import Foundation
import Darwin

/// One matching line inside a file produced by content search (`rg` or fallback scan).
nonisolated struct ContentMatchSnippet: Identifiable, Hashable, Sendable {
    let lineNumber: Int
    /// Trimmed line text (centered around the match when very long) ready for UI display.
    let lineText: String
    /// Character offset of the matched substring within `lineText`.
    let matchStart: Int
    /// Character length of the matched substring within `lineText`.
    let matchLength: Int

    var id: String { "\(lineNumber):\(matchStart):\(matchLength)" }

    /// Builds a display-safe snippet capped to `maxCharacters` around the matched UTF-8 byte range.
    static func make(
        lineNumber: Int,
        rawLine: String,
        utf8Start: Int,
        utf8End: Int,
        maxCharacters: Int = 200
    ) -> ContentMatchSnippet {
        // Strip trailing CR/LF only so column offsets stay aligned with leading text before trimming.
        var cleaned = rawLine
        while cleaned.last == "\n" || cleaned.last == "\r" {
            cleaned.removeLast()
        }

        let utf8 = cleaned.utf8
        let clampedStart = max(0, min(utf8Start, utf8.count))
        let clampedEnd = max(clampedStart, min(utf8End, utf8.count))

        let startIdx = utf8.index(utf8.startIndex, offsetBy: clampedStart)
        let endIdx = utf8.index(utf8.startIndex, offsetBy: clampedEnd)

        let charStart = cleaned.distance(from: cleaned.startIndex, to: startIdx)
        let charEnd = cleaned.distance(from: cleaned.startIndex, to: endIdx)
        let matchLen = max(0, charEnd - charStart)

        return makeFromCharacterRange(
            lineNumber: lineNumber,
            cleanedLine: cleaned,
            charStart: charStart,
            matchLength: matchLen,
            maxCharacters: maxCharacters
        )
    }

    static func makeFromCharacterRange(
        lineNumber: Int,
        cleanedLine: String,
        charStart: Int,
        matchLength: Int,
        maxCharacters: Int = 200
    ) -> ContentMatchSnippet {
        // Trim leading indentation spaces/tabs while adjusting `charStart`.
        var leadingTrimmed = 0
        var idx = cleanedLine.startIndex
        while idx < cleanedLine.endIndex, cleanedLine[idx] == " " || cleanedLine[idx] == "\t" {
            if leadingTrimmed >= charStart { break }
            leadingTrimmed += 1
            idx = cleanedLine.index(after: idx)
        }
        let body = String(cleanedLine[idx...])
        let adjustedStart = max(0, charStart - leadingTrimmed)
        let totalChars = body.count

        guard totalChars > maxCharacters else {
            return ContentMatchSnippet(
                lineNumber: lineNumber,
                lineText: body,
                matchStart: min(adjustedStart, totalChars),
                matchLength: min(matchLength, max(0, totalChars - adjustedStart))
            )
        }

        // Window around the match so long minified lines remain readable and fast to lay out.
        let leadContext = max(24, (maxCharacters - matchLength) / 3)
        let windowStart = max(0, min(adjustedStart - leadContext, totalChars - maxCharacters))
        let windowEnd = min(totalChars, windowStart + maxCharacters)

        let wStartIdx = body.index(body.startIndex, offsetBy: windowStart)
        let wEndIdx = body.index(body.startIndex, offsetBy: windowEnd)
        let prefix = windowStart > 0 ? "…" : ""
        let suffix = windowEnd < totalChars ? "…" : ""
        let slice = prefix + String(body[wStartIdx..<wEndIdx]) + suffix

        let newMatchStart = (adjustedStart - windowStart) + prefix.count
        let clampedMatchLen = min(matchLength, max(0, slice.count - newMatchStart))

        return ContentMatchSnippet(
            lineNumber: lineNumber,
            lineText: slice,
            matchStart: max(0, newMatchStart),
            matchLength: clampedMatchLen
        )
    }
}

/// One parsed `rg --json` match event.
nonisolated struct RipgrepMatchEvent: Equatable, Sendable {
    let path: String
    let snippet: ContentMatchSnippet
}

