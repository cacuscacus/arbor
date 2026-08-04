# Roadmap

Status legend: ⬚ planned · ◐ in progress · ✓ done

Priorities may shift. **macOS remains the reference implementation**; other OS ports reuse `arbor-core` behind a native UI.

---

## Phase 0 — Foundation

- ✓ Repository scaffold (Cargo workspace, docs, licenses)
- ✓ Public GitHub repository ([cacuscacus/arbor](https://github.com/cacuscacus/arbor))
- ✓ Homebrew / GitHub Releases shipping path (see [RELEASES.md](RELEASES.md))
- ✓ PR test gate (`./scripts/dev-check.sh` + GitHub Actions)
- ◐ `arbor-core` directory listing API (+ tests)
- ◐ `arbor-ffi` minimal C ABI (`list_dir`, version)
- ◐ SwiftUI shell: sidebar, list/icon views, search, DnD, undo
- ⬚ Move remaining FS work from Swift into `arbor-core` / FFI
- ⬚ Keyboard navigation completeness (arrows, Enter, Backspace, `/` search)
- ✓ `arbor-cli` for smoke tests without UI

---

## Phase 1 — Navigation & search

- ⬚ Favorites, Recents, Volumes, Bookmarks, History
- ⬚ Back / Forward, directory tree
- ⬚ Instant filename search (`fd` / walk + ignore) driven by core
- ⬚ Query language: `kind:`, `ext:`, `size>`, `modified:`
- ⬚ Virtual scrolling for large directories

---

## Phase 2 — Terminal & in-window AI agents

Goal: the folder you are looking at is also a place to **work** and to **delegate work**, without leaving Arbor.

### 2a — Embedded terminal (cwd = current folder)

- ⬚ Split / bottom / side terminal pane bound to the active directory
- ⬚ When the browser navigates, offer “follow cwd” vs “keep session cwd”
- ⬚ Shell profiles: system default (bash / zsh / fish / nushell / PowerShell) plus optional **Ghostty** integration when installed (external or embedded host — TBD by platform capabilities)
- ⬚ Tabs / multiple sessions per window; copy/paste, clear, restart
- ⬚ Session restoration after restart (scrollback policy TBD; at least cwd + profile)

### 2b — Configurable AI coding tool runners

First-class launchers for CLI agents that operate **on the current folder (and selection)**, configured in Settings — not hard-coded to one vendor.

**Built-in presets (detect PATH / custom binary path):**

| Preset | Example tools |
|--------|----------------|
| OpenCode | `opencode` |
| Codex | `codex` |
| Claude Code | `claude` |
| Kimi Code | vendor CLI |
| Qwen Coder | vendor CLI |
| DeepSeek | vendor CLI |
| Custom | any argv template |

Each preset stores: display name, executable, argv template, env overrides, working-directory policy (`browser cwd` | `project root` | fixed path), and whether to open in the **embedded terminal** or an external terminal app (Ghostty / Terminal.app / etc.).

**User flows:**

1. **Agent prompt** — e.g. “review everything in this folder and organize it” → Arbor opens the chosen agent in the folder cwd with the prompt (and optional selection paths) injected.
2. **Quick run** — start agent REPL / TUI in cwd with no prompt.
3. **Plain terminal** — open a normal shell in cwd for manual work.

**Guardrails (product rules):**

- Destructive agent actions stay visible in the terminal (Arbor does not silently run shell behind the user’s back in v1 of this feature).
- Settings → Tools: enable/disable presets, set paths, defaults, keyboard shortcuts.
- Never ship API keys in-repo; agents use the user’s own CLIs / auth.

Related later work in Phase 4 (NL → Arbor-native actions) complements this; Phase 2 is **bring-your-own agent CLI inside Arbor’s folder context**.

---

## Phase 3 — Multi-window & session persistence

Goal: Arbor feels like a real desktop app across restarts and crashes.

- ⬚ Multiple independent windows (each with its own path, selection, view mode, terminal/agent pane state)
- ⬚ Open window / New window from current folder; drag folder to Dock / reopen behavior as platform allows
- ⬚ Persist per-window: frame (position/size/screen), sidebar width, view mode, sort, cwd, optional terminal visibility
- ⬚ Persist global: favorites, tool presets, default agent, appearance
- ⬚ Restore session on launch (“Reopen windows”); safe degrade if a path vanished
- ⬚ Crash / forced-quit: write state atomically so a restart restores the last good snapshot

Implementation note: macOS first (SwiftUI `WindowGroup` + Codable session store). Other OS ports implement the same **session schema** from `arbor-core` so behavior matches.

---

## Phase 4 — Developer mode & quick file diff

- ⬚ Git status in list / sidebar; detect repos for a sidebar section
- ⬚ Open in Cursor / VS Code / Zed / Xcode / IntelliJ / …
- ⬚ Blame / file history (deeper Git)

### Quick diff (two-file compare)

User selects **exactly two files** (or picks “Diff with…” from a second path) → opens a **simple, readable diff viewer** optimized for fast checks, not a full merge tool.

- ⬚ Side-by-side and unified views; word/line highlighting
- ⬚ Binary / huge-file guards with clear messaging
- ⬚ Optional: diff working tree vs HEAD for one file when inside a Git repo
- ⬚ Keyboard-first: `⌘D` (or equivalent) when two files are selected

Out of scope for the first cut: three-way merge, editing inside the diff, directory diffs (those can follow).

---

## Phase 5 — AI automation beyond CLIs

Builds on Phase 2b; Arbor-native intelligence rather than only spawning external TUIs.

- ⬚ NL → Arbor actions / shell with confirmation
- ⬚ Provider adapters (CLI tools + API providers)
- ⬚ Folder / file rules, triggers, workflows
- ⬚ Batch rename / move / convert / compress / dedupe

---

## Phase 6 — Preview & remote

- ⬚ Quick Look + Markdown / image / video / PDF / code / hex
- ⬚ SSH / SFTP / SMB / NFS / WebDAV
- ⬚ S3, Google Drive, Dropbox

---

## Phase 7 — Cross-platform (native UI per OS)

Strategy: **one Rust core (`arbor-core` + FFI/IPC), native UI per platform** — not a single lowest-common-denominator web shell as the long-term UX. Shared session, FS, search, agent-runner, and diff schemas live in core so features land once and surface everywhere.

### Linux

- ⬚ Native Linux UI track (toolkit TBD: e.g. iced / GTK / Slint — choose when Phase 0–3 APIs stabilize)
- ⬚ Packaging: `.deb` / AppImage / Flatpak (pick primary after first usable build)
- ⬚ Terminal host compatible with common VTE / GPU terminals; Ghostty when available
- ⬚ Desktop integration: trash, mime types, file manager replace optional

### Windows

- ⬚ Native Windows UI track (toolkit TBD: e.g. WinUI / iced / Slint)
- ⬚ Packaging: `.msix` and/or portable `.zip` + winget later
- ⬚ PowerShell / Windows Terminal / Ghostty-on-Windows awareness for agent/terminal panes
- ⬚ Recycle Bin, drive roots, long-path awareness

### Shared for every port

- ⬚ Parity checklist: browse, search, multi-window session restore, quick diff, terminal + agent runners, settings schema
- ⬚ Rust plugin ABI + Lua / Python / JS scripting hosts
- ⬚ CI matrix: `cargo test` on Linux / Windows / macOS

---

## Distribution & updates (macOS today)

No Apple Developer Program / notarization. See [RELEASES.md](RELEASES.md).

- ✓ Release process docs (`docs/RELEASES.md`)
- ✓ macOS packaging script (`scripts/package-macos.sh`)
- ✓ Homebrew cask in-repo (`Casks/arbor.rb`)
- ✓ GitHub Releases with packaged ZIP assets (`gh release create`)
- ⬚ In-app **Check for Updates…** via GitHub Releases API (no Sparkle)
- ⬚ Broader macOS deployment target (v1.0.0 requires macOS 26 / Tahoe APIs)
- ⬚ Linux / Windows release channels once Phase 7 UIs exist

---

## Milestone sketch (ordering)

```text
macOS core polish → Terminal + agent runners → Multi-window sessions
        → Quick diff / Git → Automation & remotes → Linux UI → Windows UI
```

Agent runners and multi-window persistence are high leverage on macOS before investing in second/third native shells.
