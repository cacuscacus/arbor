//! AI layer — natural language → shell / Arbor actions.

use crate::error::{ArborError, Result};

/// Translate a natural-language request into a suggested command. Not implemented yet.
pub fn translate(_prompt: &str) -> Result<String> {
    Err(ArborError::NotImplemented("AI natural-language interface"))
}
