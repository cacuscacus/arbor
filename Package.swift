// swift-tools-version:5.9
import PackageDescription

// Pure-logic test package for Arbor's macOS app.
//
// The app itself is built by the Xcode project in apps/macos; this package
// exists so the Foundation-only logic (Markdown renderer, source-language
// detection, Go to Folder resolution, search-pattern interpretation) has
// CI-enforceable unit tests without an Xcode test target. `swift test` runs
// anywhere Swift runs.
let package = Package(
    name: "arbor-pure",
    targets: [
        .target(
            name: "ArborPure",
            path: "apps/macos/Arbor/Services",
            sources: [
                "MarkdownHTMLRenderer.swift",
                "SourceLanguage.swift",
                "GoToFolderResolver.swift",
                "FilenameSearchPattern.swift",
            ]
        ),
        .testTarget(
            name: "ArborPureTests",
            dependencies: ["ArborPure"]
        ),
    ]
)
