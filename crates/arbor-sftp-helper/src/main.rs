//! Private newline-delimited JSON bridge used by the macOS app.
//!
//! Authentication and routing stay in the system OpenSSH client so aliases,
//! ssh-agent, IdentityFile and ProxyJump keep their normal semantics. The
//! helper deliberately uses StrictHostKeyChecking: host-key enrollment is a
//! separate, explicit UI operation.

use std::{
    env,
    io::{self, BufRead, Write},
    path::Path,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use futures_util::{pin_mut, StreamExt};
use openssh::{KnownHosts, SessionBuilder};
use openssh_sftp_client::{metadata::MetaData, Sftp, SftpOptions};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug)]
struct ConnectionOptions {
    destination: String,
    user: Option<String>,
    port: Option<u16>,
}

#[derive(Debug, Deserialize)]
struct Request {
    id: u64,
    #[serde(flatten)]
    operation: Operation,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "method", rename_all = "snake_case")]
enum Operation {
    List {
        path: String,
    },
    Stat {
        path: String,
    },
    CreateDirectory {
        path: String,
    },
    CreateFile {
        path: String,
        contents_base64: String,
    },
    Rename {
        from: String,
        to: String,
    },
    Remove {
        path: String,
        is_directory: bool,
    },
    Ping,
}

#[derive(Debug, Serialize)]
struct Entry {
    name: String,
    is_directory: bool,
    is_symbolic_link: bool,
    size: Option<u64>,
    modified: Option<u32>,
    permissions: Option<u32>,
}

#[derive(Debug, Serialize)]
struct Response {
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ProtocolError>,
}

#[derive(Debug, Serialize)]
struct ProtocolError {
    code: &'static str,
    message: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let options = parse_args(env::args().skip(1))?;
    let mut builder = SessionBuilder::default();
    builder
        .known_hosts_check(KnownHosts::Strict)
        .connect_timeout(Duration::from_secs(15))
        .server_alive_interval(Duration::from_secs(30));
    if let Some(user) = options.user {
        builder.user(user);
    }
    if let Some(port) = options.port {
        builder.port(port);
    }

    let session = builder
        .connect(&options.destination)
        .await
        .context("OpenSSH connection failed")?;
    let sftp = Sftp::from_session(session, SftpOptions::default())
        .await
        .context("SFTP subsystem failed")?;
    let mut fs = sftp.fs();

    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.context("failed to read request")?;
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) => match execute(&mut fs, request.operation).await {
                Ok(result) => Response {
                    id: request.id,
                    result: Some(result),
                    error: None,
                },
                Err(error) => Response {
                    id: request.id,
                    result: None,
                    error: Some(classify_error(error)),
                },
            },
            Err(error) => Response {
                id: 0,
                result: None,
                error: Some(ProtocolError {
                    code: "invalid_request",
                    message: error.to_string(),
                }),
            },
        };
        serde_json::to_writer(&mut stdout, &response)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
    }

    sftp.close().await.context("failed to close SFTP session")
}

async fn execute(fs: &mut openssh_sftp_client::fs::Fs, operation: Operation) -> Result<Value> {
    match operation {
        Operation::List { path } => {
            let directory = fs.open_dir(&path).await?;
            let stream = directory.read_dir();
            pin_mut!(stream);
            let mut entries = Vec::new();
            while let Some(entry) = stream.next().await {
                let entry = entry?;
                let name = entry.filename().to_string_lossy();
                if name == "." || name == ".." {
                    continue;
                }
                entries.push(entry_value(name.into_owned(), entry.metadata()));
            }
            Ok(serde_json::to_value(entries)?)
        }
        Operation::Stat { path } => {
            let metadata = fs.symlink_metadata(&path).await?;
            let name = Path::new(&path)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or(path);
            Ok(serde_json::to_value(entry_value(name, metadata))?)
        }
        Operation::CreateDirectory { path } => {
            fs.create_dir(path).await?;
            Ok(json!({}))
        }
        Operation::CreateFile {
            path,
            contents_base64,
        } => {
            let contents = BASE64
                .decode(contents_base64)
                .context("invalid base64 file contents")?;
            fs.write(path, contents).await?;
            Ok(json!({}))
        }
        Operation::Rename { from, to } => {
            fs.rename(from, to).await?;
            Ok(json!({}))
        }
        Operation::Remove { path, is_directory } => {
            if is_directory {
                fs.remove_dir(path).await?;
            } else {
                fs.remove_file(path).await?;
            }
            Ok(json!({}))
        }
        Operation::Ping => Ok(json!({ "protocol": 1 })),
    }
}

fn entry_value(name: String, metadata: MetaData) -> Entry {
    let file_type = metadata.file_type();
    Entry {
        name,
        is_directory: file_type.is_some_and(|kind| kind.is_dir()),
        is_symbolic_link: file_type.is_some_and(|kind| kind.is_symlink()),
        size: metadata.len(),
        modified: metadata.modified().map(|time| time.into_raw()),
        permissions: metadata.permissions().map(permission_bits),
    }
}

fn permission_bits(permissions: openssh_sftp_client::metadata::Permissions) -> u32 {
    [
        (permissions.suid(), 0o4000),
        (permissions.sgid(), 0o2000),
        (permissions.svtx(), 0o1000),
        (permissions.read_by_owner(), 0o400),
        (permissions.write_by_owner(), 0o200),
        (permissions.execute_by_owner(), 0o100),
        (permissions.read_by_group(), 0o040),
        (permissions.write_by_group(), 0o020),
        (permissions.execute_by_group(), 0o010),
        (permissions.read_by_other(), 0o004),
        (permissions.write_by_other(), 0o002),
        (permissions.execute_by_other(), 0o001),
    ]
    .into_iter()
    .filter_map(|(set, bit)| set.then_some(bit))
    .sum()
}

fn classify_error(error: anyhow::Error) -> ProtocolError {
    let message = format!("{error:#}");
    let lower = message.to_ascii_lowercase();
    let code = if lower.contains("no such file") {
        "not_found"
    } else if lower.contains("permission denied") {
        "permission_denied"
    } else if lower.contains("file exists") {
        "already_exists"
    } else if lower.contains("not a directory") {
        "not_directory"
    } else {
        "operation_failed"
    };
    ProtocolError { code, message }
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<ConnectionOptions> {
    let mut destination = None;
    let mut user = None;
    let mut port = None;
    let mut args = args.peekable();
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--destination" => destination = args.next(),
            "--user" => user = args.next(),
            "--port" => {
                port = Some(
                    args.next()
                        .context("--port requires a value")?
                        .parse()
                        .context("invalid SSH port")?,
                )
            }
            _ => bail!("unknown argument: {argument}"),
        }
    }
    Ok(ConnectionOptions {
        destination: destination.context("--destination is required")?,
        user,
        port,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_direct_connection_options() {
        let options = parse_args(
            ["--destination", "host", "--user", "alice", "--port", "2222"]
                .into_iter()
                .map(String::from),
        )
        .unwrap();
        assert_eq!(options.destination, "host");
        assert_eq!(options.user.as_deref(), Some("alice"));
        assert_eq!(options.port, Some(2222));
    }

    #[test]
    fn request_is_tagged_by_method() {
        let request: Request =
            serde_json::from_str(r#"{"id":7,"method":"list","path":"/srv"}"#).unwrap();
        assert_eq!(request.id, 7);
        assert!(matches!(request.operation, Operation::List { .. }));
    }
}
