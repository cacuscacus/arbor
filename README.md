# Arbor

A modern, native, open-source file manager built for developers and power users.

Finder for everyone else. **Arbor** for people who actually work with files.

---

## Install (macOS)

Apple silicon, **macOS 26 (Tahoe)+**. No Apple notarization — prefer Homebrew:

```bash
brew tap cacuscacus/arbor https://github.com/cacuscacus/arbor
brew trust cacuscacus/arbor   # required on Homebrew 6+
brew install --cask arbor
```

Direct downloads: [GitHub Releases](https://github.com/cacuscacus/arbor/releases). First launch may need Finder → right-click → **Open**.

Maintainer release process: [docs/RELEASES.md](docs/RELEASES.md).

---

## Vision

Modern OS file explorers prioritize casual browsing over discoverability, search performance, developer workflows, automation, and extensibility.

Arbor aims to be the filesystem equivalent of VS Code:

- **Fast** — instant startup, Everything-class search
- **Native** — SwiftUI on macOS first; Tauri later for Linux and Windows
- **Extensible** — Rust plugins with Lua / Python / JavaScript scripting
- **AI-first** — natural language that translates into real shell commands
- **Cross-platform** — one Rust core, multiple UIs
- **Open source** — Apache-2.0

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
├── apps/macos/         # SwiftUI shell
├── crates/
│   ├── arbor-core/     # Core library (+ unit tests)
│   ├── arbor-ffi/      # FFI bridge (+ unit tests)
│   └── arbor-cli/      # CLI (+ integration tests)
├── Casks/              # Homebrew cask
├── docs/               # Architecture, roadmap, releases, vision
├── scripts/            # dev-check, packaging
└── .github/workflows/  # CI
```

---

## Status

**Public MVP on macOS.** v1.0.0 ships a Finder-like browser (list/icon views, search, DnD, undo) via Homebrew / GitHub Releases. The UI still talks to the filesystem directly in places; Rust `arbor-core` / FFI ownership is the next hardening step.

### Near-term focus

1. Grow `arbor-core` + FFI coverage; thin the SwiftUI layer
2. Richer search (`fd` / walk + query language)
3. Embedded terminal per folder
4. In-app **Check for Updates…** via GitHub Releases API

See [docs/ROADMAP.md](docs/ROADMAP.md).

---

## Getting Started (development)

### Prerequisites

- Rust 1.75+ (`rustup`), with `rustfmt` and `clippy`
- Xcode 26+ and macOS 26+ for the SwiftUI app

### Build & test

```bash
cargo build
cargo test --workspace
cargo run -p arbor-cli -- list .
./scripts/dev-check.sh          # required before PRs (matches CI)
```

### macOS UI

```bash
open apps/macos/Arbor.xcodeproj
# or package a Release ZIP:
./scripts/package-macos.sh
```

More app notes: [apps/macos/README.md](apps/macos/README.md).

---

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md). Every PR must pass `./scripts/dev-check.sh` / GitHub Actions CI.

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
