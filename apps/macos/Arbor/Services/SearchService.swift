import Foundation
import AppKit

nonisolated enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolder = "This Folder"
    case global = "Global"

    var id: String { rawValue }
}

/// One search result with its `FileEntry` already materialized off the MainActor.
nonisolated struct SearchHit: Identifiable, Hashable, Sendable {
    let id: ItemRef
    let entry: FileEntry
    let ring: SearchRing

    var name: String { entry.name }
    var parentPath: String { entry.location }
    var isDirectory: Bool { entry.isDirectory }
    var isPackage: Bool { entry.isPackage }
    var isBrowsable: Bool { entry.isBrowsable }
}

/// Progressive snapshot emitted while a search streams results from one or more rings.
nonisolated struct SearchProgressUpdate: Sendable {
    let hits: [SearchHit]
    let countsByRing: [SearchRing: Int]
    let activeBackend: SearchBackendKind
    let isRunning: Bool
    let stopReason: SearchStopReason?
    let elapsedSeconds: Double
}

/// Thread-safe accumulator coordinating concurrent concentric rings and batched UI flushes.
nonisolated private final class SearchStreamCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var merger: SearchRingMerger<SearchHit>
    private var activeBackend: SearchBackendKind = .inMemory
    private var stopReason: SearchStopReason?
    private var dirtyCount = 0
    private var lastEmit = ContinuousClock.now
    private let startedAt = ContinuousClock.now
    private let continuation: AsyncThrowingStream<SearchProgressUpdate, Error>.Continuation
    private let flushBatchSize = 25
    private let flushInterval: Duration = .milliseconds(65)

    init(
        limit: Int,
        continuation: AsyncThrowingStream<SearchProgressUpdate, Error>.Continuation
    ) {
        self.merger = SearchRingMerger(limit: limit)
        self.continuation = continuation
    }

    var isLimitReached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return merger.isLimitReached
    }

    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return merger.totalCount
    }

    func noteBackend(_ backend: SearchBackendKind) {
        lock.lock()
        // Prefer reporting the broadest active engine (Spotlight / fd / walk over inMemory).
        if activeBackend == .inMemory || backend == .spotlight {
            activeBackend = backend
        }
        lock.unlock()
    }

    func noteStopReason(_ reason: SearchStopReason) {
        lock.lock()
        // Keep the most actionable stop reason (limitReached > timedOut > nodeLimitReached > completed).
        switch (stopReason, reason) {
        case (_, .limitReached):
            stopReason = reason
        case (.limitReached, _):
            break
        case (_, .timedOut):
            stopReason = reason
        case (.timedOut, _):
            break
        case (_, .nodeLimitReached):
            stopReason = reason
        case (nil, _):
            stopReason = reason
        default:
            break
        }
        lock.unlock()
    }

    /// Inserts a materialized hit and flushes a snapshot when batch/interval thresholds fire.
    /// Returns `false` when the overall result limit has been reached (caller should cut off).
    func append(canonicalPath: String, ring: SearchRing, hit: SearchHit) -> Bool {
        var snapshot: SearchProgressUpdate?
        let keepGoing: Bool

        lock.lock()
        let result = merger.insert(canonicalPath: canonicalPath, ring: ring, item: hit)
        if result == .inserted {
            dirtyCount += 1
        }
        keepGoing = !merger.isLimitReached
        let now = ContinuousClock.now
        if dirtyCount > 0 && (dirtyCount >= flushBatchSize || (now - lastEmit) >= flushInterval || !keepGoing) {
            dirtyCount = 0
            lastEmit = now
            snapshot = makeSnapshotLocked(isRunning: true, finalReason: nil, now: now)
        }
        lock.unlock()

        if let snapshot {
            continuation.yield(snapshot)
        }
        return keepGoing
    }

    func flushRunning(backend: SearchBackendKind? = nil) {
        lock.lock()
        if let backend {
            noteBackendLocked(backend)
        }
        let now = ContinuousClock.now
        dirtyCount = 0
        lastEmit = now
        let snapshot = makeSnapshotLocked(isRunning: true, finalReason: nil, now: now)
        lock.unlock()
        continuation.yield(snapshot)
    }

    private func noteBackendLocked(_ backend: SearchBackendKind) {
        if activeBackend == .inMemory || backend == .spotlight {
            activeBackend = backend
        }
    }

    func finish(defaultReason: SearchStopReason = .completed) {
        lock.lock()
        let finalReason: SearchStopReason
        if merger.isLimitReached {
            finalReason = .limitReached(limit: merger.limit)
        } else {
            finalReason = stopReason ?? defaultReason
        }
        let snapshot = makeSnapshotLocked(isRunning: false, finalReason: finalReason, now: ContinuousClock.now)
        lock.unlock()
        continuation.yield(snapshot)
        continuation.finish()
    }

    private func makeSnapshotLocked(
        isRunning: Bool,
        finalReason: SearchStopReason?,
        now: ContinuousClock.Instant
    ) -> SearchProgressUpdate {
        let elapsed = startedAt.duration(to: now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return SearchProgressUpdate(
            hits: merger.orderedItems,
            countsByRing: merger.countsByRing,
            activeBackend: activeBackend,
            isRunning: isRunning,
            stopReason: finalReason,
            elapsedSeconds: max(0, seconds)
        )
    }
}

