# Roadmap

Status legend: ⬚ planned · ◐ in progress · ✓ done

---

## Phase 0 — Foundation (current)

- ✓ Repository scaffold (Cargo workspace, docs, licenses)
- ⬚ `arbor-core` directory listing API
- ⬚ `arbor-ffi` minimal C ABI (`list_dir`, `stat`)
- ⬚ SwiftUI shell: sidebar + file list + breadcrumbs
- ⬚ Keyboard navigation (arrows, Enter, Backspace, `/` search)
- ⬚ `arbor-cli` for smoke tests without UI

## Phase 1 — Navigation & search

- ⬚ Favorites, Recents, Volumes, Bookmarks, History
- ⬚ Back / Forward, directory tree
- ⬚ Instant filename search (`fd` / walk + ignore)
- ⬚ Query language: `kind:`, `ext:`, `size>`, `modified:`
- ⬚ Virtual scrolling for large directories

## Phase 2 — Terminal

- ⬚ Per-folder terminal pane
- ⬚ bash / zsh / fish / nushell
- ⬚ Terminal tabs + session persistence

## Phase 3 — Developer mode

- ⬚ Git status in list / sidebar
- ⬚ Diff viewer, blame, file history
- ⬚ Open in Cursor / VS Code / Zed / Xcode / IntelliJ
- ⬚ Detect Git repos for sidebar section

## Phase 4 — AI & automation

- ⬚ NL → command translation with confirmation
- ⬚ Provider adapters (CLI tools + API providers)
- ⬚ Folder / file rules, triggers, workflows
- ⬚ Batch rename / move / convert / compress / dedupe

## Phase 5 — Preview & remote

- ⬚ Quick Look + Markdown / image / video / PDF / code / hex
- ⬚ SSH / SFTP / SMB / NFS / WebDAV
- ⬚ S3, Google Drive, Dropbox

## Phase 6 — Cross-platform & plugins

- ⬚ Tauri UI for Linux / Windows
- ⬚ Rust plugin ABI
- ⬚ Lua / Python / JS scripting hosts
- ✓ Public GitHub repository ([cacuscacus/arbor](https://github.com/cacuscacus/arbor))

## Distribution & updates

No Apple Developer Program / notarization. See [RELEASES.md](RELEASES.md).

- ✓ Release process docs (`docs/RELEASES.md`)
- ✓ macOS packaging script (`scripts/package-macos.sh`)
- ✓ Homebrew cask in-repo (`Casks/arbor.rb`)
- ✓ GitHub Releases with packaged ZIP assets (`gh release create`)
- ⬚ In-app **Check for Updates…** via GitHub Releases API (no Sparkle)
- ⬚ Broader macOS deployment target (v1.0.0 requires macOS 26 / Tahoe APIs)

---

Priorities may shift; Phase 0–1 are the current focus.
