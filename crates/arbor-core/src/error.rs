//! Error types for Arbor core operations.

use std::path::PathBuf;

use thiserror::Error;

/// Result alias used throughout `arbor-core`.
pub type Result<T> = std::result::Result<T, ArborError>;

/// Errors that can occur in Arbor core operations.
#[derive(Debug, Error)]
pub enum ArborError {
    /// I/O failure while touching the filesystem.
    #[error("I/O error at {path}: {source}")]
    Io {
        /// Path involved in the failure, when known.
        path: PathBuf,
        /// Underlying I/O error.
        source: std::io::Error,
    },

    /// Path does not exist.
    #[error("path not found: {0}")]
    NotFound(PathBuf),

    /// Path exists but is not a directory.
    #[error("not a directory: {0}")]
    NotADirectory(PathBuf),

    /// Operation is not implemented yet.
    #[error("not implemented: {0}")]
    NotImplemented(&'static str),

    /// Generic catch-all with context.
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}
