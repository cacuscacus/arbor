# Architecture

## High-level

```
┌─────────────────────────────────────────────────────────────┐
│  UI                                                         │
│  SwiftUI (macOS)  ·  Tauri (Linux / Windows, future)        │
└─────────────────────────────┬───────────────────────────────┘
                              │ FFI / IPC
┌─────────────────────────────▼───────────────────────────────┐
│  arbor-core                                                 │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐  │
│  │    FS    │ │  Search  │ │ Watcher  │ │   Metadata     │  │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐  │
│  │ Preview  │ │Scheduler │ │ Plugins  │ │  AI · Terminal │  │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Crates

| Crate | Responsibility |
|-------|----------------|
| `arbor-core` | Domain logic: FS, search, watcher, metadata, preview, scheduler, plugin host, AI, terminal |
| `arbor-ffi` | Stable C ABI for Swift (and later other native UIs) |
| `arbor-cli` | Headless driver for scripting, debugging, and CI |

UI never talks to the filesystem directly for core operations. All paths go through `arbor-core` so behavior stays consistent across platforms and plugins.

## Performance targets

| Metric | Target |
|--------|--------|
| Cold startup | &lt; 100 ms |
| Search (filename) | Instant / as-you-type |
| Steady memory | &lt; 150 MB |
| Listing | Lazy load + virtual scrolling |
| Index | Background, incremental, optional |

## Search stack

1. **Live walk** — `walkdir` / `fd`-style ignore rules for immediate results
2. **Content** — `ripgrep` for `contains:` queries
3. **Fuzzy** — `fzf`-style ranking for interactive pickers
4. **Optional SQLite** — accelerate repeated queries and metadata filters
5. **Spotlight** — opportunistic on macOS when it helps, never required

## Plugin surface (planned)

Each plugin may receive:

- Filesystem events
- Current selection
- Terminal handle
- Search API
- Metadata

Scripting hosts (planned): Lua, Python, JavaScript — on top of a Rust plugin ABI.

## AI layer (planned)

Natural language → validated shell / Arbor actions.

Providers: Claude Code, Codex CLI, Cursor CLI, OpenCode, Kimi Code, Gemini CLI, Ollama, OpenAI, Anthropic, OpenRouter, custom local models.

AI suggests; the user (or automation policy) confirms destructive ops.
