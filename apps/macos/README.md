# macOS App (SwiftUI)

Native shell for Arbor on macOS.

## Status

Source scaffold only. Create an Xcode macOS App project and add the files under `Arbor/`, or generate the project with XcodeGen when ready.

Current listing uses `LocalFileService` (Swift `FileManager`). It will be replaced by `arbor-ffi` once the Rust static library is linked.

## Intended structure

```
Arbor/
├── ArborApp.swift
├── Views/
│   ├── ContentView.swift
│   ├── SidebarView.swift
│   └── FileBrowserView.swift
├── Services/
│   └── LocalFileService.swift   # temporary stand-in for FFI
├── Models/                      # shared view models
└── Resources/                   # assets, entitlements
```

## Create the Xcode project (manual)

1. Xcode → File → New → Project → macOS → App
2. Product Name: `Arbor`, Interface: SwiftUI, Language: Swift
3. Save into `apps/macos/` (replace the generated stub with these sources)
4. Set deployment target to macOS 14+
5. Later: link `libarbor_ffi.a` / `cdylib` from `cargo build -p arbor-ffi`

## Build Rust FFI for linking

```bash
cargo build -p arbor-ffi --release
# artifact: target/release/libarbor_ffi.a (and/or .dylib)
```
