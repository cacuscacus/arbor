//! Preview engine — Quick Look bridge, Markdown, images, PDF, code, hex.

use crate::error::{ArborError, Result};

/// Generate or fetch a preview for a path. Not implemented yet.
pub fn preview(_path: impl AsRef<std::path::Path>) -> Result<()> {
    Err(ArborError::NotImplemented("preview engine"))
}
