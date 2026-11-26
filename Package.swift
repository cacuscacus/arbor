// swift-tools-version:5.9
import PackageDescription

// Pure-logic test package for Arbor's macOS app.
//
// The app itself is built by the Xcode project in apps/macos; this package
// exists so the logic that does not need a running app (Markdown renderer,
// source-language detection, Go to Folder resolution, search-pattern
// interpretation, drag payloads) has CI-enforceable unit tests without an
// Xcode test target. `swift test` runs on macOS, where AppKit is available.
let package = Package(
    name: "arbor-pure",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ArborPure",
            path: "apps/macos/Arbor/Services",
            sources: [
                "MarkdownHTMLRenderer.swift",
                "SourceLanguage.swift",
                "GoToFolderResolver.swift",
                "FilenameSearchPattern.swift",
                "FileDragPayload.swift",
                "PasteDestinationResolver.swift",
                "SidebarDropRouting.swift",
                "DragAutoScrollController.swift",
                "SearchEngine.swift",
                "ContentSearchEngine.swift",
                "SearchQueryExpander.swift",
                "SearchPreferencesStore.swift",
                "FinderParityHelpers.swift",
            ]
        ),
        .testTarget(
            name: "ArborPureTests",
            dependencies: ["ArborPure"]
        ),
    ]
)