/// Parses individual JSON lines emitted by `rg --json`.
nonisolated enum RipgrepJSONParser {
    private struct Envelope: Decodable {
        let type: String
        let data: MatchData?
    }

    private struct TextOrBytes: Decodable {
        let text: String?
        let bytes: String?

        var decoded: String? {
            if let text { return text }
            if let bytes, let raw = Data(base64Encoded: bytes) {
                return String(decoding: raw, as: UTF8.self)
            }
            return nil
        }
    }

    private struct Submatch: Decodable {
        let start: Int
        let end: Int
    }

    private struct MatchData: Decodable {
        let path: TextOrBytes?
        let lines: TextOrBytes?
        let line_number: Int?
        let submatches: [Submatch]?
    }

    /// Parses a single JSON line from `rg --json`. Returns `nil` for non-match events
    /// (`begin`, `end`, `summary`, `context`) or malformed lines.
    static func parseLine(_ jsonLine: String) -> RipgrepMatchEvent? {
        guard jsonLine.contains("\"match\""),
              let data = jsonLine.data(using: .utf8),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              env.type == "match",
              let match = env.data,
              let path = match.path?.decoded,
              !path.isEmpty,
              let lineText = match.lines?.decoded,
              let lineNumber = match.line_number
        else {
            return nil
        }

        let firstSub = match.submatches?.first
        let snippet = ContentMatchSnippet.make(
            lineNumber: lineNumber,
            rawLine: lineText,
            utf8Start: firstSub?.start ?? 0,
            utf8End: firstSub?.end ?? 0
        )
        return RipgrepMatchEvent(path: path, snippet: snippet)
    }
}

