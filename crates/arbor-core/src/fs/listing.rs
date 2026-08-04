//! Directory listing.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{ArborError, Result};

fn system_time_to_unix(time: SystemTime) -> Option<i64> {
    time.duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_secs()).ok())
}

/// Kind of filesystem entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    /// Regular file.
    File,
    /// Directory.
    Directory,
    /// Symbolic link.
    Symlink,
    /// Something else (socket, fifo, device, …).
    Other,
}

/// A single entry returned by [`list_dir`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectoryEntry {
    /// File or directory name (not a full path).
    pub name: String,
    /// Absolute path.
    pub path: PathBuf,
    /// Entry kind.
    pub kind: EntryKind,
    /// Size in bytes (0 for directories / unknown).
    pub size: u64,
    /// Last modified time as Unix seconds, if available.
    pub modified: Option<i64>,
    /// Whether this entry is hidden (name starts with `.` on Unix).
    pub hidden: bool,
}

/// Options for [`list_dir`].
#[derive(Debug, Clone, Default)]
pub struct ListOptions {
    /// Include hidden entries (dotfiles). Default: `false`.
    pub show_hidden: bool,
}

/// List the immediate children of `path`.
///
/// Results are sorted: directories first, then files, case-insensitive by name.
pub fn list_dir(path: impl AsRef<Path>, options: ListOptions) -> Result<Vec<DirectoryEntry>> {
    let path = path.as_ref();

    if !path.exists() {
        return Err(ArborError::NotFound(path.to_path_buf()));
    }
    if !path.is_dir() {
        return Err(ArborError::NotADirectory(path.to_path_buf()));
    }

    let read = fs::read_dir(path).map_err(|source| ArborError::Io {
        path: path.to_path_buf(),
        source,
    })?;

    let mut entries = Vec::new();

    for entry in read {
        let entry = entry.map_err(|source| ArborError::Io {
            path: path.to_path_buf(),
            source,
        })?;

        let name = entry.file_name().to_string_lossy().into_owned();
        let hidden = name.starts_with('.');
        if hidden && !options.show_hidden {
            continue;
        }

        let file_path = entry.path();
        let metadata = entry.metadata().ok();
        let file_type = entry.file_type().ok();

        let kind = match file_type {
            Some(ft) if ft.is_dir() => EntryKind::Directory,
            Some(ft) if ft.is_file() => EntryKind::File,
            Some(ft) if ft.is_symlink() => EntryKind::Symlink,
            _ => EntryKind::Other,
        };

        let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
        let modified = metadata
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(system_time_to_unix);

        entries.push(DirectoryEntry {
            name,
            path: file_path,
            kind,
            size,
            modified,
            hidden,
        });
    }

    entries.sort_by(|a, b| {
        let dir_cmp = (a.kind != EntryKind::Directory).cmp(&(b.kind != EntryKind::Directory));
        dir_cmp.then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    #[test]
    fn lists_directory_children() {
        let dir = tempfile::tempdir().unwrap();
        File::create(dir.path().join("b.txt")).unwrap();
        File::create(dir.path().join("a.txt")).unwrap();
        fs::create_dir(dir.path().join("subdir")).unwrap();
        File::create(dir.path().join(".hidden")).unwrap();

        let entries = list_dir(dir.path(), ListOptions::default()).unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();

        assert_eq!(names, vec!["subdir", "a.txt", "b.txt"]);
        assert!(entries[0].kind == EntryKind::Directory);
    }

    #[test]
    fn show_hidden_includes_dotfiles() {
        let dir = tempfile::tempdir().unwrap();
        File::create(dir.path().join(".secret")).unwrap();

        let entries = list_dir(dir.path(), ListOptions { show_hidden: true }).unwrap();

        assert!(entries.iter().any(|e| e.name == ".secret"));
    }

    #[test]
    fn missing_path_returns_not_found() {
        let err = list_dir("/nonexistent/arbor/path", ListOptions::default()).unwrap_err();
        assert!(matches!(err, ArborError::NotFound(_)));
    }

    #[test]
    fn file_path_returns_not_a_directory() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("not-a-dir.txt");
        File::create(&file).unwrap();

        let err = list_dir(&file, ListOptions::default()).unwrap_err();
        assert!(matches!(err, ArborError::NotADirectory(_)));
    }

    #[test]
    fn sorts_case_insensitively_within_kind() {
        let dir = tempfile::tempdir().unwrap();
        File::create(dir.path().join("Zed.txt")).unwrap();
        File::create(dir.path().join("alpha.txt")).unwrap();
        fs::create_dir(dir.path().join("Beta")).unwrap();
        fs::create_dir(dir.path().join("aardvark")).unwrap();

        let entries = list_dir(dir.path(), ListOptions::default()).unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();

        assert_eq!(names, vec!["aardvark", "Beta", "alpha.txt", "Zed.txt"]);
    }

    #[test]
    fn marks_hidden_and_reports_file_size() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".notes");
        std::fs::write(&path, b"hello").unwrap();

        let entries = list_dir(dir.path(), ListOptions { show_hidden: true }).unwrap();
        let entry = entries.iter().find(|e| e.name == ".notes").unwrap();

        assert!(entry.hidden);
        assert_eq!(entry.kind, EntryKind::File);
        assert_eq!(entry.size, 5);
        assert!(entry.path.ends_with(".notes"));
    }
}
