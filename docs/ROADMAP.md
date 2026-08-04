# Roadmap

Status legend: ⬚ planned · ◐ in progress · ✓ done

Priorities may shift. **macOS remains the reference implementation**; other OS ports reuse `arbor-core` behind a native UI.

---

## Phase 0 — Foundation

- ✓ Repository scaffold (Cargo workspace, docs, licenses)
- ✓ Public GitHub repository ([cacuscacus/arbor](https://github.com/cacuscacus/arbor))
- ✓ Homebrew / GitHub Releases shipping path (see [RELEASES.md](RELEASES.md))
- ✓ PR test gate (`./scripts/dev-check.sh` + GitHub Actions)
- ✓ `arbor-core` directory listing API (+ tests)
- ✓ `arbor-ffi` minimal C ABI (`list_dir`, version)
- ✓ SwiftUI shell MVP: sidebar, list/icon views, search, DnD, undo ([v1.0.0](https://github.com/cacuscacus/arbor/releases/tag/v1.0.0))
- ⬚ Move remaining FS work from Swift into `arbor-core` / FFI
- ◐ Keyboard navigation (arrows, Enter, Backspace, `/` search — keep hardening)
- ✓ `arbor-cli` for smoke tests without UI

---

## Phase 1 — Navigation & search

- ✓ Favorites (sidebar, shared across windows, persisted)
- ⬚ Recents, Volumes, Bookmarks, History
- ✓ Back / Forward navigation stack
- ⬚ Directory tree
- ◐ Filename search (`fd` / Spotlight / walk in the macOS app; not yet driven by `arbor-core`)
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

Related later work in Phase 5 (NL → Arbor-native actions) complements this; Phase 2 is **bring-your-own agent CLI inside Arbor’s folder context**.

---

## Phase 3 — Multi-window, tabs, split view & session persistence

Goal: Arbor feels like a real desktop app across restarts and crashes — Finder-class windowing.

### Windows

Shipped in [**v1.1.0**](https://github.com/cacuscacus/arbor/releases/tag/v1.1.0):

- ✓ **New Window** from File menu (⌘N) and Dock right-click menu; clones the frontmost / last-focused folder
- ✓ Independent windows (separate navigation / selection / view state; shared favorites)
- ✓ Dock click with no open windows restores a **single** window (reopen vs SwiftUI default de-duplicated)
- ⬚ Open window from a selected folder (“Open in New Window”)
- ⬚ Persist per-window: frame (position/size/screen), sidebar width, view mode, sort, cwd, optional terminal visibility
- ⬚ Persist global: favorites, tool presets, default agent, appearance
- ⬚ Restore session on launch (“Reopen windows”); safe degrade if a path vanished
- ⬚ Crash / forced-quit: write state atomically so a restart restores the last good snapshot

### Tabs (planned)

Finder-style tabs inside a window so one frame can host multiple folders:

- ⬚ Tab bar with open / close / reorder; ⌘T new tab, ⌘W close tab (window when last tab)
- ⬚ Each tab owns its own navigation stack, selection, and view mode
- ⬚ Drag folder onto tab bar / “Open in New Tab”
- ⬚ Optional: merge all windows into tabs / move tab to new window

### Split view (planned)

Two (later more) folder panes in one window for side-by-side browsing:

- ⬚ Horizontal split (primary); vertical split as follow-up
- ⬚ Each pane has its own cwd, selection, and history
- ⬚ Drag-and-drop between panes (copy/move with same semantics as between windows)
- ⬚ “Open in Split” from selection or tab

Implementation note: macOS first (SwiftUI `WindowGroup` + tab/split containers + Codable session store). Other OS ports implement the same **session schema** from `arbor-core` so behavior matches.

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
- ✓ [v1.0.0](https://github.com/cacuscacus/arbor/releases/tag/v1.0.0) — initial Homebrew / browser MVP
- ✓ [v1.1.0](https://github.com/cacuscacus/arbor/releases/tag/v1.1.0) — multi-window (File + Dock New Window)
- ⬚ In-app **Check for Updates…** via GitHub Releases API (no Sparkle)
- ⬚ Broader macOS deployment target (still requires macOS 26 / Tahoe APIs)
- ⬚ Linux / Windows release channels once Phase 7 UIs exist

---

## Milestone sketch (ordering)

```text
✓ v1.0.0 browser MVP
✓ v1.1.0 multi-window (New Window / Dock)
  → next: tabs / split / “Open in New Window” / session restore
  → Terminal + agent runners → Quick diff / Git
  → Automation & remotes → Linux UI → Windows UI
```

Phase 3 window **basics** are done; tabs, split view, and session persistence are the remaining Phase 3 work before heavier terminal / agent investment if windowing UX is still the bottleneck.
