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

/// Finder-style type-to-select (type-ahead) matcher for List and Icon views.
///
/// Accumulates typed characters within `timeout` seconds and matches prefixes
/// case- and diacritic-insensitively. Typing the same single character repeatedly
/// when no entry matches the doubled prefix cycles through entries starting with
/// that character (matching macOS Finder).
nonisolated struct TypeAheadMatcher: Sendable {
    var timeout: TimeInterval = 0.85
    private(set) var buffer: String = ""
    private var lastTypedAt: Date = .distantPast

    init(timeout: TimeInterval = 0.85) {
        self.timeout = timeout
    }

    mutating func reset() {
        buffer = ""
        lastTypedAt = .distantPast
    }

    /// Appends `characters` typed at `now` and returns the matched candidate index, if any.
    mutating func match(
        typing characters: String,
        at now: Date,
        candidates: [String],
        currentIndex: Int?
    ) -> Int? {
        guard !characters.isEmpty, !candidates.isEmpty else { return nil }

        let normalizedCandidates = candidates.map(Self.normalize)
        let expired = now.timeIntervalSince(lastTypedAt) > timeout
        let normalizedInput = Self.normalize(characters)
        guard !normalizedInput.isEmpty else { return nil }

        if expired {
            buffer = ""
        }
        lastTypedAt = now

        let candidateBuffer = buffer + normalizedInput
        if let exactIndex = firstMatch(prefix: candidateBuffer, in: normalizedCandidates, startingAt: 0) {
            buffer = candidateBuffer
            return exactIndex
        }

        // Finder behavior: pressing the same single key repeatedly cycles through
        // items starting with that letter when no item starts with the doubled prefix.
        if buffer.count == 1, normalizedInput == buffer {
            let start = ((currentIndex ?? -1) + 1) % normalizedCandidates.count
            if let cycled = firstMatch(prefix: normalizedInput, in: normalizedCandidates, startingAt: start) {
                return cycled
            }
        }

        // If the extended buffer didn't match, keep buffer updated so further
        // back-to-back typos don't accidentally match unrelated items, unless
        // this was the first character after timeout.
        buffer = candidateBuffer
        return nil
    }

    private func firstMatch(
        prefix: String,
        in normalizedCandidates: [String],
        startingAt start: Int
    ) -> Int? {
        let count = normalizedCandidates.count
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let index = (start + offset) % count
            if normalizedCandidates[index].hasPrefix(prefix) {
                return index
            }
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Filters raw keyDown text to printable characters suitable for type-to-select.
    static func printableInput(from characters: String?) -> String? {
        guard let characters, !characters.isEmpty else { return nil }
        // Reject single-character space (Quick Look) and "/" (search shortcut) as the
        // first character, control keys, and arrow/function Unicode scalars (U+F700..U+F8FF).
        for scalar in characters.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        if characters == " " || characters == "/" { return nil }
        return characters
    }
}

/// Collision-safe naming for inline New Folder / New File creation across both
/// local and remote (SSH) providers.
nonisolated enum UniqueItemNameResolver {
    static func uniqueName(
        preferred: String,
        existingNames: Set<String>,
        isDirectory: Bool
    ) -> String {
        let existingLower = Set(existingNames.map { $0.lowercased() })
        if !existingLower.contains(preferred.lowercased()) {
            return preferred
        }

        let ns = preferred as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let stem = ext.isEmpty ? preferred : ns.deletingPathExtension

        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !existingLower.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }
}

/// Snapshot emitted during async recursive folder size calculation (`Get Info`).
nonisolated struct FolderSizeSnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let itemCount: Int
    let isComplete: Bool

    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(totalBytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    var formattedSummary: String {
        let itemsLabel = itemCount == 1
            ? "1 item"
            : "\(NumberFormatter.localizedString(from: NSNumber(value: itemCount), number: .decimal)) items"
        if isComplete {
            return "\(formattedBytes) (\(itemsLabel))"
        }
        if itemCount == 0 && totalBytes == 0 {
            return "Calculating…"
        }
        return "Calculating… \(formattedBytes) (\(itemsLabel))"
    }
}

/// Async recursive folder size calculator with hardlink deduplication,
/// symlink loop safety, and cooperative Swift Task cancellation.
nonisolated enum FolderSizeCalculator {
    static func calculate(
        url: URL,
        progressInterval: TimeInterval = 0.12,
        onProgress: (@Sendable (FolderSizeSnapshot) -> Void)? = nil
    ) async -> FolderSizeSnapshot {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
                .fileResourceIdentifierKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                return FolderSizeSnapshot(totalBytes: 0, itemCount: 0, isComplete: true)
            }

            var totalBytes: UInt64 = 0
            var itemCount = 0
            var seenInodes = Set<NSObject>()
            var lastEmit = Date.distantPast
            var visited = 0

            while let next = enumerator.nextObject() as? URL {
                visited += 1
                if visited & 63 == 0 {
                    if Task.isCancelled {
                        return FolderSizeSnapshot(
                            totalBytes: totalBytes,
                            itemCount: itemCount,
                            isComplete: false
                        )
                    }
                    let now = Date()
                    if let onProgress, now.timeIntervalSince(lastEmit) >= progressInterval {
                        lastEmit = now
                        onProgress(FolderSizeSnapshot(
                            totalBytes: totalBytes,
                            itemCount: itemCount,
                            isComplete: false
                        ))
                    }
                }

                guard let values = try? next.resourceValues(forKeys: keys) else { continue }
                itemCount += 1

                if values.isSymbolicLink == true {
                    continue
                }
                guard values.isRegularFile == true else { continue }

                // Deduplicate hardlinks using the file's volume+inode identifier.
                if let resourceID = values.fileResourceIdentifier as? NSObject {
                    if !seenInodes.insert(resourceID).inserted {
                        continue
                    }
                }

                let bytes = values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
                if bytes > 0 {
                    totalBytes += UInt64(bytes)
                }
            }

            let finalSnapshot = FolderSizeSnapshot(
                totalBytes: totalBytes,
                itemCount: itemCount,
                isComplete: !Task.isCancelled
            )
            onProgress?(finalSnapshot)
            return finalSnapshot
        }.value
    }
}

