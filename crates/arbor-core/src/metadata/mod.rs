//! Metadata engine — size, dates, tags, owners, content-type cache.

use crate::error::{ArborError, Result};

/// Cached metadata for a path. Shape will expand with the SQLite index.
#[derive(Debug, Clone, Default)]
pub struct FileMetadata {
    /// MIME / content type if known.
    pub content_type: Option<String>,
}

/// Load metadata for a path. Not implemented yet.
pub fn metadata_for(_path: impl AsRef<std::path::Path>) -> Result<FileMetadata> {
    Err(ArborError::NotImplemented("metadata engine"))
}