/// Pure text file inspection and fallback content scanner (used when `rg` is unavailable,
/// and for extracting quick preview snippets from small text files returned by Spotlight).
nonisolated enum ContentFileScanner {
    /// Checks first 8 KB for NUL bytes to avoid reading binary files as text.
    static func isLikelyBinary(_ data: Data) -> Bool {
        let probeCount = min(data.count, 8_192)
        guard probeCount > 0 else { return false }
        return data.prefix(probeCount).contains(0)
    }

    /// Scans a single file (bounded by `maxFileSizeBytes`) for case-insensitive substring hits.
    static func scanFile(
        at path: String,
        query: String,
        maxFileSizeBytes: UInt64?,
        maxMatches: Int
    ) -> [ContentMatchSnippet] {
        guard !query.isEmpty, maxMatches > 0 else { return [] }
        let url = URL(fileURLWithPath: path)
        if let maxSize = maxFileSizeBytes {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) {
                if values.isRegularFile == false { return [] }
                if let size = values.fileSize, UInt64(max(0, size)) > maxSize {
                    return []
                }
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        // Read header first so huge or binary files bail immediately.
        guard let head = try? handle.read(upToCount: 8_192), !head.isEmpty else { return [] }
        if isLikelyBinary(head) { return [] }

        var data = head
        if let rest = try? handle.readToEnd(), !rest.isEmpty {
            data.append(rest)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        var snippets: [ContentMatchSnippet] = []
        snippets.reserveCapacity(min(maxMatches, 5))
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            if let range = line.range(of: query, options: .caseInsensitive) {
                let charStart = line.distance(from: line.startIndex, to: range.lowerBound)
                let charLen = line.distance(from: range.lowerBound, to: range.upperBound)
                snippets.append(
                    ContentMatchSnippet.makeFromCharacterRange(
                        lineNumber: lineNumber,
                        cleanedLine: line,
                        charStart: charStart,
                        matchLength: charLen
                    )
                )
                if snippets.count >= maxMatches {
                    stop = true
                }
            }
        }
        return snippets
    }

    /// Cycle-safe, size-bounded BFS fallback content search when `rg` is not installed.
    static func walkAndScan(
        root: URL,
        query: String,
        options: SearchOptions,
        isGlobalRoot: Bool,
        onFileMatch: @escaping @Sendable (String, [ContentMatchSnippet]) -> Bool
    ) async throws -> CycleSafeDirectoryWalker.WalkResult {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let excludedNameSet = Set(options.excludedNames)
        let deadline = ContinuousClock.now + .seconds(options.timeoutSeconds)
        let maxSize = options.maxContentFileSizeBytes
        let maxPerFile = options.maxMatchesPerFile

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var visitedDirs = Set<FileIdentity>()
            if let rootID = FileIdentity.ofResolvedTarget(path: rootPath) {
                visitedDirs.insert(rootID)
            }

            var queue: [(URL, Int)] = [(rootURL, 0)]
            var queueHead = 0
            var visitedNodes = 0
            var matchedFiles = 0
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .fileSizeKey,
            ]

            while queueHead < queue.count {
                let (dirURL, depth) = queue[queueHead]
                queueHead += 1
                if queueHead > 2048 {
                    queue.removeFirst(queueHead)
                    queueHead = 0
                }

                try Task.checkCancellation()
                if ContinuousClock.now >= deadline {
                    return CycleSafeDirectoryWalker.WalkResult(
                        stopReason: .timedOut(seconds: options.timeoutSeconds),
                        visitedNodes: visitedNodes,
                        matchedCount: matchedFiles
                    )
                }

                let enumOptions: FileManager.DirectoryEnumerationOptions =
                    options.showHiddenFiles ? [] : [.skipsHiddenFiles]
                guard let children = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: keys,
                    options: enumOptions
                ) else {
                    continue
                }

                for child in children {
                    visitedNodes += 1
                    if visitedNodes & 31 == 0 {
                        try Task.checkCancellation()
                        if ContinuousClock.now >= deadline {
                            return CycleSafeDirectoryWalker.WalkResult(
                                stopReason: .timedOut(seconds: options.timeoutSeconds),
                                visitedNodes: visitedNodes,
                                matchedCount: matchedFiles
                            )
                        }
                    }

                    if visitedNodes > options.maxVisitedNodes {
                        return CycleSafeDirectoryWalker.WalkResult(
                            stopReason: .nodeLimitReached(visited: visitedNodes - 1),
                            visitedNodes: visitedNodes - 1,
                            matchedCount: matchedFiles
                        )
                    }

                    let childPath = child.path
                    if SearchPathFilter.isExcluded(
                        path: childPath,
                        rootPath: rootPath,
                        isGlobalRoot: isGlobalRoot,
                        excludedNames: excludedNameSet,
                        excludedGlobalRelativePaths: options.excludedGlobalRelativePaths,
                        showHiddenFiles: options.showHiddenFiles
                    ) {
                        continue
                    }

                    let values = try? child.resourceValues(forKeys: Set(keys))
                    let isDirectory = values?.isDirectory ?? false
                    let isPackage = values?.isPackage ?? false
                    let isSymlink = values?.isSymbolicLink ?? false

                    if isDirectory {
                        guard !isPackage, !isSymlink else { continue }
                        if SearchPathFilter.packageExtensions.contains(child.pathExtension.lowercased()) {
                            continue
                        }
                        if let maxDepth = options.maxDepth, depth >= maxDepth {
                            continue
                        }
                        if let identity = FileIdentity.of(path: childPath) {
                            guard visitedDirs.insert(identity).inserted else { continue }
                        }
                        queue.append((child, depth + 1))
                        continue
                    }

                    guard values?.isRegularFile == true, !isSymlink else { continue }
                    if let maxSize, let size = values?.fileSize, UInt64(max(0, size)) > maxSize {
                        continue
                    }

                    let snippets = scanFile(
                        at: childPath,
                        query: query,
                        maxFileSizeBytes: maxSize,
                        maxMatches: maxPerFile
                    )
                    if !snippets.isEmpty {
                        matchedFiles += 1
                        if !onFileMatch(childPath, snippets) || matchedFiles >= options.resultLimit {
                            return CycleSafeDirectoryWalker.WalkResult(
                                stopReason: .limitReached(limit: options.resultLimit),
                                visitedNodes: visitedNodes,
                                matchedCount: matchedFiles
                            )
                        }
                    }
                }
            }

            return CycleSafeDirectoryWalker.WalkResult(
                stopReason: .completed,
                visitedNodes: visitedNodes,
                matchedCount: matchedFiles
            )
        }.value
    }
}
