# Roadmap

Status legend: ⬚ planned · ◐ in progress · ✓ done

Priorities may shift. **macOS remains the reference implementation**; other OS ports reuse the provider contracts and pure logic behind a native UI (see [ARCHITECTURE.md](ARCHITECTURE.md) for the current split).

**Shipped through [v1.4.1](https://github.com/cacuscacus/arbor/releases/tag/v1.4.1):** Finder-class browse (windows, tabs, split, session restore, DnD, live folder refresh), embedded terminal, **agent runners** (Settings → Tools + Run Agent Here…), Help → Release History / Check for Updates, Homebrew + GitHub Releases.

**Recommended next milestone:** Phase **4** quick diff / ambient Git, or browser polish (richer session fields, FS watchers, tab reorder), or deeper Phase **2a** terminal sessions.

**Remote SSH (Phase 6):** feasibility analysis captured in [`docs/REMOTE-SSH.md`](REMOTE-SSH.md) — high product fit, high architecture risk; needs `FileProvider` / `ItemRef` before first remote pane. Not the immediate cut; track as the first hard remote provider once local FS is abstracted.

---

## Phase 0 — Foundation

- ✓ Repository scaffold (Cargo workspace, docs, licenses)
- ✓ Public GitHub repository ([cacuscacus/arbor](https://github.com/cacuscacus/arbor))
- ✓ Homebrew / GitHub Releases shipping path (see [RELEASES.md](RELEASES.md))
- ✓ PR test gate (`./scripts/dev-check.sh` + GitHub Actions)
- ✓ `arbor-core` directory listing API (+ tests)
- ✓ `arbor-ffi` minimal C ABI (`list_dir`, version)
- ✓ SwiftUI shell MVP: sidebar, list/icon views, search, DnD, undo ([v1.0.0](https://github.com/cacuscacus/arbor/releases/tag/v1.0.0))
- ⬚ Grow portable FS/search contracts behind the `FileProvider` boundary; promote code into `arbor-core` only where a shared implementation pays off (sidecars first — see ARCHITECTURE.md)
- ◐ Keyboard navigation (arrows, Enter, Backspace, `/` search — keep hardening)
- ✓ `arbor-cli` for smoke tests without UI

---

## Phase 1 — Navigation & search

- ✓ Favorites (sidebar, shared across windows, persisted)
- ⬚ Recents, Volumes (with Eject), Bookmarks, History
- ✓ Back / Forward navigation stack (with scroll-position restore)
- ⬚ Directory tree
- ◐ Filename search (`fd` / Spotlight / walk in the macOS app; not yet driven by `arbor-core`)
- ⬚ Query language: `kind:`, `ext:`, `size>`, `modified:`
- ⬚ Virtual scrolling for large directories
- ✓ Directory listing watchers (auto-refresh when the folder changes outside Arbor) — visible tab panes only, debounced

### 1a — Search reliability, guardrails & progressive scoping

Shipped in [**v1.8.0**](https://github.com/cacuscacus/arbor/releases/tag/v1.8.0). Goal: search never hangs the UI, stays responsive on huge trees, and gives instant feedback even in Global mode. Every guardrail and behavior is configurable in **Settings → Search** (opt-in / customizable, never forced).

- ✓ **Streaming + early cutoff in `SearchService`**: read incremental chunks from `mdfind` / `fd` and terminate the child process as soon as `resultLimit` valid hits (post-bundle filtering) are collected, instead of buffering full `stdout` to EOF
- ✓ **Off-main-thread `FileEntry` materialization**: build `FileEntry` values on background workers (with cancellation checks) — remove synchronous `asFileEntry()` disk `stat()`/`resourceValues` calls from `@MainActor`
- ✓ **Hard hang & loop protection**:
  - Configurable per-search timeout (default `10s`) with `SIGTERM` → `SIGKILL` escalation; return partial results + "Continue (+10s)" action on timeout
  - Node-visit cap (`maxVisited`), optional `maxDepth`, and `(st_dev, st_ino)` cycle tracking in BFS fallback directory walk (`CycleSafeDirectoryWalker`)
  - Editable exclusion list with safe Global defaults (`~/Library/Caches`, `~/Library/CloudStorage`, `.Trash`, `.git`, `node_modules`, `DerivedData`, `target`, `.build`, `Pods`) to avoid triggering iCloud/cloud downloads or TCC storms
  - Longer debounce on 1-character Global queries
- ✓ **Progressive "staircase" / concentric-ring search (configurable, on by default)**:
  - Even when **Global** is selected, resolve rings in parallel: Ring 0 (in-memory current folder children, ~1–10 ms) → Ring 1 (current folder subtree, ~20–80 ms) → Ring 2 (full Global)
  - Deduplicate by canonical `ItemRef`; always keep outer-ring results *below* inner rings so early hits never jump under the cursor
- ✓ **Informative search status UI**:
  - Persistent status bar (`SearchStatusBanner`) showing active engine/scope, live elapsed time, match count / ring breakdown, and an explicit **Stop** button (preserving partial hits)
  - Clear limit indicator (*"Showing first 500 matches"*) with inline **"Load up to 2,000"** / configurable limit presets (`200 / 500 / 2,000 / 5,000`)

### 1b — Background Search Tabs

Shipped in [**v1.8.0**](https://github.com/cacuscacus/arbor/releases/tag/v1.8.0). Goal: long or deep searches never block the user from browsing other folders.

- ✓ Lift search state from view-local `@State` into an `@Observable` `SearchSession` owned by `BrowserPane`
- ✓ Hybrid workflow:
  - `⌘F` stays lightweight and inline in the current pane, with an **`Open in Tab`** button to promote results into their own tab
  - `⌘⇧F` opens (or focuses) a dedicated **Search Tab** (plus Settings toggle to open Global searches in a new tab automatically)
- ✓ Tab pill shows search icon / live mini spinner while running + live hit badge (`124` / `500+`); closing the tab (`⌘W`) immediately cancels the underlying search process and frees memory

### 1c — Content search (`grep` / `ripgrep`)

Goal: fast, configurable text search inside files without turning Global search into an I/O storm.

- ⬚ Mode toggle in search bar: **`Name` | `Content`**
- ⬚ **Local / folder content search**: `rg --json` streaming (later promotable into `arbor-core` via `ignore` + `grep-searcher` + `grep-regex` to drop the external binary dependency), batching UI updates every ~80–120 ms
- ⬚ **Global content search**: Spotlight `kMDItemTextContent` streaming by default (fast, indexes PDFs/docs, avoids cloud-file downloads) + explicit opt-in **Deep Scan (`rg`)** with strict exclusions and clear disk-scan notice
- ⬚ **Sweet-spot limits in Settings → Search**:
  - Max file size for content grep (default `5 MB`; presets `1 MB / 5 MB / 25 MB / Unlimited`)
  - Respect `.gitignore` toggle (default ON for content, OFF for filename)
  - Max matches per file / total result cap
- ⬚ **Content-result UX**: show matching line snippet with highlight + line number; click for Quick Look / preview, double-click to open (or jump to line in editor), `Show Enclosing Folder` reveals and selects the hit

### 1d — Optional local LLM term expansion (MLX)

Goal: bridge vocabulary mismatches in filename & content search (e.g., `"factura luz"` → `edenor`, `receipt`, `electricity`, `invoice`; `"login timeout"` → `auth_session_expired`) completely offline on Apple Silicon — **strictly opt-in and off by default**.

- ⬚ **Settings → Search → Smart Expansion (MLX)**:
  - Master toggle (OFF by default — zero downloads or extra RAM unless enabled)
  - User-selectable quantized model tiers: `0.6B` (fast / low RAM), `2B` / `4B` (balanced sweet spot), `9B` (high accuracy for 32+ GB Macs), plus custom model path/ID and quantization choice (`4-bit` / `8-bit`)
  - Configurable idle unload TTL (e.g., unload weights from RAM after 2–5 min idle) and RAM budget guard
- ⬚ **Pre-implementation benchmark**: run a reproducible local eval script (~25–30 Spanish/English/code queries) across `0.6B / 2B / 4B / 9B` in `4-bit` vs `8-bit` measuring TTFT, total latency, peak RAM, and term-expansion quality to pick sensible presets
- ⬚ **Non-blocking, transparent UX & isolation**:
  - Run MLX in an isolated helper process (`arbor-llm-helper` / XPC) so memory or Metal pressure never freezes or crashes the browser UI
  - Literal search runs immediately; term expansion triggers asynchronously after typing pause (~400–500 ms) and cancels on new input
  - Display expanded terms as editable chips/pills under the search bar (one click to remove noisy terms) with stopword filtering before feeding into `fd` / `rg`

### 1e — Finder-parity UX & daily-driver polish

High-leverage desktop UX improvements identified against macOS Finder (without cloning unnecessary Finder bloat):

- ⬚ **Real Copy/Paste (`⌘C` / `⌘V` / `⌘⌥V`)**: extend `FileClipboard` beyond Cut-only and integrate with `NSPasteboard.general` so files copy/paste seamlessly between Arbor, Finder, Slack, Mail, etc.
- ⬚ **macOS muscle-memory shortcuts**: move Trash from bare `Delete` to `⌘⌫` (plus `⌘⌥⌫` permanent delete), add `⌘⇧N` (New Folder), `⌘I` (Get Info), `⌘O` / `⌘↓` (Open), `⌘1` / `⌘2` (List / Icons), and **type-to-select** (type-ahead) in both List and Icon views
- ⬚ **Sidebar Places cleanup**: wire `Volumes` (mounted disks/DMGs + Eject) and `Git Repositories` / `Recents`, or hide non-interactive placeholder rows until wired
- ⬚ **Compact status bar**: item count, selection count + total size, and free disk space (toggleable or inline with the breadcrumb bar)
- ⬚ **Everyday file actions & feedback**:
  - Inline New Folder / New File creation (create + enter rename directly)
  - **Compress (`.zip`) / Extract** and **Open With…** (via `NSWorkspace.urlsForApplications(toOpen:)`)
  - Transfer progress indicator + cancel button for slow local copies and SFTP jobs
  - Async recursive folder size calculation in `Get Info` (cancellable on close)
- ⬚ **Listing & search polish**:
  - ✓ `Show Enclosing Folder` available for both files and folders in search results, selecting and revealing the item (`pendingSelection`)
  - Right-click column headers in List view to toggle visible columns
  - Optional collapsible Preview/Inspector sidebar (`⌘⇧P`, reusing Quick Look / Markdown / code renderers) and/or Column View (`⌘3`)
  - Clear feedback when invoking `⌘F` on unsupported remote locations (until Phase 6e remote search lands)

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
- ✓ “Open in Split” from selection (browser / Favorites); View → Toggle Split View (⌘⌥S) / Close Split View

Implementation note: macOS first (SwiftUI `WindowGroup` + tab/split containers + Codable session store). Other OS ports implement the same **session schema** so behavior matches.

---

## Phase 4 — Developer mode & quick file diff

Ambient Git + a fast two-file compare — the “I’m in a repo” feeling without becoming a full IDE.

- ⬚ Git status badges in the list / sidebar; detect repos for a sidebar section
- ⬚ Open in Cursor / VS Code / Zed / Xcode / IntelliJ / …
- ⬚ Blame / file history (deeper Git)

### Quick diff (two-file compare)

User selects **exactly two files** (or picks “Diff with…” from a second path) → opens a **simple, readable diff viewer** optimized for fast checks, not a full merge tool.

- ✓ Side-by-side and unified views with line highlighting ([v1.5.0](https://github.com/cacuscacus/arbor/releases/tag/v1.5.0))
- ⬚ Word-level highlighting inside changed lines
- ✓ Binary / huge-file guards with clear messaging
- ⬚ Optional: diff working tree vs HEAD for one file when inside a Git repo
- ✓ Keyboard-first: `⌘D` when exactly two files are selected; **Quick Diff…** context action

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

- ✓ Quick Look via Space / ⌘Y for local items (Up/Down walks the listing; remote previews remain capability-gated)
- ✓ **Rendered Markdown preview** for `.md` files — GFM subset, local/relative images, zoom (⌘+ ⌘− ⌘0), reload
- ✓ **Mermaid diagrams** in Markdown (bundled runtime, offline) and inline **quick edit** (⌘E / ⌘S)
- ✓ **Syntax-highlighted code preview** for 35+ languages (bundled highlight.js), with language/line/size header
- ✓ **Go to Folder…** (⇧⌘G) with `~`, relative names, Tab completion, and file reveal
- ⬚ Hex/binary previews; Markdown polish (TOC, task-list editing, print, Mermaid theme switch); code folding and “copy” action
- ⬚ SMB / NFS / WebDAV (additional providers once the abstraction exists)
- ⬚ S3, Google Drive, Dropbox

### 6 — SSH / SFTP as first-class locations

Analysis (2026-08-15): [`REMOTE-SSH.md`](REMOTE-SSH.md). Intent: sidebar **SSH locations**, credentials (OpenSSH config + agent + Keychain), split local↔remote, DnD translated to SFTP/rsync jobs, remote terminal / agents on the connected host.

| Sub-phase | Goal | Status |
|-----------|------|--------|
| **6a** Provider abstraction | `ItemRef` / Location / Volume / Connection; `LocalFileProvider`; migrate listing, mutations, undo, favorites, sessions | ✓ complete — provider-neutral browser/actions/execution requests, async provider-routed undo, materialization boundary and capability gating |
| **6b** SSH MVP | Connect UI, host keys, SFTP browse + basic mutations, reconnectable favorites/sessions, poll refresh | ✓ complete — key/agent/password/passphrase auth (askpass bridge + Keychain), new-host trust and changed-key rotation flows, recursive delete, identity-file profiles, 5 s poll refresh |
| **6c** Cross-location transfers | Job engine, local↔remote DnD, custom UTType, optional rsync-over-SSH, safe move = copy+verify+delete | ⬚ planned |
| **6d** Remote terminal & agents | `ExecutionContext.remote`, `ssh -tt`, follow-folder per connection, clear host labels | ⬚ planned |
| **6e** Search / preview polish | Remote `fd`/`find`, thumbnail materialization limits, capability-aware Get Info / Open | ⬚ planned |

**Transport decision (analysis):** SFTP baseline · rsync as large-tree accelerator · OpenSSH for terminal · **not** sshfs as internal model (optional Finder mount later).

**Hard constraints:** do not fake remotes as local file URLs; capability-aware Trash / Quick Look / Show in Finder / Open in Cursor / watchers; never silent host-key accept.

---

## Phase 7 — Cross-platform (native UI per OS)

Strategy: **shared contracts, native UI per platform** — not a single lowest-common-denominator web shell. The portability boundary is the provider-neutral `FileProvider` / `ItemRef` model plus pure logic (already Foundation-only and SPM-tested); native capabilities ride Rust sidecars over stdio IPC (the `arbor-sftp-helper` pattern). Whether a full `arbor-core` runtime becomes the porting core is decided when the first port starts — grown from real shared needs (search, metadata), not by rewriting working Swift.

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
- ✓ [v1.5.0](https://github.com/cacuscacus/arbor/releases/tag/v1.5.0) — lightweight two-file Quick Diff
- ✓ [v1.4.9](https://github.com/cacuscacus/arbor/releases/tag/v1.4.9) — explicit Copy File Path context action
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
✓ v1.5.0 lightweight two-file Quick Diff
✓ v1.4.9 explicit Copy File Path context action
✓ v1.4.8 icon view Quick Look thumbnails
✓ v1.4.7 icon view precise hit targets + marquee
✓ v1.4.6 icon view toolbar underlap fix
✓ v1.4.5 smoother scrolling + AppKit icons
✓ v1.4.4 Sort By + hidden-file dimming
✓ v1.4.3 Show Hidden Files (⌘⇧.)
  → next: quick diff / Git (Phase 4), browser polish,
     richer terminal sessions
  → later: FileProvider + SSH locations (Phase 6 / REMOTE-SSH.md),
     preview → Linux / Windows
```

Polish backlog (can ship interleaved as minor releases): richer session fields, tab reorder, Open in New Tab, FS watchers depth/polish, vertical split, shell profile picker, more agent presets, manual Refresh (⌘R), Quick Look polish (space over hovered item, edit-while-previewing).
