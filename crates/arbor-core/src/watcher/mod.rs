//! Filesystem watcher — incremental updates for listings and indexes.

use crate::error::{ArborError, Result};

/// Watch a path for changes. Not implemented yet.
pub fn watch(_path: impl AsRef<std::path::Path>) -> Result<()> {
    Err(ArborError::NotImplemented("filesystem watcher"))
}
