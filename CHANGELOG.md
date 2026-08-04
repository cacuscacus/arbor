# Changelog

All notable changes to Arbor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

This file is the **source of truth** for release history. The macOS app loads it
from the GitHub repository (Help → Release History). Maintainers update this file
in the same commit as each version bump — see [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Added

- Finder-style **tabs** in a window: tab bar, ⌘T new tab (clones current folder), ⌘W closes tab (closes window on last tab); inactive tab browsers stay mounted so selection and view state are preserved
- Horizontal **split view** per tab: two folder panes side by side (`HSplitView`), each with its own navigation; **Open in Split** from folder context menus; **View → Toggle Split View** (⌘\) / **Close Split View**; sidebar and focused-scene values follow the focused pane
- Help → **Check for Updates…** compares the installed version to the latest GitHub Release (open release page / copy `brew upgrade --cask arbor`)
- Context menu **Open in New Window** for a selected folder (browser and Favorites sidebar)
- **Session restore**: quit/relaunch reopens Arbor browser windows with saved frames, tabs, split pane folder URLs, focused pane, and selected tab; missing paths fall back to Home; state is written atomically to `~/Library/Application Support/Arbor/session.json`
- **Embedded terminal** pane (SwiftTerm PTY): bottom split bound to the focused browser folder; **View → Show/Hide Terminal** (⌘J or ⌃\`); **Follow Folder** toggle (default on) cds the shell when the browser navigates; **Restart** recreates the shell in the current folder; show/hide and follow preferences persist in UserDefaults
- Tab strip sits in the **detail column only** (Finder-style; sidebar stays full-height) with a trailing **+** control
- Terminal PTY canvas insets glyph text from the pane edges

### Fixed

- Tab strip uses a system `safeAreaBar` (no custom materials) so the toolbar keeps Liquid Glass translucency with folder content scrolling behind it

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

[Unreleased]: https://github.com/cacuscacus/arbor/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.2.0
[1.1.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.1.0
[1.0.0]: https://github.com/cacuscacus/arbor/releases/tag/v1.0.0
