# Changelog

All notable changes to Arbor are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

This file is the **source of truth** for release history. The macOS app loads it
from the GitHub repository (Help → Release History). Maintainers update this file
in the same commit as each version bump — see [docs/RELEASES.md](docs/RELEASES.md).

## [Unreleased]

### Added

- Help → **Check for Updates…** compares the installed version to the latest GitHub Release (open release page / copy `brew upgrade --cask arbor`)
- Context menu **Open in New Window** for a selected folder (browser and Favorites sidebar)

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
