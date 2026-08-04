# macOS App (SwiftUI)

Native shell for Arbor on macOS.

## Open in Xcode

```bash
open /Users/cacus/Workspace/arbor/apps/macos/Arbor.xcodeproj
```

Then press **▶ Run** (⌘R). Destination: **My Mac**.

## Search

Open search with the toolbar magnifying glass, **⌘F**, or **`/`**. Esc (or the panel ✕) closes it.

| | |
|---|---|
| **Folder** | Search under the current directory |
| **Global** | Search under your home folder |
| Plain text | Case-insensitive **substring** match on filenames |
| Globs | Use `*`, `?`, or `[…]` — e.g. `blabla*.json`, `*.md`, `report-??.txt` |

Results are capped at **500** hits (shown as `500+` when truncated).

### Backends (first available wins)

1. **`fd`** — preferred when installed (`brew install fd`). Substrings use `--fixed-strings`; globs use `--glob`.
2. **Spotlight (`mdfind`)** — used for Global when `fd` is missing. Filename queries via `kMDItemFSName`.
3. **Directory walk** — fallback enumerator with the same substring/glob rules (`fnmatch`).

Heavy directories such as `.git`, `node_modules`, `DerivedData`, `target`, and `.build` are skipped.

## Layout

```
apps/macos/
├── Arbor.xcodeproj
├── Arbor/
│   ├── ArborApp.swift
│   ├── Views/
│   ├── Services/          # LocalFileService, SearchService (temporary; replace with arbor-ffi)
│   ├── Models/
│   ├── Resources/
│   └── Assets.xcassets
└── README.md
```

App Sandbox is **off** for local development so the file manager can read the filesystem.

Before PRs, run `./scripts/dev-check.sh` from the repo root (see [CONTRIBUTING.md](../../CONTRIBUTING.md)). Rust / CLI tests run in GitHub Actions; SwiftUI still needs a manual smoke check in Xcode.

## Build from terminal

```bash
xcodebuild -project apps/macos/Arbor.xcodeproj -scheme Arbor -configuration Debug build
```

## Releases & updates

Shipping and update policy (GitHub Releases, Homebrew tap, planned **Check for Updates…** — no Sparkle / no Apple notarization): [`docs/RELEASES.md`](../../docs/RELEASES.md).

Package a Release ZIP:

```bash
./scripts/package-macos.sh
```

Install from this repo’s cask (after a GitHub Release exists):

```bash
brew tap cacuscacus/arbor https://github.com/cacuscacus/arbor
brew trust cacuscacus/arbor   # required on Homebrew 6+
brew install --cask arbor
```

Menu commands live in `Arbor/ArborApp.swift` (`.commands`). **v1.0.0 requires macOS 26 (Tahoe)+.**

### Multi-window

- **File → New Window** (⌘N) opens an independent browser window
- **Dock → right-click → New Window** (custom Dock menu) and **Dock → New Window** when shown
- Right-click a folder (browser or Favorites) → **Open in New Window** opens that folder in a new window
- New windows **clone the frontmost / last-focused folder**; Home if none is known
- Clicking the Dock icon with no windows open creates a new window again
- Favorites are shared across windows; navigation and selection are per-window

Session restore (positions after restart), tabs, and split view are planned — see [`docs/ROADMAP.md`](../../docs/ROADMAP.md) Phase 3.

### Help

- **Help → Release History…** — loads [`CHANGELOG.md`](../../CHANGELOG.md) from the public GitHub repo (`main`)
- **Help → View Releases on GitHub** — opens the Releases page in a browser
