//! Arbor core library.
//!
//! Domain logic for filesystem access, search, watching, metadata, preview,
//! scheduling, plugins, AI, and terminal integration. Native UI layers (SwiftUI
//! on macOS; Linux and Windows planned) talk to this crate through `arbor-ffi`
//! or `arbor-cli`.

#![deny(missing_docs)]

pub mod ai;
pub mod error;
pub mod fs;
pub mod metadata;
pub mod plugin;
pub mod preview;
pub mod scheduler;
pub mod search;
pub mod terminal;
pub mod watcher;

pub use error::{ArborError, Result};
pub use fs::{list_dir, DirectoryEntry, EntryKind};

/// Library version embedded at compile time.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
