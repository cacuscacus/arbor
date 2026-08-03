# macOS App (SwiftUI)

Native shell for Arbor on macOS.

## Open in Xcode

```bash
open /Users/cacus/Workspace/arbor/apps/macos/Arbor.xcodeproj
```

Then press **▶ Run** (⌘R). Destination: **My Mac**.

## Layout

```
apps/macos/
├── Arbor.xcodeproj
├── Arbor/
│   ├── ArborApp.swift
│   ├── Views/
│   ├── Services/          # LocalFileService (temporary; replace with arbor-ffi)
│   ├── Models/
│   ├── Resources/
│   └── Assets.xcassets
└── README.md
```

App Sandbox is **off** for local development so the file manager can read the filesystem.

## Build from terminal

```bash
xcodebuild -project apps/macos/Arbor.xcodeproj -scheme Arbor -configuration Debug build
```
