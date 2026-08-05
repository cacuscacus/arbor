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

Shipping and update policy (GitHub Releases, Homebrew tap, in-app **Check for Updates…** — no Sparkle / no Apple notarization): [`docs/RELEASES.md`](../../docs/RELEASES.md).

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

### Multi-window / tabs / split / terminal

- **File → New Window** (⌘N) and Dock **New Window**; clones frontmost / last-focused folder
- Right-click a folder (browser or Favorites) → **Open in New Window**
- **Tabs** float as a glass pill island in the **detail column** (sidebar stays full-height): open with ⌘T or the **+** control; close with ⌘W (last tab closes the window); pill island appears once you have more than one tab
- **Split**: View → Toggle Split (⌘\) / **Open in Split** on folders; sidebar drives the focused pane
- **Session restore**: quit/relaunch restores frames, tabs, and split pane folders (`~/Library/Application Support/Arbor/session.json`)
- **Embedded terminal** (⌘J / ⌃\`): SwiftTerm PTY with Follow Folder + Restart; canvas insets text from the edges

### Agents / Settings

- **Arbor → Settings…** (⌘,) → **Tools**: enable presets, edit argv templates (`{folder}` `{prompt}` `{selection}`), choose Embedded / Terminal.app / Ghostty
- **Agent → Run Agent Here…** (⇧⌘R) or folder context menu → prompt sheet → runs in the configured host
- **Agent → Quick Run Agent** (⌥⌘R) uses the default tool with its quick-run template
- **Open in Cursor** opens the folder in Cursor IDE (not the Cursor Agent CLI)

### Help

- **Help → Check for Updates…** — compares `CFBundleShortVersionString` to the latest GitHub Release; opens the release page or copies `brew upgrade --cask arbor` (does not auto-install)
- **Help → Release History…** — loads [`CHANGELOG.md`](../../CHANGELOG.md) from the public GitHub repo (`main`)
- **Help → View Releases on GitHub** — opens the Releases page in a browser
