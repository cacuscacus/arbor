# Arbor

A modern, native, open-source file manager built for developers and power users.

Finder for everyone else. **Arbor** for people who actually work with files.

---

## Vision

Modern operating systems still ship with file explorers designed primarily for casual users. Finder, Explorer, and most Linux file managers prioritize simplicity over discoverability, search performance, developer workflows, automation, and extensibility.

Arbor aims to become the filesystem equivalent of VS Code:

- **Fast** — instant startup, Everything-class search
- **Native** — SwiftUI on macOS first; Tauri later for Linux and Windows
- **Extensible** — Rust plugins with Lua / Python / JavaScript scripting
- **AI-first** — natural language that translates into real shell commands
- **Cross-platform** — one Rust core, multiple UIs
- **Open source** — Apache-2.0

Instead of merely browsing folders, Arbor becomes the control center for everything that happens around files: search, Git, terminals, automation, and AI — without jumping between Finder, Terminal, and your IDE.

The filesystem barely evolved for decades. We still navigate folders like in the 1990s. Arbor treats the filesystem as a knowledge base — semantic search, Git, terminals, automation, and AI are first-class from day one.

---

## Design Principles

| Principle | Meaning |
|-----------|---------|
| Native feeling | Looks and behaves like a first-party macOS app |
| Instant startup | Target **&lt;100ms** cold start |
| Zero indexing delays | Search works immediately; index is optional acceleration |
| Minimal memory | Target **&lt;150 MB** steady state |
| Keyboard-first | Every action reachable without a mouse |
| Mouse-friendly | Pointer users are first-class too |
| AI without intrusion | Helpful when asked; quiet when not |
| Fully scriptable | If you can do it in the UI, you can automate it |

---

## Architecture

```
UI (SwiftUI / Tauri)
        ↓
   Rust Core (FFI)
        ↓
┌───────────────────────────────────────┐
│  Filesystem · Search · Watcher        │
│  Metadata · Preview · Scheduler       │
│  Plugins · AI Layer · Terminal Layer  │
└───────────────────────────────────────┘
```

| Layer | Role |
|-------|------|
| **UI** | SwiftUI (macOS) → Tauri (Linux / Windows) |
| **arbor-core** | Filesystem, search, watcher, metadata, preview, scheduler |
| **arbor-ffi** | C ABI bridge for native UIs |
| **arbor-cli** | Headless / scripting entry point |
| **Plugins** | Rust (+ Lua / Python / JS scripting APIs) |
| **AI Layer** | NL → shell commands; Claude Code, Codex, Cursor CLI, Ollama, … |
| **Terminal Layer** | Per-folder terminals (bash, zsh, fish, nushell, PowerShell) |

---

## Repository Layout

```
arbor/
├── apps/
│   └── macos/          # SwiftUI shell
├── crates/
│   ├── arbor-core/     # Core library
│   ├── arbor-ffi/      # FFI bridge
│   └── arbor-cli/      # CLI binary
├── docs/               # Architecture, roadmap, vision
└── scripts/            # Dev helpers
```

---

## Status

**Early scaffolding.** Local development only — no public remote yet.

### Near-term focus

1. Directory listing + keyboard navigation (SwiftUI)
2. Instant filename search (`fd` / `walkdir` + optional SQLite)
3. Embedded terminal per folder
4. FFI bridge so the UI talks to Rust, not the other way around

See [docs/ROADMAP.md](docs/ROADMAP.md) for the full plan.

---

## Getting Started

### Prerequisites

- Rust 1.75+ (`rustup`)
- Xcode 15+ (macOS UI)
- macOS 14+ recommended

### Build the Rust workspace

```bash
cargo build
cargo test
cargo run -p arbor-cli -- --help
```

### macOS UI

The SwiftUI app lives under `apps/macos/`. Open it in Xcode once the project is generated, or follow docs as they land.

---

## Search (target UX)

Search should feel like [Everything](https://www.voidtools.com/) on Windows — not Spotlight-as-primary.

```
invoice june
kind:pdf
modified:last-week
size>100mb
tag:project-alpha
owner:juan
contains:"OrderSend"
extension:mq4
```

Powered by `fd`, `ripgrep`, `fzf`, optional SQLite index, and Spotlight when useful.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
