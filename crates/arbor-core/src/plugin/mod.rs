//! Plugin system — Rust ABI with planned Lua / Python / JS hosts.

use crate::error::{ArborError, Result};

/// Load a plugin from disk. Not implemented yet.
pub fn load_plugin(_path: impl AsRef<std::path::Path>) -> Result<()> {
    Err(ArborError::NotImplemented("plugin system"))
}