/// Filename search for the macOS UI:
/// - Streams results with early cutoff (`StreamingProcessRunner`) so `mdfind`/`fd` never buffer unbounded output.
/// - Materializes `FileEntry` off the MainActor so sorting/rendering never stalls the UI.
/// - Runs progressive concentric rings (Ring 0 in-memory folder → Ring 1 folder subtree → Ring 2 Global)
///   when enabled, appending outer rings below inner rings so early results never jump.
/// - Enforces hard timeouts, cycle-safe walks, and configurable exclusions/limits.
nonisolated enum SearchService {
    static let resultLimit = SearchOptions.defaultResultLimit
    private static let localProvider = LocalFileProvider()

    static func searchStream(
        query: String,
        scope: SearchScope,
        currentFolder: URL,
        seedEntries: [FileEntry] = [],
        options: SearchOptions = SearchOptions()
    ) -> AsyncThrowingStream<SearchProgressUpdate, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                let pattern = FilenameSearchPattern(query)
                let coordinator = SearchStreamCoordinator(
                    limit: options.resultLimit,
                    continuation: continuation
                )
                guard !pattern.isEmpty else {
                    coordinator.finish(defaultReason: .completed)
                    return
                }

                do {
                    try await executeSearch(
                        pattern: pattern,
                        scope: scope,
                        currentFolder: currentFolder.standardizedFileURL,
                        seedEntries: seedEntries,
                        options: options,
                        coordinator: coordinator
                    )

                    // Literal fallback when a glob-like filename (e.g. `corchetes[1].txt`) yielded 0 hits.
                    if coordinator.totalCount == 0, pattern.isGlob, !Task.isCancelled {
                        try await executeSearch(
                            pattern: pattern.literalFallback,
                            scope: scope,
                            currentFolder: currentFolder.standardizedFileURL,
                            seedEntries: seedEntries,
                            options: options,
                            coordinator: coordinator
                        )
                    }

                    guard !Task.isCancelled else {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    coordinator.finish(defaultReason: .completed)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    /// Convenience one-shot wrapper returning the final hits (used by callers/tests that don't stream).
    static func search(
        query: String,
        scope: SearchScope,
        currentFolder: URL,
        showHiddenFiles: Bool = false,
        options: SearchOptions? = nil
    ) async throws -> [SearchHit] {
        var resolved = options ?? SearchOptions(showHiddenFiles: showHiddenFiles)
        resolved.showHiddenFiles = showHiddenFiles
        var latest: [SearchHit] = []
        for try await update in searchStream(
            query: query,
            scope: scope,
            currentFolder: currentFolder,
            options: resolved
        ) {
            latest = update.hits
        }
        return latest
    }

    // MARK: - Concentric Ring Orchestration

    private static func executeSearch(
        pattern: FilenameSearchPattern,
        scope: SearchScope,
        currentFolder: URL,
        seedEntries: [FileEntry],
        options: SearchOptions,
        coordinator: SearchStreamCoordinator
    ) async throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let displayRootPath = (scope == .global ? homeURL : currentFolder).path
        let excludedNames = Set(options.excludedNames)

        // Ring 0: Instant in-memory match against current folder's loaded children.
        let shouldRunLocalRings = (scope == .currentFolder) || options.progressiveScoping
        if shouldRunLocalRings, !seedEntries.isEmpty {
            let folderPath = currentFolder.path
            for entry in seedEntries {
                try Task.checkCancellation()
                guard SearchPathFilter.matchesFilename(entry.name, pattern: pattern) else { continue }
                if SearchPathFilter.isExcluded(
                    path: entry.fullPath,
                    rootPath: folderPath,
                    isGlobalRoot: false,
                    excludedNames: excludedNames,
                    excludedGlobalRelativePaths: options.excludedGlobalRelativePaths,
                    showHiddenFiles: options.showHiddenFiles
                ) {
                    continue
                }
                let loc = SearchPathFilter.relativeParent(for: entry.fullPath, rootPath: displayRootPath)
                let relEntry = entry.withLocation(loc)
                let hit = SearchHit(id: entry.id, entry: relEntry, ring: .currentFolderDirect)
                if !coordinator.append(canonicalPath: entry.fullPath, ring: .currentFolderDirect, hit: hit) {
                    return
                }
            }
            if coordinator.totalCount > 0 {
                coordinator.flushRunning(backend: .inMemory)
            }
        }

        try Task.checkCancellation()

        switch scope {
        case .currentFolder:
            try await searchSubtree(
                pattern: pattern,
                root: currentFolder,
                displayRootPath: displayRootPath,
                ring: .currentFolderSubtree,
                isGlobalRoot: false,
                options: options,
                coordinator: coordinator
            )

        case .global:
            let runLocalSubtree = options.progressiveScoping && currentFolder.path != homeURL.path
            if runLocalSubtree {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await searchSubtree(
                            pattern: pattern,
                            root: currentFolder,
                            displayRootPath: displayRootPath,
                            ring: .currentFolderSubtree,
                            isGlobalRoot: false,
                            options: options,
                            coordinator: coordinator
                        )
                    }
                    group.addTask {
                        try await searchGlobal(
                            pattern: pattern,
                            homeURL: homeURL,
                            options: options,
                            coordinator: coordinator
                        )
                    }
                    try await group.waitForAll()
                }
            } else {
                try await searchGlobal(
                    pattern: pattern,
                    homeURL: homeURL,
                    options: options,
                    coordinator: coordinator
                )
            }
        }
    }

    // MARK: - Ring Runners

    private static func searchGlobal(
        pattern: FilenameSearchPattern,
        homeURL: URL,
        options: SearchOptions,
        coordinator: SearchStreamCoordinator
    ) async throws {
        // Spotlight first for Global (fast metadata index, avoids cold disk walks & cloud downloads).
        do {
            let succeeded = try await searchWithSpotlight(
                pattern: pattern,
                homeURL: homeURL,
                options: options,
                coordinator: coordinator
            )
            if succeeded { return }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Spotlight unavailable or errored — fall through to bounded fd / cycle-safe walk.
        }

        try await searchSubtree(
            pattern: pattern,
            root: homeURL,
            displayRootPath: homeURL.path,
            ring: .global,
            isGlobalRoot: true,
            options: options,
            coordinator: coordinator
        )
    }

    private static func searchSubtree(
        pattern: FilenameSearchPattern,
        root: URL,
        displayRootPath: String,
        ring: SearchRing,
        isGlobalRoot: Bool,
        options: SearchOptions,
        coordinator: SearchStreamCoordinator
    ) async throws {
        let excludedNameSet = Set(options.excludedNames)
        if let ranFd = try await searchWithFd(
            pattern: pattern,
            root: root,
            displayRootPath: displayRootPath,
            ring: ring,
            isGlobalRoot: isGlobalRoot,
            options: options,
            excludedNameSet: excludedNameSet,
            coordinator: coordinator
        ), ranFd {
            return
        }

        coordinator.flushRunning(backend: .walk)
        let walkResult = try await CycleSafeDirectoryWalker.walk(
            root: root,
            pattern: pattern,
            options: options,
            isGlobalRoot: isGlobalRoot
        ) { path in
            emitPath(
                path,
                rootPath: root.path,
                displayRootPath: displayRootPath,
                ring: ring,
                isGlobalRoot: isGlobalRoot,
                options: options,
                excludedNameSet: excludedNameSet,
                coordinator: coordinator
            )
        }

        if walkResult.stopReason != .completed {
            coordinator.noteStopReason(walkResult.stopReason)
        }
    }

    // MARK: - Spotlight (streaming + early cutoff)

    private static func searchWithSpotlight(
        pattern: FilenameSearchPattern,
        homeURL: URL,
        options: SearchOptions,
        coordinator: SearchStreamCoordinator
    ) async throws -> Bool {
        let homePath = homeURL.path
        let excludedNameSet = Set(options.excludedNames)
        let namePredicate: String
        switch pattern.kind {
        case .substring(let text):
            namePredicate = "kMDItemFSName == '*\(escapeSpotlightLiteral(text))*'cd"
        case .glob(let glob):
            namePredicate = "kMDItemFSName == '\(escapeSpotlightGlob(glob))'cd"
        }

        coordinator.flushRunning(backend: .spotlight)
        let outcome = try await StreamingProcessRunner.run(
            executable: "/usr/bin/mdfind",
            arguments: [
                "-0",
                "-onlyin", homePath,
                namePredicate,
            ],
            timeoutSeconds: options.timeoutSeconds,
            preferNUL: true
        ) { path in
            emitPath(
                path,
                rootPath: homePath,
                displayRootPath: homePath,
                ring: .global,
                isGlobalRoot: true,
                options: options,
                excludedNameSet: excludedNameSet,
                coordinator: coordinator
            )
        }

        switch outcome.reason {
        case .earlyCutoff:
            coordinator.noteStopReason(.limitReached(limit: options.resultLimit))
            return true
        case .timedOut:
            coordinator.noteStopReason(.timedOut(seconds: options.timeoutSeconds))
            return true
        case .cancelled:
            throw CancellationError()
        case .completed:
            return outcome.terminationStatus == 0
        }
    }

    private static func escapeSpotlightLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeSpotlightGlob(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - fd (streaming + early cutoff)

    private static func searchWithFd(
        pattern: FilenameSearchPattern,
        root: URL,
        displayRootPath: String,
        ring: SearchRing,
        isGlobalRoot: Bool,
        options: SearchOptions,
        excludedNameSet: Set<String>,
        coordinator: SearchStreamCoordinator
    ) async throws -> Bool? {
        guard let fd = resolveFdPath() else { return nil }

        // Allow headroom above resultLimit because bundle internals are filtered out in-stream.
        let fdCap = min(50_000, max(options.resultLimit * 3, options.resultLimit + 200))
        var arguments = [
            "--color=never",
            "--ignore-case",
            "--no-ignore",
            "--print0",
            "--max-results", "\(fdCap)",
        ]
        if let maxDepth = options.maxDepth {
            arguments.append(contentsOf: ["--max-depth", "\(maxDepth + 1)"])
        }
        for excluded in options.excludedNames where !excluded.isEmpty {
            arguments.append(contentsOf: ["--exclude", excluded])
        }
        if isGlobalRoot {
            for rel in options.excludedGlobalRelativePaths where !rel.isEmpty {
                arguments.append(contentsOf: ["--exclude", rel])
            }
        }
        if options.showHiddenFiles {
            arguments.append("--hidden")
        }

        let query: String
        switch pattern.kind {
        case .substring(let text):
            arguments.append("--fixed-strings")
            query = text
        case .glob(let glob):
            arguments.append("--glob")
            query = glob
        }
        arguments.append(contentsOf: [query, root.path])

        coordinator.flushRunning(backend: .fd)
        let outcome = try await StreamingProcessRunner.run(
            executable: fd,
            arguments: arguments,
            timeoutSeconds: options.timeoutSeconds,
            preferNUL: true
        ) { path in
            emitPath(
                path,
                rootPath: root.path,
                displayRootPath: displayRootPath,
                ring: ring,
                isGlobalRoot: isGlobalRoot,
                options: options,
                excludedNameSet: excludedNameSet,
                coordinator: coordinator
            )
        }

        switch outcome.reason {
        case .earlyCutoff:
            coordinator.noteStopReason(.limitReached(limit: options.resultLimit))
            return true
        case .timedOut:
            coordinator.noteStopReason(.timedOut(seconds: options.timeoutSeconds))
            return true
        case .cancelled:
            throw CancellationError()
        case .completed:
            return outcome.terminationStatus == 0 || outcome.terminationStatus == 1
        }
    }

    private static func resolveFdPath() -> String? {
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

    // MARK: - Off-main-thread materialization

    private static func emitPath(
        _ rawPath: String,
        rootPath: String,
        displayRootPath: String,
        ring: SearchRing,
        isGlobalRoot: Bool,
        options: SearchOptions,
        excludedNameSet: Set<String>,
        coordinator: SearchStreamCoordinator
    ) -> Bool {
        guard !rawPath.isEmpty else { return true }
        if coordinator.isLimitReached { return false }

        // Trim trailing slash that `fd` appends to directories.
        let path = rawPath.count > 1 && rawPath.hasSuffix("/")
            ? String(rawPath.dropLast())
            : rawPath

        guard !SearchPathFilter.isInsidePackage(path) else { return true }
        guard !SearchPathFilter.isExcluded(
            path: path,
            rootPath: rootPath,
            isGlobalRoot: isGlobalRoot,
            excludedNames: excludedNameSet,
            excludedGlobalRelativePaths: options.excludedGlobalRelativePaths,
            showHiddenFiles: options.showHiddenFiles
        ) else {
            return true
        }

        let url = URL(fileURLWithPath: path)
        let item = LocalFileLocation.item(for: url)
        let location = SearchPathFilter.relativeParent(for: path, rootPath: displayRootPath)

        // Materialize full FileEntry on this background worker (zero MainActor disk I/O).
        let entry: FileEntry
        if let providerEntry = try? localProvider.entrySync(at: item) {
            entry = FileEntry(providerEntry: providerEntry, location: location)
        } else {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                return true
            }
            let name = url.lastPathComponent
            entry = FileEntry(
                id: item,
                name: name,
                isDirectory: isDir.boolValue,
                isPackage: false,
                isHidden: name.hasPrefix("."),
                size: 0,
                kind: isDir.boolValue ? "Folder" : "Document",
                modified: nil,
                created: nil,
                location: location
            )
        }

        let hit = SearchHit(id: item, entry: entry, ring: ring)
        return coordinator.append(canonicalPath: path, ring: ring, hit: hit)
    }

    #if DEBUG
    static func runSelfCheck() {
        assert(SearchPathFilter.isInsidePackage("/Applications/Foo.app/Contents/Info.plist"))
        assert(!SearchPathFilter.isInsidePackage("/Applications/Foo.app"))
        assert(!SearchPathFilter.isInsidePackage("/Users/x/notes.txt"))
        assert(FilenameSearchPattern("*.png").isGlob)
        assert(FilenameSearchPattern("corchetes[1].txt").isGlob)
        assert(
            FilenameSearchPattern("corchetes[1].txt").literalFallback.literalText
                == "corchetes[1].txt"
        )
    }
    #endif
}

private nonisolated extension FileEntry {
    func withLocation(_ newLocation: String) -> FileEntry {
        FileEntry(
            id: id,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: isHidden,
            size: size,
            kind: kind,
            modified: modified,
            created: created,
            location: newLocation
        )
    }
}
