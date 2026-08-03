//! Arbor CLI — headless entry point for development and scripting.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use arbor_core::fs::{ListOptions, list_dir};

#[derive(Parser)]
#[command(name = "arbor", version, about = "Arbor — modern file manager for developers")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Print Arbor core version
    Version,

    /// List directory contents
    List {
        /// Directory to list
        #[arg(default_value = ".")]
        path: PathBuf,

        /// Include hidden (dot) files
        #[arg(long, short = 'a')]
        all: bool,

        /// Emit JSON instead of a human-readable table
        #[arg(long)]
        json: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Version => {
            println!("arbor {}", arbor_core::VERSION);
        }
        Commands::List { path, all, json } => {
            let entries = list_dir(
                &path,
                ListOptions {
                    show_hidden: all,
                },
            )
            .with_context(|| format!("failed to list {}", path.display()))?;

            if json {
                println!("{}", serde_json::to_string_pretty(&entries)?);
            } else {
                for entry in &entries {
                    let marker = match entry.kind {
                        arbor_core::fs::EntryKind::Directory => "dir ",
                        arbor_core::fs::EntryKind::File => "file",
                        arbor_core::fs::EntryKind::Symlink => "link",
                        arbor_core::fs::EntryKind::Other => "other",
                    };
                    println!("{marker}  {}", entry.name);
                }
                eprintln!("{} entries", entries.len());
            }
        }
    }

    Ok(())
}
