import Foundation

/// Pure naming helpers for Finder-style `.zip` compression & extraction.
/// Never overwrites an existing file or folder — appends ` 2`, ` 3`, etc.
nonisolated enum ArchiveNameResolver {
    static func uniqueArchiveURL(
        for urls: [URL],
        in directory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let baseName: String
        if urls.count == 1, let only = urls.first {
            let stem = only.deletingPathExtension().lastPathComponent
            baseName = stem.isEmpty ? only.lastPathComponent : stem
        } else {
            baseName = "Archive"
        }

        let initial = directory.appendingPathComponent("\(baseName).zip")
        if !fileExists(initial.path) {
            return initial
        }
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(suffix).zip")
            if !fileExists(candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    static func uniqueExtractionURL(
        for archiveURL: URL,
        in directory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let stem = archiveURL.deletingPathExtension().lastPathComponent
        let baseName = stem.isEmpty ? "Extracted" : stem

        let initial = directory.appendingPathComponent(baseName)
        if !fileExists(initial.path) {
            return initial
        }
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(suffix)")
            if !fileExists(candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    static func isSupportedArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }
}

/// Pure status-bar summary formatter (item count, selection count + bytes, free volume space).
nonisolated enum StatusBarSummary {
    static func format(
        itemCount: Int,
        selectedCount: Int,
        selectedBytes: UInt64,
        availableBytes: Int64?
    ) -> String {
        var parts: [String] = []
        parts.append(itemCount == 1 ? "1 item" : "\(formatInteger(itemCount)) items")

        if selectedCount > 0 {
            if selectedBytes > 0 {
                let bytes = ByteCountFormatter.string(
                    fromByteCount: Int64(min(selectedBytes, UInt64(Int64.max))),
                    countStyle: .file
                )
                parts.append("\(formatInteger(selectedCount)) selected (\(bytes))")
            } else {
                parts.append("\(formatInteger(selectedCount)) selected")
            }
        }

        if let availableBytes, availableBytes >= 0 {
            let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            parts.append("\(free) available")
        }

        return parts.joined(separator: " · ")
    }

    private static func formatInteger(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

/// Pure clipboard decision logic for Copy (`⌘C`), Cut (`⌘X`), Paste (`⌘V`), and Move Here (`⌘⌥V`),
/// seamlessly reconciling Arbor's internal clipboard with external apps (Finder, Slack, Mail).
nonisolated enum FileClipboardIntent: Equatable, Sendable {
    case copy
    case cut
}

nonisolated struct FileClipboardResolution: Equatable, Sendable {
    let paths: [String]
    let isMove: Bool
    let clearsInternalAfterPaste: Bool
}

nonisolated struct FileClipboardState: Sendable {
    private(set) var internalPaths: [String] = []
    private(set) var intent: FileClipboardIntent = .copy
    private(set) var recordedPasteboardChangeCount: Int = -1

    mutating func record(paths: [String], intent: FileClipboardIntent, pasteboardChangeCount: Int) {
        self.internalPaths = paths
        self.intent = intent
        self.recordedPasteboardChangeCount = pasteboardChangeCount
    }

    mutating func clear() {
        internalPaths = []
        intent = .copy
        recordedPasteboardChangeCount = -1
    }

    /// Resolves what a Paste (`forceMove: false`) or Move-Here (`forceMove: true`) should transfer,
    /// preferring newer external pasteboard URLs (e.g. copied in Finder) over stale internal state.
    func resolve(
        externalPasteboardPaths: [String],
        currentPasteboardChangeCount: Int,
        forceMove: Bool
    ) -> FileClipboardResolution? {
        let externalIsNewer = !externalPasteboardPaths.isEmpty
            && currentPasteboardChangeCount != recordedPasteboardChangeCount

        if externalIsNewer {
            return FileClipboardResolution(
                paths: externalPasteboardPaths,
                isMove: forceMove,
                clearsInternalAfterPaste: false
            )
        }

        if !internalPaths.isEmpty {
            let isMove = forceMove || (intent == .cut)
            return FileClipboardResolution(
                paths: internalPaths,
                isMove: isMove,
                clearsInternalAfterPaste: isMove
            )
        }

        if !externalPasteboardPaths.isEmpty {
            return FileClipboardResolution(
                paths: externalPasteboardPaths,
                isMove: forceMove,
                clearsInternalAfterPaste: false
            )
        }

        return nil
    }
}
