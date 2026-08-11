import Foundation
import AppKit
import Darwin

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolder = "This Folder"
    case global = "Global"

    var id: String { rawValue }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let parentPath: String
    let isDirectory: Bool
    let isPackage: Bool

    var isBrowsable: Bool {
        isDirectory && !isPackage
    }

    func asFileEntry() -> FileEntry {
        LocalFileService.entry(at: id, location: parentPath)
            ?? FileEntry(
                id: id,
                name: name,
                isDirectory: isDirectory,
                isPackage: isPackage,
                isHidden: name.hasPrefix("."),
                size: 0,
                kind: isDirectory ? "Folder" : "Document",
                modified: nil,
                created: nil,
                location: parentPath
            )
    }
}

/// Interpreted filename query: plain substring or shell-style glob (`*`, `?`, `[…]`).
struct FilenameSearchPattern: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Case-insensitive substring of the filename (current default UX).
        case substring(String)
        /// Filename glob, e.g. `blabla*.json`, `*.md`, `report-??.txt`.
        case glob(String)
    }

    let kind: Kind

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.containsGlobMetacharacters(trimmed) {
            kind = .glob(trimmed)
        } else {
            kind = .substring(trimmed)
        }
    }

    var isEmpty: Bool {
        switch kind {
        case .substring(let s), .glob(let s):
            return s.isEmpty
        }
    }

    /// `true` when the query uses `*`, `?`, or a character class.
    var isGlob: Bool {
        if case .glob = kind { return true }
        return false
    }

    private static func containsGlobMetacharacters(_ value: String) -> Bool {
        var inClass = false
        for scalar in value.unicodeScalars {
            switch scalar {
            case "*", "?":
                if !inClass { return true }
            case "[":
                inClass = true
            case "]":
                if inClass { return true }
            default:
                break
            }
        }
        return false
    }
}

/// Filename search for the macOS UI. Prefers `fd`, then Spotlight (`mdfind`), then a walk fallback.
enum SearchService {
    nonisolated static let resultLimit = 500

    nonisolated static func search(
        query: String,
        scope: SearchScope,
        currentFolder: URL,
        showHiddenFiles: Bool = false
    ) async throws -> [SearchHit] {
        let pattern = FilenameSearchPattern(query)
        guard !pattern.isEmpty else { return [] }

        try Task.checkCancellation()

        let root: URL = {
            switch scope {
            case .currentFolder:
                return currentFolder.standardizedFileURL
            case .global:
                return FileManager.default.homeDirectoryForCurrentUser
            }
        }()

        if let hits = try await searchWithFd(
            pattern: pattern,
            root: root,
            showHiddenFiles: showHiddenFiles
        ) {
            return hits
        }

        if scope == .global, let hits = try await searchWithSpotlight(pattern: pattern) {
            return hits
        }

        return try await searchWithEnumerator(
            pattern: pattern,
            root: root,
            showHiddenFiles: showHiddenFiles
        )
    }

    // MARK: - fd

    /// `fd` is ideal here: globs use its `--glob` matcher (same engine style as ripgrep),
    /// substrings stay `--fixed-strings`. Both stay O(tree) with ignore rules and an early cap.
    nonisolated private static func searchWithFd(
        pattern: FilenameSearchPattern,
        root: URL,
        showHiddenFiles: Bool
    ) async throws -> [SearchHit]? {
        guard let fd = resolveFdPath() else { return nil }

        var arguments = [
            "--color=never",
            "--ignore-case",
            "--max-results", "\(resultLimit)",
            "--exclude", ".git",
            "--exclude", "node_modules",
            "--exclude", "DerivedData",
            "--exclude", "target",
            "--exclude", ".build",
        ]
        if showHiddenFiles {
            arguments.append("--hidden")
        }

        let query: String
        switch pattern.kind {
        case .substring(let text):
            // Literal substring anywhere in the path entry name / path as fd matches.
            arguments.append("--fixed-strings")
            query = text
        case .glob(let glob):
            // Shell-style: `blabla*.json`, `*.swift`, `img-??.png`
            arguments.append("--glob")
            query = glob
        }

        arguments.append(contentsOf: [query, root.path])

        let output = try await runProcess(executable: fd, arguments: arguments)
        try Task.checkCancellation()
        return parsePathLines(output, relativeTo: root)
    }

    nonisolated private static func resolveFdPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            "\(home)/.kimi-code/bin/fd",
            "\(home)/.cargo/bin/fd",
            "\(home)/.local/bin/fd",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Spotlight

