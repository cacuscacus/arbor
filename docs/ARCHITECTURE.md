# Architecture

## What runs today (v1.6.x)

```
┌────────────────────────────────────────────────────────────────┐
│ macOS app (Arbor.app) — Swift                                  │
│  SwiftUI shell + AppKit for heavy views                        │
│  (NSTableView, NSCollectionView, SwiftTerm)                    │
│                                                                │
│  Product logic, all in Swift:                                  │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌─────────────┐  │
│  │ FileProvider│ │ Search     │ │ Preview    │ │ Session /   │  │
│  │ (ItemRef)  │ │ (Spotlight │ │ renderers  │ │ windowing   │  │
│  │ Local + SSH│ │  → fd →    │ │ (Markdown, │ │ (tabs,      │  │
│  │            │ │  walk)     │ │  code, QL) │ │  split, DnD)│  │
│  └────────────┘ └────────────┘ └────────────┘ └─────────────┘  │
└──────────────┬─────────────────────────────────────────────────┘
               │ spawn (stdin/stdout NDJSON)
┌──────────────▼─────────────────────────────────────────────────┐
│ arbor-sftp-helper — Rust sidecar                               │
│ SFTP operations over OpenSSH; one process per connection       │
└────────────────────────────────────────────────────────────────┘

arbor-cli (Rust): headless smoke tool for CI. Not shipped in the app.
arbor-core / arbor-ffi (Rust): listing + API stubs; NOT linked into
the app. Kept as a future option, not the plan of record.
```

## Where each piece lives

| Component | Language | Ships in app | Role |
|-----------|----------|--------------|------|
| Browser, windowing, search, previews, terminal, agents | Swift | yes | The product core on macOS |
| `FileProvider` / `ItemRef` abstraction | Swift | yes | Portability boundary (local + SSH today) |
| `arbor-sftp-helper` | Rust | yes (in `Contents/Helpers`) | Native-capability sidecar; NDJSON over stdio |
| `arbor-cli` | Rust | no | CI smoke tests (`version`, `list`) |
| `arbor-core` | Rust | no | `list_dir` + module stubs (search, watcher, …) |
| `arbor-ffi` | Rust | no | C ABI exists; no build bridge to Xcode |

## Decision: Swift is the macOS core (2026-11)

The original plan was "thin Swift UI over a Rust core via FFI." In
practice v1.x grew the other way: the Swift `FileProvider` model,
search pipeline, and preview renderers are richer than anything in
`arbor-core`, and the app has never linked the Rust staticlib.

**Plan of record:**

- **Swift owns the product** on macOS. The portability boundary is the
  provider-neutral `FileProvider` / `ItemRef` model plus the pure-logic
  types (Markdown renderer, source-language detection, path resolution,
  search patterns), which are Foundation-only and unit-tested via the
  SPM package in `Package.swift`.
- **Rust earns its place as sidecars**: native capabilities that are
  awkward or unsafe in-process, reached over stdio IPC — the pattern
  proven by `arbor-sftp-helper`. Candidates: content search/indexing,
  archive inspection, checksums.
- **A shared Rust core for Linux/Windows ports** stays possible, but it
  will be decided when those ports start, growing from real shared
  needs (search, metadata) rather than by rewriting working Swift.

## Performance targets

| Metric | Target | Status |
|--------|--------|--------|
| Cold startup | < 100 ms | Release launches in ~1 s; keep pushing |
| Search (filename) | Instant / as-you-type | Folder: yes (`fd`); Global: Spotlight ~0.3 s |
| Steady memory | < 150 MB | ~116 MB release, ~128 MB with 3k-file folder |
| Large listings | Virtualized | Icon view: AppKit virtualization; list view: pending |

## Search (as implemented)

1. **This Folder** — `fd` (preferred): NUL-delimited, literal + glob,
   no `.gitignore` surprises, 500-result cap; directory-walk fallback.
2. **Global** — Spotlight (`mdfind`) first (~0.3 s), `fd` fallback.
3. Query language (`kind:`, `size>`, `modified:`) and content search
   (`ripgrep`) are roadmap items, not implemented.

## Plugin & AI surface (planned)

Not implemented. If added, plugins would receive filesystem events,
selection, terminal handle, search API, and metadata; scripting hosts
(Lua / Python / JS) would sit on a Rust ABI — most likely as sidecars,
consistent with the decision above.

The AI layer today is agent CLIs in a visible terminal (Settings →
Tools): OpenCode, Kimi, Cursor Agent, custom — never silent background
jobs. Arbor-native natural-language actions remain a Phase 5 item.
