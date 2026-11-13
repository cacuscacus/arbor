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
| Globs | Use `*`, `?`, or `[…]` — e.g. `blabla*.json`, `*.md`, `report-??.txt`. If a glob has no matches, the query is retried as a literal name, so `corchetes[1].txt` still finds itself. |

Results are capped at **500** hits (shown as `500+` when truncated).

### Backends

1. **This Folder → `fd`** — preferred when installed (`brew install fd`). Substrings use `--fixed-strings`; globs use `--glob`. Ignore files are **not** honoured (a `.gitignore`d build output is still searchable; dotfiles still follow **Show Hidden Files**), and output is NUL-delimited so filenames containing newlines work.
2. **Global → Spotlight (`mdfind`)** — index-backed and Finder-speed. Falls back to `fd` when the index is unavailable. Filename queries use `kMDItemFSName`; bundles are not searched internally, and Spotlight does not index dotfiles (search This Folder for those).
3. **Directory walk** — fallback enumerator with the same substring/glob rules (`fnmatch`).

Heavy directories such as `.git`, `node_modules`, `DerivedData`, `target`, `.build`, and `Pods` are skipped by the `fd` and walk backends.

## Document preview (Markdown and code)

Markdown and source-code files open in Arbor’s own viewer instead of Quick Look
(which shows them as plain text). Everything else — images, PDFs, media, `.txt` —
keeps the system Quick Look.

### Markdown

`.md` / `.markdown` files get a **rendered** preview instead of Quick Look’s plain
text: headings, lists, tables, fenced code, quotes, links and images (local,
relative, `../` and remote) are formatted like a README.

Fenced ` ```mermaid ` blocks are drawn as diagrams (flowchart, sequence, gantt,
class, state, pie, …) by a **bundled** Mermaid build — no network, no CDN.
An invalid diagram renders a readable error instead of breaking the page.

| | |
|---|---|
| Open | **Space** (or **⌘Y**) on a single `.md` file |
| Edit | **⌘E** or the **Edit** button — monospaced editor with undo |
| Save | **⌘S**, the save button, or **Done** (saves and returns to the view) |
| Cancel | **Esc** in the editor (asks before discarding changes) |
| Zoom | **⌘+** / **⌘−** / **⌘0**, or the floating − / % / + control |
| Reload | **⌘R** or the ↻ button (keeps the zoom level) |
| Close | Space, Esc, ⌘W, or the window close button (prompts if unsaved) |

Mermaid is vendored from [mermaid@11.4.1](https://github.com/mermaid-js/mermaid)
(MIT, see `Arbor/Resources/vendor/mermaid.LICENSE`) and copied into the app bundle
as a resource.

### Source code

Code files open highlighted, with a header showing the language, line count and
size. A bundled [highlight.js](https://highlightjs.org) build (BSD-3-Clause, see
`Arbor/Resources/vendor/highlight.LICENSE`) covers JavaScript, TypeScript, JSX/TSX,
Python, Swift, Rust, Go, Ruby, PHP, Perl, Lua, R, Java, Kotlin, Scala, Groovy, C,
C++, C#, Objective-C, HTML/XML/SVG, CSS/SCSS/Less, JSON, YAML, TOML/INI, GraphQL,
Shell, PowerShell, Batch, SQL, Dockerfile, Makefile, CMake, Terraform, Diff and more.

| | |
|---|---|
| Detection | file extension, known file names (`Dockerfile`, `Makefile`, `.env`, …) and shebangs for extension-less scripts |
| Unknown/oversized | files above 600 KB show a “highlighting skipped” notice but still open as text |
| Binary files | never opened here — NUL-byte sniffing sends them to system Quick Look |

Both previews share the same controls: **⌘E** edit, **⌘S** save, **⌘R** reload,
**⌘+ / ⌘− / ⌘0** zoom, **Space/Esc** close.

Raw HTML in the document is escaped, `javascript:` links are dropped, and the asset
handler only serves image files. Every other file type still uses system Quick Look.

## Quick Look

Press **Space** (or **File → Quick Look**, ⌘Y) to preview the selection. Up/Down walk the
listing while the panel is open and the browser selection follows; Space or Esc closes it.
Only items with a local file URL can be previewed — remote (SSH) entries are skipped until
materialization lands.

## Go to Folder

**⇧⌘G** (or **Go → Go to Folder…**) opens a path sheet, Finder-style:

| Input | Resolves to |
|---|---|
| `/Users/me/project` | that folder |
| `~/project` | home-relative path |
| `project` | a name inside the folder you are browsing |
| `/…/file.txt` | opens the parent folder and selects the file |

**Tab** completes the last component with the first match; missing paths show an inline
error instead of navigating.

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
- **Split**: View → Toggle Split (⌘⌥S) / **Open in Split** on folders; sidebar drives the focused pane
- **Quick Look**: Space / ⌘Y; Up/Down walk the listing, Space or Esc closes
- **Go to Folder…**: ⇧⌘G — accepts `~`, absolute paths, and names relative to the current folder; Tab completes
- **Show Hidden Files**: View menu or Finder-style **⌘⇧.** — app-wide and persisted across launches
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