    /// Spotlight’s `kMDItemFSName` already speaks glob (`*` / `?`). Metadata index = fast for Global.
    nonisolated private static func searchWithSpotlight(
        pattern: FilenameSearchPattern
    ) async throws -> [SearchHit]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let namePredicate: String
        switch pattern.kind {
        case .substring(let text):
            // Wrap with * so "note" matches "my-note.txt". Escape glob mets in the literal.
            namePredicate = "kMDItemFSName == '*\(escapeSpotlightLiteral(text))*'cd"
        case .glob(let glob):
            // Pass user wildcards through; only escape quotes / backslashes.
            namePredicate = "kMDItemFSName == '\(escapeSpotlightGlob(glob))'cd"
        }

        let output = try await runProcess(
            executable: "/usr/bin/mdfind",
            arguments: [
                "-onlyin", home,
                namePredicate,
            ]
        )

        try Task.checkCancellation()
        var hits = parsePathLines(output, relativeTo: URL(fileURLWithPath: home))
        if hits.count > resultLimit {
            hits = Array(hits.prefix(resultLimit))
        }
        return hits
    }

    /// Escape a literal fragment so embedded `*` / `?` are not wildcards.
    nonisolated private static func escapeSpotlightLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escape only quoting hazards; leave `*` / `?` / `[…]` as Spotlight globs.
    nonisolated private static func escapeSpotlightGlob(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Fallback walk

    nonisolated private static func searchWithEnumerator(
        pattern: FilenameSearchPattern,
        root: URL,
        showHiddenFiles: Bool
    ) async throws -> [SearchHit] {
        let rootPath = root.path

        return try await Task.detached(priority: .userInitiated) {
            var hits: [SearchHit] = []
            let fm = FileManager.default
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .nameKey],
                options: options
            ) else {
                return []
            }

            let skipNames: Set<String> = [
                ".git", "node_modules", "DerivedData", "target", ".build", "Pods",
            ]

            while let next = enumerator.nextObject() as? URL {
                try Task.checkCancellation()

                if skipNames.contains(next.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let name = next.lastPathComponent
                guard matchesFilename(name, pattern: pattern) else { continue }

                let values = try? next.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDirectory = values?.isDirectory ?? false
                let isPackage = values?.isPackage ?? false
                let parent = next.deletingLastPathComponent().path
                let relativeParent: String = {
                    if parent == rootPath { return "." }
                    if parent.hasPrefix(rootPath + "/") {
                        return String(parent.dropFirst(rootPath.count + 1))
                    }
                    return parent
                }()

                hits.append(
                    SearchHit(
                        id: next,
                        name: name,
                        parentPath: relativeParent,
                        isDirectory: isDirectory,
                        isPackage: isPackage
                    )
                )

                if hits.count >= resultLimit {
                    break
                }
            }

            return hits
        }.value
    }

    nonisolated private static func matchesFilename(_ name: String, pattern: FilenameSearchPattern) -> Bool {
        switch pattern.kind {
        case .substring(let text):
            return name.localizedCaseInsensitiveContains(text)
        case .glob(let glob):
            // POSIX fnmatch: same semantics as shell globs, case-insensitive.
            return glob.withCString { patternC in
                name.withCString { nameC in
                    fnmatch(patternC, nameC, FNM_CASEFOLD) == 0
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func parsePathLines(_ output: String, relativeTo root: URL) -> [SearchHit] {
        let rootPath = root.path
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(resultLimit, 64))

        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            var isDirectory = false
            var isPackage = false
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                isDirectory = values.isDirectory ?? false
                isPackage = values.isPackage ?? false
            } else {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                isDirectory = isDir.boolValue
            }

            let parent = url.deletingLastPathComponent().path
            let relativeParent: String = {
                if parent == rootPath { return "." }
                if parent.hasPrefix(rootPath + "/") {
                    return String(parent.dropFirst(rootPath.count + 1))
                }
                return parent
            }()

            hits.append(
                SearchHit(
                    id: url,
                    name: url.lastPathComponent,
                    parentPath: relativeParent,
                    isDirectory: isDirectory,
                    isPackage: isPackage
                )
            )
        }

        return hits
    }

    nonisolated private static func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()
                    process.waitUntilExit()

                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""

                    // fd returns 1 when no matches — treat as empty success.
                    if process.terminationStatus == 0
                        || (executable.hasSuffix("/fd") && process.terminationStatus == 1)
                    {
                        continuation.resume(returning: text)
                    } else {
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(
                            throwing: NSError(
                                domain: "ArborSearch",
                                code: Int(process.terminationStatus),
                                userInfo: [
                                    NSLocalizedDescriptionKey: err.isEmpty ? "Search failed" : err,
                                ]
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
