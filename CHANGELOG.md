# Changelog

All notable changes to Arbor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

This file is the **source of truth** for release history. The macOS app loads it
from the GitHub repository (Help → Release History). Maintainers update this file
in the same commit as each version bump — see [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Added

- **Interactive SSH auth**: passwords and key passphrases prompt a secure in-app sheet via an OpenSSH askpass bridge; secrets can be **remembered in the Keychain** and are then answered automatically (entries are only readable by Arbor)
- **Per-profile identity file** (`identityFile`, like `ssh -i`) with `IdentitiesOnly`, configurable in the SSH location JSON
- **Host-key rotation flow**: when a recorded host key changes, the verification sheet now shows recorded vs. offered fingerprints with an explicit **Replace and Connect** action (`ssh-keygen -R` + re-trust), instead of a dead end
- **Recursive delete for SSH locations**: folders delete bottom-up over SFTP; the Delete key routes to the permanent-delete confirmation when a provider has no Trash

### Fixed

- **SSH transport hang on macOS 26**: `FileHandle.read(upToCount:)` never returns on a live pipe (even `/bin/cat` hangs); the transport and askpass bridge now use `availableData`. SSH connections never completed before this
- The SFTP helper replaced the `openssh` crate (which hardcodes `BatchMode=yes`) with a direct `ssh -s <host> sftp` spawn, so interactive auth works and stderr diagnostics still reach the app's error classification
- Helper environment now inherits the full app environment (agent socket included) instead of replacing it
- Repeated SSH retries no longer deadlock askpass prompts behind one another (per-connection threads + queued prompt presentation)

### Fixed

- Quick Look: panel data source no longer routes through `MainActor.assumeIsolated` (lock-protected storage instead), the arrow-key sync matches by URL so mixed/remote listings select the right row, and the index-change callback is released when the panel closes
- Document preview: the local-asset scheme handler is now fully thread-safe (`vendorCache` behind a lock, document root bound explicitly) with no main-actor assumption
- Eliminated all build warnings (concurrency isolation in `MarkdownHTMLRenderer`, `DocumentPreviewController`, `ContentView`)

### Changed

- `BreadcrumbBar` extracted from `FileBrowserView` into its own file; `FilenameSearchPattern` extracted from `SearchService`
- Pure Foundation logic (Markdown renderer, source-language detection, Go to Folder resolver, search pattern) now has 47 SPM unit tests running in CI via a new `swift test` job

## [1.6.1] — 2026-11-13

### Added

- **Open Terminal Here** in the folder, empty-space, and sidebar context menus, placed above **Run Agent Here…**; it replaces the previous **New Terminal Here** label

## [1.6.0] — 2026-11-13

### Added

- **Rendered Markdown preview** for `.md` / `.markdown` — headings, lists, tables, quotes, fenced code, links and images (relative, `../`, remote), with zoom (⌘+ ⌘− ⌘0) and reload (⌘R)
- **Mermaid diagrams** in Markdown (flowchart, sequence, gantt, class, state, pie, …) via a bundled offline runtime, with a readable error for invalid diagrams
- **Quick edit** in both previews: ⌘E switches to a monospaced editor, ⌘S saves and re-renders, unsaved changes prompt on close
- **Syntax-highlighted code preview** for 35+ languages (JS/TS/JSX/TSX, Python, Swift, Rust, Go, Ruby, PHP, Java, Kotlin, C/C++/C#, HTML/XML, CSS/SCSS, JSON, YAML, TOML/INI, GraphQL, shell, SQL, Dockerfile, Makefile, …) with language, line count and size in the header; detection by extension, file name and shebang
- **Quick Look** (Space / ⌘Y) for local files and folders; Up/Down walk the listing from the panel and the browser selection follows
- **Go to Folder…** (⇧⌘G) accepting absolute paths, `~`, and names relative to the current folder, with Tab completion and file reveal
- **Arrow navigation** from the search field into the results (Down/Up, then Return)
- **SSH remote locations** (MVP): provider-neutral `ItemRef`/location model, SFTP browsing and basic mutations, host-key verification, OpenSSH config discovery, reconnectable favorites and sessions

### Changed

- **Global search uses Spotlight first** (~0.3 s instead of a 5–15 s cold `fd` walk of `$HOME`); `fd` remains the backend for the current folder
- **Search semantics are Finder-like**: `.gitignore`d files are searchable, bundle internals are not, and a glob-looking name falls back to a literal match (`corchetes[1].txt` finds itself)
- **View menu** is a single menu again (macOS 26 duplicated it and dropped every custom command); split toggle is **⌘⌥S** so it works on non-US keyboard layouts
- File menu keeps **Close / Close All** (⌘W) alongside Quick Look

### Fixed

- Search could hang forever: `fd`/`mdfind` output was read after `waitUntilExit`, deadlocking once the 64 KB stdout pipe filled; output is now drained while the process runs
- Cancelling a search left the child process running; it is now terminated
- Filenames containing newlines were split and never found (NUL-delimited output now)
- Double-click in list view did not open folders (SwiftUI `Table` is outline-backed on macOS 26 and the installer rejected it)
- Return in the Go to Folder sheet was not delivered in optimized builds; the sheet now uses an AppKit key monitor
- The keyboard stopped reaching the listing after closing the Go to Folder sheet

## [1.5.0] — 2026-08-15

### Added

- **Quick Diff** compares exactly two selected text files from the context menu or with `⌘D`
- Side-by-side and unified layouts with line-level additions, removals, and changes
- Independent horizontal scrolling per side-by-side pane with synchronized vertical navigation
- Clear guards for folders, binary files, unsupported encodings, oversized files, and excessive line counts

### Fixed

- Icon-view context menus are built when opened so multi-selection actions always reflect the current selection

## [1.4.9] — 2026-08-14

### Changed

- File and folder context menus now label the full-path clipboard action explicitly as **Copy File Path** (or **Copy File Paths** for multi-selection)

## [1.4.8] — 2026-08-14

### Added

- Icon view shows **Quick Look thumbnails** for images, PDFs, and videos (Finder-like content previews); list view keeps compact type icons

### Fixed

- Selection chrome hugs the thumbnail’s aspect ratio instead of filling the grid cell

## [1.4.7] — 2026-08-11

### Fixed

- Icon view selection / hit targets hug the **icon and name** again (Finder-like); cell padding starts marquee instead of selecting or dragging the file

## [1.4.6] — 2026-08-11

### Fixed

- Restore Liquid Glass / soft scroll-edge underlap under the toolbar in **icon view** (AppKit grid was safe-area clipped and painted opaque)

## [1.4.5] — 2026-08-11

### Changed

- **Much smoother scrolling** in list and icon views — stop rebuilding the browser on every scroll tick; cache file icons; lighten scroll/install hot paths
- **Icon view** now uses AppKit `NSCollectionView` virtualization (Finder-like) instead of SwiftUI `LazyVGrid`

### Fixed

- Icon-view keyboard Return/Delete when the grid has focus; drop onto folders in icon view

## [1.4.4] — 2026-08-11

### Added

- **Sort By** — toolbar menu, View → Sort By, and list column headers; Name / Kind / Date Modified / Date Created / Size, plus Keep Folders on Top; shared live across split panes and tabs in the same window

### Changed

- Hidden files shown via Show Hidden Files now render at Finder-like **semi-transparent** opacity in list and icon views

## [1.4.3] — 2026-08-11

### Added

- **Show Hidden Files** — View menu toggle and Finder-style **⌘⇧.**; preference is app-wide and persisted across launches (listings and search)

## [1.4.2] — 2026-08-07

### Fixed

- Dock **New Window** (and Dock reopen with no windows) opens on the **current virtual desktop**, even when another Arbor window lives on a different Space

## [1.4.1] — 2026-08-06

### Fixed

- Folder listings **auto-refresh** when files change outside Arbor (visible tab panes only, debounced), plus a reload when the app becomes active again

## [1.4.0] — 2026-08-05

Bring-your-own AI coding CLIs into the folder you’re browsing — Settings-configured runners, prompt sheet, and embedded/external terminal hosts.

### Added

- **Settings → Tools** (⌘,): OpenCode, Kimi Code, Cursor Agent, and Custom presets with PATH detection, path override, argv templates (`{folder}`, `{prompt}`, `{selection}`), and launch host (Embedded Terminal / Terminal.app / Ghostty)
- **Run Agent Here…** from folder context menus (browser, empty space, Favorites) and the **Agent** menu (⇧⌘R); prompt sheet with command preview; empty prompt = Quick Run
- **Quick Run Agent** (⌥⌘R) launches the default tool’s quick-run template
- **Open in Cursor** opens the target folder in Cursor IDE (separate from Cursor Agent CLI)
- Embedded terminal **Close** and **Copy Output** header actions (alongside Restart / Follow Folder)

### Fixed

- Embedded shells start as login+interactive (`zsh -il`) with Homebrew on PATH; agent launches rewrite bare binaries to absolute paths when detected
- Kimi templates `cd` into `{folder}` first (Kimi uses process cwd; OpenCode already took the folder as an arg)

## [1.3.1] — 2026-08-05

### Fixed

- Split view: drop files onto the other pane’s **current folder** (empty space / listing chrome), not only onto nested folder rows
- After a cross-pane move/copy/trash/rename/undo, **every pane** showing an affected folder reloads so the source side does not stay stale
- Focusing a split pane no longer remounts the browser (which re-ran `onAppear` and **reset scroll**)

## [1.3.0] — 2026-08-05

Major windowing and workspace update: tabs, split view, session restore, embedded
terminal, Check for Updates, and Open in New Window — plus Liquid Glass polish for
Tahoe.

### Added

- Finder-style **tabs** in a window: floating glass pill island in the detail column (sidebar stays full-height), trailing **+**, ⌘T new tab (clones current folder), ⌘W closes tab (closes window on last tab); pill island appears once you have more than one tab; inactive tab browsers stay mounted so selection and view state are preserved
- Horizontal **split view** per tab: two folder panes (`HSplitView`), each with its own navigation; **Open in Split** from folder context menus; **View → Toggle Split View** (⌘\) / **Close Split View**; sidebar and focused-scene values follow the focused pane
- Split titles show both pane folders as `left | right` (toolbar + tab pills) with the focused side semibold and the other italic/secondary; clicking a name focuses that pane
- **Session restore**: quit/relaunch reopens browser windows with saved frames, tabs, split pane folder URLs, focused pane, and selected tab; missing paths fall back to Home; state is written atomically to `~/Library/Application Support/Arbor/session.json`
- **Embedded terminal** pane (SwiftTerm PTY): bottom split bound to the focused browser folder; **View → Show/Hide Terminal** (⌘J or ⌃\`); **Follow Folder** (default on) cds the shell when the browser navigates; **Restart** recreates the shell in the current folder; show/hide and follow preferences persist in UserDefaults; PTY canvas insets glyph text from the pane edges
- Help → **Check for Updates…** compares the installed version to the latest GitHub Release (open release page / copy `brew upgrade --cask arbor`)
- Context menu **Open in New Window** for a selected folder (browser and Favorites sidebar)
- Back/Forward keeps each folder’s **vertical scroll position** (icon grid and list) per pane history, Finder-style

### Fixed

- Toolbar keeps Liquid Glass translucency with folder content scrolling behind chrome
- Window toolbar attaches outside `HSplitView` so split focus no longer flattens glass into an opaque bar
- Split panes use the native soft scroll-edge underlap; Forward scroll restore no longer races content remount

## [1.2.0] — 2026-08-04

### Added

- Help → **Release History…** loads [`CHANGELOG.md`](CHANGELOG.md) from the public GitHub repo
- Help → **View Releases on GitHub**
- Release History marks the **Installed** version next to the matching changelog section

### Fixed

- Release History changelog layout no longer collapses into a single run-on paragraph

## [1.1.0] — 2026-08-04

### Added

- Finder-like **New Window** from File → New Window (⌘N)
- Dock right-click menu item **New Window**
- New windows clone the frontmost / last-focused folder
- Shared favorites across windows; independent navigation and selection per window

### Fixed

- Closing all windows and clicking the Dock icon no longer opens two windows

## [1.0.0] — 2026-08-04

### Added

- Initial public macOS release (Apple silicon, macOS 26 Tahoe+)
- Finder-like browser: sidebar favorites, list and icon views, search, drag-and-drop, undo
- Homebrew cask install (`cacuscacus/arbor`)
- GitHub Releases packaging (`Arbor-*-macos-arm64.zip`)

[Unreleased]: https://github.com/cacuscacus/arbor/compare/v1.6.1...HEAD
[1.6.1]: https://github.com/cacuscacus/arbor/releases/tag/v1.6.1
[1.6.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.6.0
[1.5.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.5.0
[1.4.9]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.9
[1.4.8]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.8
[1.4.7]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.7
[1.4.6]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.6
[1.4.5]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.5
[1.4.4]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.4
[1.4.3]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.3
[1.4.2]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.2
[1.4.1]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.1
[1.4.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.4.0
[1.3.1]: https://github.com/cacuscacus/arbor/releases/tag/v1.3.1
[1.3.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.3.0
[1.2.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.2.0
[1.1.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.1.0
[1.0.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.0.0
