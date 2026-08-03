//! Terminal layer — per-folder sessions (bash, zsh, fish, nushell, PowerShell).

use crate::error::{ArborError, Result};

/// Open a terminal session rooted at `cwd`. Not implemented yet.
pub fn open_session(_cwd: impl AsRef<std::path::Path>) -> Result<()> {
    Err(ArborError::NotImplemented("terminal layer"))
}