/// Pure formatting & anti-flicker display rules for active file transfer jobs.
nonisolated enum TransferProgressFormatter {
    static let delayedRevealThreshold: TimeInterval = 0.35
    static let immediateRevealItemThreshold = 6
    static let immediateRevealByteThreshold: Int64 = 20 * 1024 * 1024

    static func shouldRevealImmediately(totalItems: Int, totalBytes: Int64?) -> Bool {
        if totalItems >= immediateRevealItemThreshold { return true }
        if let totalBytes, totalBytes >= immediateRevealByteThreshold { return true }
        return false
    }

    static func fractionCompleted(
        completedItems: Int,
        totalItems: Int,
        completedBytes: Int64?,
        totalBytes: Int64?
    ) -> Double? {
        if let totalBytes, totalBytes > 0, let completedBytes {
            return min(1.0, max(0.0, Double(completedBytes) / Double(totalBytes)))
        }
        guard totalItems > 1 else { return nil }
        return min(1.0, max(0.0, Double(completedItems) / Double(totalItems)))
    }

    static func subtitle(
        completedItems: Int,
        totalItems: Int,
        currentItemName: String?,
        completedBytes: Int64?,
        totalBytes: Int64?,
        isCancelling: Bool
    ) -> String {
        if isCancelling {
            return "Cancelling…"
        }
        var parts: [String] = []
        if totalItems > 1 {
            let activeIndex = min(totalItems, completedItems + 1)
            parts.append("\(activeIndex) of \(totalItems)")
        }
        if let totalBytes, totalBytes > 0, let completedBytes {
            let doneStr = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            parts.append("\(doneStr) of \(totalStr)")
        }
        if let currentItemName, !currentItemName.isEmpty {
            parts.append(currentItemName)
        }
        return parts.isEmpty ? "Working…" : parts.joined(separator: " · ")
    }
}
