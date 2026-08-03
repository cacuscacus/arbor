//! Search engine — Everything-class filename search and query language.
//!
//! Planned backends: live walk (`fd` / `walkdir`), ripgrep for content,
//! optional SQLite index, Spotlight when useful.

use crate::error::{ArborError, Result};

/// A parsed search query (placeholder until the query language lands).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchQuery {
    /// Raw query string as typed by the user.
    pub raw: String,
}

impl SearchQuery {
    /// Create a query from a raw string.
    pub fn parse(raw: impl Into<String>) -> Self {
        Self { raw: raw.into() }
    }
}

/// A single search hit.
#[derive(Debug, Clone)]
pub struct SearchHit {
    /// Absolute path of the match.
    pub path: std::path::PathBuf,
    /// Optional score for ranking (higher is better).
    pub score: f32,
}

/// Run a search. Not implemented yet.
pub fn search(_query: &SearchQuery) -> Result<Vec<SearchHit>> {
    Err(ArborError::NotImplemented(
        "search engine — see docs/ROADMAP.md Phase 1",
    ))
}
