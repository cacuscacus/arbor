# Changelog

All notable changes to Arbor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

This file is the **source of truth** for release history. The macOS app loads it
from the GitHub repository (Help → Release History). Maintainers update this file
in the same commit as each version bump — see [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

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

[Unreleased]: https://github.com/cacuscacus/arbor/compare/v1.4.4...HEAD
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
