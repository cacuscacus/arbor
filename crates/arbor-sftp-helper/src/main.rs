//! Private newline-delimited JSON bridge used by the macOS app.
//!
//! The helper spawns the system `ssh` client directly (`ssh -s <dest> sftp`)
//! so authentication and routing keep their normal OpenSSH semantics:
//! aliases, ssh-agent, IdentityFile and ProxyJump all work, and password /
//! passphrase prompts are served through an askpass bridge back to the app
//! (the app sets SSH_ASKPASS/SSH_ASKPASS_REQUIRE on this process and listens
//! on the socket named by ARBOR_ASKPASS_SOCKET).
//!
//! Host-key enrollment stays explicit: StrictHostKeyChecking=yes, so new or
//! changed keys fail here and are resolved by the app's verification UI.

use std::{
    env,
    io::{self, BufRead, Write},
    path::Path,
    process::Stdio,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use futures_util::{pin_mut, StreamExt};
use openssh_sftp_client::{metadata::MetaData, Sftp, SftpOptions};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::process::{Child, Command};

const MAX_REMOVE_DEPTH: u32 = 64;

#[derive(Debug)]
struct ConnectionOptions {
    destination: String,
    user: Option<String>,
    port: Option<u16>,
    identity_file: Option<String>,
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
        #[serde(default)]
        recursive: bool,
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

/// Askpass bridge entry: ssh (or ssh-add) invokes $SSH_ASKPASS with the
/// prompt as argv[1]; the answer comes from the app over a unix socket.
fn run_askpass() -> Result<()> {
    let socket_path = env::var("ARBOR_ASKPASS_SOCKET").context("ARBOR_ASKPASS_SOCKET missing")?;
    let prompt = env::args().nth(1).unwrap_or_default();

    let stream = connect_with_retry(&socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(300)))?;
    let mut writer = stream
        .try_clone()
        .context("failed to clone askpass socket")?;
    let mut reader = io::BufReader::new(stream);

    let request = json!({ "prompt": prompt });
    writer.write_all(request.to_string().as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()?;

    let mut line = String::new();
    reader
        .read_line(&mut line)
        .context("askpass reply failed")?;
    let reply: Value = serde_json::from_str(line.trim()).context("invalid askpass reply")?;

    if reply.get("cancelled").and_then(Value::as_bool) == Some(true) {
        std::process::exit(1);
    }
    let secret = reply
        .get("secret")
        .and_then(Value::as_str)
        .unwrap_or_default();
    println!("{secret}");
    Ok(())
}

fn connect_with_retry(path: &str) -> Result<std::os::unix::net::UnixStream> {
    let mut last_error = None;
    for _ in 0..50 {
        match std::os::unix::net::UnixStream::connect(path) {
            Ok(stream) => return Ok(stream),
            Err(error) => last_error = Some(error),
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err(last_error
        .map(|error| anyhow::anyhow!("cannot reach askpass socket: {error}"))
        .unwrap_or_else(|| anyhow::anyhow!("cannot reach askpass socket")))
}

fn spawn_ssh(options: &ConnectionOptions) -> Result<Child> {
    let mut command = Command::new("ssh");
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // No -q: the app classifies failures from ssh's stderr, and it is
        // piped (never shown to the user directly).
        .arg("-T")
        .arg("-o")
        .arg("StrictHostKeyChecking=yes")
        .arg("-o")
        .arg("ConnectTimeout=15")
        .arg("-o")
        .arg("ServerAliveInterval=30");
    if let Some(user) = &options.user {
        command.arg("-l").arg(user);
    }
    if let Some(identity) = &options.identity_file {
        command.arg("-i").arg(identity);
        // Only the chosen key is offered; agent keys must not silently win.
        command.arg("-o").arg("IdentitiesOnly=yes");
    }
    if let Some(port) = options.port {
        command.arg("-p").arg(port.to_string());
    }
    // `-s` marks the remote command as a subsystem: `ssh -s <dest> sftp`.
    command.arg("-s").arg(&options.destination).arg("sftp");
    let child = command.spawn().context("failed to spawn ssh")?;
    Ok(child)
}

/// Optional debug log (set ARBOR_HELPER_LOG to a file path). Never enabled by
/// the app in normal operation.
fn debug_log(message: &str) {
    let Ok(path) = env::var("ARBOR_HELPER_LOG") else {
        return;
    };
    use std::fmt::Write as _;
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis());
    let mut line = String::new();
    let _ = writeln!(line, "{millis} {message}");
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = file.write_all(line.as_bytes());
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    if env::var_os("ARBOR_ASKPASS_SOCKET").is_some()
        && !env::args().skip(1).any(|arg| arg == "--destination")
    {
        return run_askpass();
    }

    let options = parse_args(env::args().skip(1))?;
    let mut child = spawn_ssh(&options)?;
    let stdin = child.stdin.take().context("ssh stdin missing")?;
    let stdout = child.stdout.take().context("ssh stdout missing")?;

    // Capture ssh's stderr (for diagnostics) and tee it to our own stderr:
    // the app classifies connection failures (host key, auth) from whatever
    // we emit. The task ends when the child closes the pipe.
    let stderr_task = child.stderr.take().map(|mut stderr| {
        tokio::spawn(async move {
            use tokio::io::AsyncReadExt;
            let mut captured = String::new();
            let mut chunk = [0u8; 4096];
            loop {
                match stderr.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(read) => {
                        let text = String::from_utf8_lossy(&chunk[..read]).into_owned();
                        eprint!("{text}");
                        captured.push_str(&text);
                    }
                    Err(_) => break,
                }
            }
            captured
        })
    });

    let sftp = match Sftp::new(stdin, stdout, SftpOptions::default()).await {
        Ok(sftp) => sftp,
        Err(error) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            // Give the stderr task a chance to finish so its output reaches
            // our stderr before the runtime tears down.
            let details = match stderr_task {
                Some(task) => task.await.unwrap_or_default(),
                None => String::new(),
            };
            let details = details.trim();
            if details.is_empty() {
                bail!("SFTP subsystem negotiation failed: {error:#}");
            }
            bail!(
                "SFTP subsystem negotiation failed: {error:#}
{details}"
            );
        }
    };
    let mut fs = sftp.fs();

    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.context("failed to read request")?;
        debug_log(&format!("request: {line}"));
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

    drop(fs);
    sftp.close().await.context("failed to close SFTP session")?;
    let _ = child.kill().await;
    Ok(())
}

async fn execute(fs: &mut openssh_sftp_client::fs::Fs, operation: Operation) -> Result<Value> {
    debug_log(&format!("execute: {operation:?}"));
    match operation {
        Operation::List { path } => {
            debug_log("list: open_dir...");
            let directory = fs.open_dir(&path).await?;
            debug_log("list: open_dir done");
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
            debug_log(&format!("list: {} entries", entries.len()));
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
        Operation::Remove {
            path,
            is_directory,
            recursive,
        } => {
            if is_directory {
                if recursive {
                    remove_tree(fs, &path, 0).await?;
                } else {
                    fs.remove_dir(path).await?;
                }
            } else {
                fs.remove_file(path).await?;
            }
            Ok(json!({}))
        }
        Operation::Ping => Ok(json!({ "protocol": 1 })),
    }
}

/// Depth-first recursive delete. Symlinks are removed without following.
async fn remove_tree(fs: &mut openssh_sftp_client::fs::Fs, path: &str, depth: u32) -> Result<()> {
    if depth > MAX_REMOVE_DEPTH {
        bail!("directory nesting exceeds {MAX_REMOVE_DEPTH} levels; refusing to delete");
    }
    let directory = fs.open_dir(path).await?;
    let stream = directory.read_dir();
    pin_mut!(stream);
    let mut children = Vec::new();
    while let Some(entry) = stream.next().await {
        let entry = entry?;
        let name = entry.filename().to_string_lossy();
        if name == "." || name == ".." {
            continue;
        }
        children.push((name.into_owned(), entry.metadata()));
    }
    let prefix = path.trim_end_matches('/');
    for (name, metadata) in children {
        let child = format!("{prefix}/{name}");
        let file_type = metadata.file_type();
        if file_type.is_some_and(|kind| kind.is_dir()) {
            Box::pin(remove_tree(fs, &child, depth + 1)).await?;
        } else {
            // Files, symlinks, and anything else are unlinked directly.
            fs.remove_file(child).await?;
        }
    }
    fs.remove_dir(path).await?;
    Ok(())
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
    let mut identity_file = None;
    let mut args = args.peekable();
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--destination" => destination = args.next(),
            "--user" => user = args.next(),
            "--identity-file" => identity_file = args.next(),
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
        identity_file,
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
    fn parses_identity_file() {
        let options = parse_args(
            ["--destination", "host", "--identity-file", "/tmp/key"]
                .into_iter()
                .map(String::from),
        )
        .unwrap();
        assert_eq!(options.identity_file.as_deref(), Some("/tmp/key"));
    }

    #[test]
    fn request_is_tagged_by_method() {
        let request: Request =
            serde_json::from_str(r#"{"id":7,"method":"list","path":"/srv"}"#).unwrap();
        assert_eq!(request.id, 7);
        assert!(matches!(request.operation, Operation::List { .. }));
    }

    #[test]
    fn remove_request_supports_recursive_flag() {
        let request: Request = serde_json::from_str(
            r#"{"id":8,"method":"remove","path":"/srv/x","is_directory":true,"recursive":true}"#,
        )
        .unwrap();
        match request.operation {
            Operation::Remove {
                path,
                is_directory,
                recursive,
            } => {
                assert_eq!(path, "/srv/x");
                assert!(is_directory);
                assert!(recursive);
            }
            other => panic!("unexpected operation: {other:?}"),
        }
    }

    #[test]
    fn remove_request_defaults_to_non_recursive() {
        let request: Request = serde_json::from_str(
            r#"{"id":9,"method":"remove","path":"/srv/x","is_directory":true}"#,
        )
        .unwrap();
        match request.operation {
            Operation::Remove { recursive, .. } => assert!(!recursive),
            other => panic!("unexpected operation: {other:?}"),
        }
    }
}
