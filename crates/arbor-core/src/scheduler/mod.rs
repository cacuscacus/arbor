//! Background task scheduler — indexing, batch ops, workflows.

use crate::error::{ArborError, Result};

/// Submit a background task. Not implemented yet.
pub fn spawn_task(_name: &str) -> Result<()> {
    Err(ArborError::NotImplemented("task scheduler"))
}
