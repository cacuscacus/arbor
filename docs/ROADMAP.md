# Roadmap

Status legend: ⬚ planned · ◐ in progress · ✓ done

Priorities may shift. **macOS remains the reference implementation**; other OS ports reuse `arbor-core` behind a native UI.

**Shipped through [v1.4.1](https://github.com/cacuscacus/arbor/releases/tag/v1.4.1):** Finder-class browse (windows, tabs, split, session restore, DnD, live folder refresh), embedded terminal, **agent runners** (Settings → Tools + Run Agent Here…), Help → Release History / Check for Updates, Homebrew + GitHub Releases.

**Recommended next milestone:** Phase **4** quick diff / ambient Git, or browser polish (richer session fields, FS watchers, tab reorder), or deeper Phase **2a** terminal sessions.

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
- ✓ Directory listing watchers (auto-refresh when the folder changes outside Arbor) — visible tab panes only, debounced

---

## Phase 2 — Terminal & in-window AI agents

Goal: the folder you are looking at is also a place to **work** and to **delegate work**, without leaving Arbor.

### 2a — Embedded terminal (cwd = current folder)

Shipped core in [**v1.3.0**](https://github.com/cacuscacus/arbor/releases/tag/v1.3.0); depth still open:

- ✓ Split / bottom terminal pane bound to the active directory
- ✓ When the browser navigates, offer “follow cwd” vs “keep session cwd”
- ✓ Show/hide terminal + follow preference persistence (UserDefaults)
- ◐ Shell profiles: system default via `$SHELL` today; Ghostty / explicit profile picker still planned
- ◐ Restart shell in current cwd (copy/paste via SwiftTerm); tabs / multiple sessions per window still planned
- ⬚ Session restoration after restart (scrollback policy TBD; at least cwd + profile + visible/hidden)

### 2b — Configurable AI coding tool runners

Shipped in [**v1.4.0**](https://github.com/cacuscacus/arbor/releases/tag/v1.4.0):

- ✓ Settings → Tools (⌘,) — presets, PATH detect, templates, launch host
- ✓ **Run Agent Here…** prompt sheet (context menus, Agent menu, ⇧⌘R)
- ✓ Quick Run (⌥⌘R) + embedded terminal command injection
- ✓ External host: Terminal.app / Ghostty
- ✓ **Open in Cursor** (IDE folder open; separate from Cursor Agent CLI)
- ✓ Built-in presets: OpenCode, Kimi Code, Cursor Agent (+ Custom)
- ✓ Login-shell PATH + absolute binary rewrite; Kimi `cd {folder}` templates
- ✓ Embedded terminal Close + Copy Output

Optional later: missing-binary install hints, richer Settings polish, more vendor presets.

**Product intent (aligned):**

1. Right-click folder / empty space / selection → **Run Agent Here…**, or a global shortcut → small **prompt sheet** (“organize all the files into topics”).
2. Settings → Tools defines each agent: display name, executable path (PATH detect + override), **argv template** with placeholders such as `{folder}`, `{prompt}`, `{selection}`, and host (`embedded terminal` default | `Ghostty` / `Terminal.app` / …).
3. Arbor expands the template and runs the command in the focused pane’s cwd (or the clicked folder), so the agent TUI stays visible — no silent background jobs in v1.

**Initial presets to prove the path (user-testable locally):**

| Preset | Notes |
|--------|--------|
| OpenCode | Detect `opencode` on PATH; argv template TBD per CLI docs |
| Kimi Code | Detect vendor CLI on PATH; argv template TBD |
| Cursor Agent | Detect Cursor CLI on PATH; argv template TBD (`folder` + `prompt` style) |
| Custom | Any executable + freestyle argv template |

Additional presets (Codex, Claude Code, Qwen, DeepSeek, …) are the same mechanism once templates are known.

Each preset stores: display name, executable, argv template, env overrides, working-directory policy (`browser cwd` | `clicked folder` | `project root` | fixed path), and launch host (embedded vs external terminal app).

**User flows:**

1. **Agent prompt** — shortcut / context menu → prompt sheet → run configured CLI with `{folder}` + `{prompt}` (+ optional `{selection}`).
2. **Quick run** — start agent REPL / TUI in cwd with no prompt (empty `{prompt}` / alternate template).
3. **Plain terminal** — normal shell in cwd (Phase 2a).

**Guardrails:**

- Agent I/O stays in a terminal the user can see.
- Settings → Tools: enable/disable presets, paths, templates, default agent, shortcuts, launch host.
- Never ship API keys in-repo; agents use the user’s own CLIs / auth.

**Suggested v1.4.0 cut (draft):**

1. Settings window → **Tools** pane (persist presets to Application Support / UserDefaults)
2. Built-in templates for **OpenCode**, **Kimi**, **Cursor Agent** + Custom (templates verified against installed CLIs — see research note below)
3. Context menu **Run Agent Here…** + menu/shortcut → prompt sheet
4. Default launch into **embedded terminal**; per-preset override to Ghostty / Terminal.app
5. PATH detection with manual path override when missing

Out of scope for first cut: Arbor-native agentic loop, API-provider chat UI, silent background agents, key vaults.

**CLI research (this machine, 2026-08-05):**

| Tool | Binary found | Interactive (TUI) with prompt | Notes |
|------|--------------|-------------------------------|--------|
| OpenCode | `/opt/homebrew/bin/opencode` (1.18.9) | `opencode --prompt "{prompt}" "{folder}"` | Also `opencode run "{prompt}" --dir "{folder}"` = non-interactive. Prefer TUI + `--prompt` for Arbor. |
| Kimi Code | `~/.kimi-code/bin/kimi` (0.31.1) | `kimi` in cwd opens TUI; **`-p/--prompt` is print-only (no TUI)** | **Decision:** prompt sheet → `kimi -p "{prompt}"` with cwd=`{folder}`. Quick Run → `kimi` TUI. |
| Cursor IDE | `/opt/homebrew/bin/cursor` | N/A (opens editor) | **Decision:** separate non-agent action **Open in Cursor** → `cursor "{folder}"`. |
| Cursor Agent | not on PATH (`agent` / `cursor-agent`) | Install separately; then `agent "{prompt}"` in cwd | Optional preset once installed. Not the same binary as `cursor`. |

Draft default argv templates (shell-quoted expansion later):

```text
OpenCode:           opencode --prompt "{prompt}" "{folder}"
Kimi (prompt):      cd {folder} && kimi -p "{prompt}"   # print/auto mode (cwd via cd)
Kimi (quick):       cd {folder} && kimi              # TUI
Cursor Agent:       agent "{prompt}"            # cwd={folder}; requires Agent CLI
Open in Cursor IDE: cursor "{folder}"           # separate action, not an agent runner
Custom:             {executable} …user template…
```

Quick Run (no prompt): OpenCode `opencode "{folder}"`, Kimi `kimi`, Cursor Agent `agent`.

---

## Phase 3 — Multi-window, tabs, split view & session persistence

Goal: Arbor feels like a real desktop app across restarts and crashes — Finder-class windowing.

Largely shipped across [v1.1.0](https://github.com/cacuscacus/arbor/releases/tag/v1.1.0)–[v1.3.1](https://github.com/cacuscacus/arbor/releases/tag/v1.3.1).

### Windows

- ✓ **New Window** from File menu (⌘N) and Dock right-click menu; clones the frontmost / last-focused folder
- ✓ Independent windows (separate navigation / selection / view state; shared favorites)
- ✓ Dock click with no open windows restores a **single** window (reopen vs SwiftUI default de-duplicated)
- ✓ Open window from a selected folder (“Open in New Window”)
- ◐ Persist per-window: frame, tabs, pane cwds, focused pane, selected tab (not yet: sidebar width, per-pane view mode/sort if they diverge from app defaults, richer terminal session fields)
- ⬚ Persist global: tool presets, default agent, appearance preferences schema (favorites already persist)
- ✓ Restore session on launch (“Reopen windows”); safe degrade if a path vanished
- ✓ Crash / forced-quit: write state atomically so a restart restores the last good snapshot

### Tabs

- ✓ Tab bar with open / close; ⌘T new tab, ⌘W close tab (window when last tab); Finder-style floating pill island
- ✓ Each tab owns its own navigation stack; selection and view mode preserved while switching (inactive browsers stay mounted)
- ⬚ Drag-reorder tabs
- ⬚ Drag folder onto tab bar / “Open in New Tab”
- ⬚ Optional: merge all windows into tabs / move tab to new window

### Split view

- ✓ Horizontal split (primary)
- ⬚ Vertical split as follow-up
- ✓ Each pane has its own cwd, selection, and history
- ✓ Drag-and-drop between panes (copy/move; pane-root drop + cross-pane listing refresh in [v1.3.1](https://github.com/cacuscacus/arbor/releases/tag/v1.3.1))
- ✓ “Open in Split” from selection (browser / Favorites); View → Toggle Split View (⌘\) / Close Split View

Implementation note: macOS first (SwiftUI `WindowGroup` + tab/split containers + Codable session store). Other OS ports implement the same **session schema** from `arbor-core` so behavior matches.

---

## Phase 4 — Developer mode & quick file diff

Ambient Git + a fast two-file compare — the “I’m in a repo” feeling without becoming a full IDE.

- ⬚ Git status badges in the list / sidebar; detect repos for a sidebar section
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

- ⬚ Arbor-native agentic loop / NL → Arbor actions with confirmation
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
- ✓ [v1.2.0](https://github.com/cacuscacus/arbor/releases/tag/v1.2.0) — Help → Release History
- ✓ [v1.3.0](https://github.com/cacuscacus/arbor/releases/tag/v1.3.0) — tabs, split view, session restore, embedded terminal, Check for Updates, Open in New Window
- ✓ [v1.3.1](https://github.com/cacuscacus/arbor/releases/tag/v1.3.1) — split DnD onto pane root + cross-pane listing refresh without scroll reset
- ✓ [v1.4.0](https://github.com/cacuscacus/arbor/releases/tag/v1.4.0) — agent runners (Settings → Tools, Run Agent Here…, Open in Cursor)
- ✓ [v1.4.1](https://github.com/cacuscacus/arbor/releases/tag/v1.4.1) — live folder listing refresh for visible panes
- ✓ [v1.4.2](https://github.com/cacuscacus/arbor/releases/tag/v1.4.2) — Dock New Window opens on the current virtual desktop
- ✓ [v1.4.8](https://github.com/cacuscacus/arbor/releases/tag/v1.4.8) — icon view Quick Look thumbnails
- ✓ [v1.4.7](https://github.com/cacuscacus/arbor/releases/tag/v1.4.7) — icon view precise hit targets + marquee
- ✓ [v1.4.6](https://github.com/cacuscacus/arbor/releases/tag/v1.4.6) — icon view toolbar glass underlap fix
- ✓ [v1.4.5](https://github.com/cacuscacus/arbor/releases/tag/v1.4.5) — smoother scrolling + AppKit icon virtualization
- ✓ [v1.4.4](https://github.com/cacuscacus/arbor/releases/tag/v1.4.4) — Sort By + Finder-like hidden-file dimming
- ✓ [v1.4.3](https://github.com/cacuscacus/arbor/releases/tag/v1.4.3) — Show Hidden Files (⌘⇧., persisted)
- ✓ Centralized [`CHANGELOG.md`](../CHANGELOG.md) + in-app **Help → Release History** (fetches from GitHub `main`)
- ✓ In-app **Check for Updates…** via GitHub Releases API (no Sparkle)
- ⬚ Broader macOS deployment target (still requires macOS 26 / Tahoe APIs)
- ⬚ Linux / Windows release channels once Phase 7 UIs exist

---

## Milestone sketch (ordering)

```text
✓ v1.0.0 browser MVP
✓ v1.1.0 multi-window (New Window / Dock)
✓ v1.2.0 Help → Release History (CHANGELOG.md)
✓ v1.3.0 tabs, split view, session restore, embedded terminal,
  Check for Updates, Open in New Window
✓ v1.3.1 split DnD / listing refresh fixes
✓ v1.4.0 agent runners (Phase 2b)
✓ v1.4.1 live folder listing refresh
✓ v1.4.2 Dock New Window on current Space
✓ v1.4.8 icon view Quick Look thumbnails
✓ v1.4.7 icon view precise hit targets + marquee
✓ v1.4.6 icon view toolbar underlap fix
✓ v1.4.5 smoother scrolling + AppKit icons
✓ v1.4.4 Sort By + hidden-file dimming
✓ v1.4.3 Show Hidden Files (⌘⇧.)
  → next: quick diff / Git (Phase 4), browser polish,
     richer terminal sessions → remotes / preview → Linux / Windows
```

Polish backlog (can ship interleaved as minor releases): richer session fields, tab reorder, Open in New Tab, FS watchers depth/polish, vertical split, shell profile picker, more agent presets, manual Refresh (⌘R).
