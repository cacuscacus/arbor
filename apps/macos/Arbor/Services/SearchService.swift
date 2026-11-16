import Foundation
import AppKit
import Darwin

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolder = "This Folder"
    case global = "Global"

    var id: String { rawValue }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: ItemRef
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

/// Thread-safe cancellation bridge between a Task and its child `Process`.
/// `Process` is not Sendable; the lock also closes the "cancel before start" race.
nonisolated private final class SearchProcessHandle: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = started && process.isRunning
        lock.unlock()
        if running {
            process.terminate()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Collector for a pipe read happening on another queue.
nonisolated private final class SearchOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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

        // Global: treat the Spotlight index like Finder does. `mdfind` answers
        // in ~0.3 s where a cold `fd` walk of $HOME takes 5-15 s; `fd` remains
        // the fallback when Spotlight is unavailable/disabled.
        if scope == .global {
            do {
                let hits = try await searchWithSpotlight(pattern: pattern)
                if !hits.isEmpty || !pattern.isGlob {
                    return hits
                }
                let literal = try await searchWithSpotlight(pattern: pattern.literalFallback)
                return literal.isEmpty ? hits : literal
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Spotlight index off or mdfind failed — fall through to fd/walk.
            }
        }

        if let hits = try await searchWithFd(
            pattern: pattern,
            root: root,
            showHiddenFiles: showHiddenFiles
        ) {
            guard hits.isEmpty, pattern.isGlob else { return hits }
            if let literal = try await searchWithFd(
                pattern: pattern.literalFallback,
                root: root,
                showHiddenFiles: showHiddenFiles
            ), !literal.isEmpty {
                return literal
            }
            return hits
        }

        let hits = try await searchWithEnumerator(
            pattern: pattern,
            root: root,
            showHiddenFiles: showHiddenFiles
        )
        guard hits.isEmpty, pattern.isGlob else { return hits }
        return try await searchWithEnumerator(
            pattern: pattern.literalFallback,
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
            // Finder-like: `.gitignore`d build outputs, logs and .env files are
            // still real files. Heavy dependency/build trees stay excluded by
            // name below so search does not descend into them.
            "--no-ignore",
            // NUL-delimited output keeps filenames containing newlines intact.
            "--print0",
            "--max-results", "\(resultLimit)",
            "--exclude", ".git",
            "--exclude", "node_modules",
            "--exclude", "DerivedData",
            "--exclude", "target",
            "--exclude", ".build",
            "--exclude", "Pods",
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
    ) async throws -> [SearchHit] {
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
                // NUL-delimited so filenames with newlines survive.
                "-0",
                "-onlyin", home,
                namePredicate,
            ]
        )

        try Task.checkCancellation()
        return parsePathLines(output, relativeTo: URL(fileURLWithPath: home))
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
                        id: LocalFileLocation.item(for: next),
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

    /// Bundle-like path extensions Finder does not descend into.
    nonisolated private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "pkg",
        "xcodeproj", "xcworkspace", "playground", "rtfd",
    ]

    /// `true` for paths *inside* a bundle. The bundle itself is not filtered,
    /// so `Demo.app` can still be a search hit.
    nonisolated private static func isInsidePackage(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count > 1 else { return false }
        return components.dropLast().contains { component in
            packageExtensions.contains((component as NSString).pathExtension.lowercased())
        }
    }

    /// Output is NUL-delimited (`fd --print0`, `mdfind -0`). Fall back to
    /// newlines only if a backend produced no NUL at all.
    nonisolated private static func pathEntries(from output: String) -> [String] {
        if output.contains("\0") {
            return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        }
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    nonisolated private static func parsePathLines(_ output: String, relativeTo root: URL) -> [SearchHit] {
        let rootPath = root.path
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(resultLimit, 64))

        for path in pathEntries(from: output) {
            guard !path.isEmpty else { continue }
            // Finder treats bundles as single items.
            guard !isInsidePackage(path) else { continue }

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
                    id: LocalFileLocation.item(for: url),
                    name: url.lastPathComponent,
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
    }

    #if DEBUG
    /// Guards the NUL/package parsing rules (newline filenames, bundle internals)
    /// and the literal fallback for names that look like globs.
    nonisolated static func runSelfCheck() {
        assert(pathEntries(from: "a\0b\0") == ["a", "b"], "NUL path parsing")
        assert(pathEntries(from: "a\nb") == ["a", "b"], "newline fallback parsing")
        assert(isInsidePackage("/Applications/Foo.app/Contents/Info.plist"))
        assert(!isInsidePackage("/Applications/Foo.app"))
        assert(!isInsidePackage("/Users/x/notes.txt"))
        assert(FilenameSearchPattern("*.png").isGlob)
        assert(FilenameSearchPattern("corchetes[1].txt").isGlob)
        assert(
            FilenameSearchPattern("corchetes[1].txt").literalFallback.literalText
                == "corchetes[1].txt"
        )
    }
    #endif

    nonisolated private static func runProcess(executable: String, arguments: [String]) async throws -> String {
        let handle = SearchProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if handle.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let process = handle.process
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    do {
                        try handle.start()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    // Drain both pipes *while* the child runs. Waiting for exit
                    // first deadlocks as soon as the child fills the 64 KB pipe.
                    let out = SearchOutput()
                    let err = SearchOutput()
                    let group = DispatchGroup()

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        out.store(stdout.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        err.store(stderr.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()

                    if handle.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let text = String(data: out.value, encoding: .utf8) ?? ""

                    // fd returns 1 when no matches — treat as empty success.
                    if process.terminationStatus == 0
                        || (executable.hasSuffix("/fd") && process.terminationStatus == 1)
                    {
                        continuation.resume(returning: text)
                    } else {
                        let message = String(data: err.value, encoding: .utf8) ?? ""
                        continuation.resume(
                            throwing: NSError(
                                domain: "ArborSearch",
                                code: Int(process.terminationStatus),
                                userInfo: [
                                    NSLocalizedDescriptionKey: message.isEmpty ? "Search failed" : message,
                                ]
                            )
                        )
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}
