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

What’s in each version: [`CHANGELOG.md`](CHANGELOG.md) (also **Help → Release History** in the app). Maintainer process: [docs/RELEASES.md](docs/RELEASES.md).

---

## Vision

Modern OS file explorers prioritize casual browsing over discoverability, search performance, developer workflows, automation, and extensibility.

Arbor aims to be the filesystem equivalent of VS Code:

- **Fast** — instant startup, Everything-class search
- **Native** — SwiftUI on macOS first; native UIs planned for Linux and Windows
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

The macOS app is Swift end-to-end (SwiftUI + AppKit): browsing, search
(Spotlight → `fd` → walk), previews (Markdown/Mermaid/code), terminal,
and agents all live behind a provider-neutral `FileProvider` model that
already abstracts local disks and SSH/SFTP. Rust ships in the app as
`arbor-sftp-helper`, a stdio-IPC sidecar per SSH connection — the
pattern for future native-capability sidecars.

```text
Arbor.app (Swift)  ──spawn/NDJSON──►  arbor-sftp-helper (Rust)
      │                                    SFTP over OpenSSH
      └── provider model: Local · SSH  ·  (SMB/S3 later)
```

Cross-platform ports (Linux/Windows) will reuse the provider contracts
and pure logic (unit-tested via `swift test`), deciding on a shared
Rust core when those ports begin. Full details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Repository Layout

```
arbor/
├── apps/macos/         # Swift app (Xcode project)
├── crates/
│   ├── arbor-sftp-helper/  # Rust sidecar: SFTP bridge (ships in app)
│   ├── arbor-cli/          # CLI smoke tool for CI
│   ├── arbor-core/         # Rust core candidate (not linked yet)
│   └── arbor-ffi/          # C ABI stubs (not linked yet)
├── Tests/              # SPM unit tests for pure logic (swift test)
├── Package.swift       # SPM package for the pure-logic tests
├── Casks/              # Homebrew cask
├── CHANGELOG.md        # Release history (Help → Release History)
├── docs/               # Architecture, roadmap, releases, vision
├── scripts/            # dev-check, packaging, test fixtures
└── .github/workflows/  # CI
```

---

## Status

**Actively shipping on macOS.** Latest: [v1.6.1](https://github.com/cacuscacus/arbor/releases/tag/v1.6.1) — rendered Markdown/Mermaid/code previews with quick edit, overhauled search, Quick Look, Go to Folder, and SSH/SFTP locations (MVP). See [`CHANGELOG.md`](CHANGELOG.md) for the full history.

### Near-term focus

1. Finish SSH locations MVP: interactive auth, host-key rotation flow, remote delete ([Phase 6](docs/ROADMAP.md))
2. Richer search: query language (`kind:`, `size>`, `modified:`), content search
3. Ambient Git: status badges, diff vs HEAD
4. Browser polish: tab reorder, Open in New Tab, vertical split

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
