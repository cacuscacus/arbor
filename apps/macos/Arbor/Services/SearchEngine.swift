import Foundation
import Darwin

/// Progressive search ring ordered from closest (fastest) to broadest.
nonisolated enum SearchRing: Int, Comparable, CaseIterable, Hashable, Sendable {
    case currentFolderDirect = 0
    case currentFolderSubtree = 1
    case global = 2
    /// Related hits found via opt-in local MLX term expansion (always below direct hits).
    case expanded = 3

    static func < (lhs: SearchRing, rhs: SearchRing) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .currentFolderDirect: return "This Folder"
        case .currentFolderSubtree: return "Subfolders"
        case .global: return "Home"
        case .expanded: return "Related"
        }
    }
}

/// Filename vs file-content (`grep` / Spotlight text) search mode.
nonisolated enum SearchMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name = "Name"
    case content = "Content"

    var id: String { rawValue }
}

/// Which search engine produced results for a run.
nonisolated enum SearchBackendKind: String, Hashable, Sendable {
    case inMemory = "Folder"
    case spotlight = "Spotlight"
    case spotlightContent = "Spotlight Content"
    case fd = "fd"
    case ripgrep = "ripgrep"
    case walk = "Disk Walk"
}

/// Why a search finished. Non-error stops preserve all partial results.
nonisolated enum SearchStopReason: Equatable, Sendable {
    case completed
    case limitReached(limit: Int)
    case timedOut(seconds: Double)
    case nodeLimitReached(visited: Int)
    case stoppedByUser
}

/// Configurable guardrails and UX knobs for filename (and future content) search.
nonisolated struct SearchOptions: Equatable, Sendable {
    static let defaultResultLimit = 500
    static let defaultTimeoutSeconds: Double = 10.0
    static let defaultMaxVisitedNodes = 150_000
    static let defaultMaxContentFileSizeMB = 5
    static let defaultMaxMatchesPerFile = 5
    static let limitPresets = [200, 500, 2_000, 5_000]
    static let timeoutPresets: [Double] = [5, 10, 20, 30]
    static let maxVisitedPresets = [50_000, 150_000, 500_000]
    /// `0` means unlimited file size.
    static let maxContentFileSizeMBPresets = [1, 5, 25, 0]
    static let maxMatchesPerFilePresets = [3, 5, 10]

    static let defaultExcludedNames: [String] = [
        ".git",
        "node_modules",
        "DerivedData",
        "target",
        ".build",
        "Pods",
        ".Trash",
        ".venv",
        "__pycache__",
    ]

    /// Relative prefixes under `$HOME` skipped during Global searches to avoid
    /// cache storms, TCC prompts, and triggering iCloud/CloudStorage downloads.
    static let defaultExcludedGlobalRelativePaths: [String] = [
        "Library/Caches",
        "Library/CloudStorage",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Application Support/MobileSync",
        ".Trash",
    ]

    var resultLimit: Int
    var timeoutSeconds: Double
    var maxVisitedNodes: Int
    var maxDepth: Int?
    var progressiveScoping: Bool
    var excludedNames: [String]
    var excludedGlobalRelativePaths: [String]
    var showHiddenFiles: Bool
    /// Max file size (in MB) scanned during content grep (`0` = unlimited).
    var maxContentFileSizeMB: Int
    /// Whether content grep respects `.gitignore` rules (default `true`).
    var respectGitignoreInContent: Bool
    /// Max snippet matches kept per file in content search.
    var maxMatchesPerFile: Int
    /// When `true`, Global content search runs bounded `rg` on disk instead of Spotlight.
    var deepGlobalContentScan: Bool
    /// Active opt-in related search tokens produced by local MLX expansion (run in `.expanded` ring).
    var expandedTerms: [String]

    var maxContentFileSizeBytes: UInt64? {
        maxContentFileSizeMB > 0 ? UInt64(maxContentFileSizeMB) * 1_024 * 1_024 : nil
    }

    init(
        resultLimit: Int = Self.defaultResultLimit,
        timeoutSeconds: Double = Self.defaultTimeoutSeconds,
        maxVisitedNodes: Int = Self.defaultMaxVisitedNodes,
        maxDepth: Int? = nil,
        progressiveScoping: Bool = true,
        excludedNames: [String] = Self.defaultExcludedNames,
        excludedGlobalRelativePaths: [String] = Self.defaultExcludedGlobalRelativePaths,
        showHiddenFiles: Bool = false,
        maxContentFileSizeMB: Int = Self.defaultMaxContentFileSizeMB,
        respectGitignoreInContent: Bool = true,
        maxMatchesPerFile: Int = Self.defaultMaxMatchesPerFile,
        deepGlobalContentScan: Bool = false,
        expandedTerms: [String] = []
    ) {
        self.resultLimit = max(1, resultLimit)
        self.timeoutSeconds = max(0.5, timeoutSeconds)
        self.maxVisitedNodes = max(100, maxVisitedNodes)
        self.maxDepth = maxDepth.map { max(0, $0) }
        self.progressiveScoping = progressiveScoping
        self.excludedNames = excludedNames
        self.excludedGlobalRelativePaths = excludedGlobalRelativePaths
        self.showHiddenFiles = showHiddenFiles
        self.maxContentFileSizeMB = max(0, maxContentFileSizeMB)
        self.respectGitignoreInContent = respectGitignoreInContent
        self.maxMatchesPerFile = max(1, maxMatchesPerFile)
        self.deepGlobalContentScan = deepGlobalContentScan
        self.expandedTerms = expandedTerms
    }

    /// Next larger result limit preset when the user clicks "Load more".
    static func nextExpandedLimit(after current: Int) -> Int? {
        for preset in limitPresets where preset > current {
            return preset
        }
        return nil
    }
}

/// Incremental byte-stream splitter for NUL-delimited (`mdfind -0`, `fd --print0`)
/// or newline-delimited output. Handles arbitrary chunk boundaries safely.
nonisolated struct StreamingPathSplitter: Sendable {
    private var buffer = Data()
    private var detectedNUL = false
    private let preferNUL: Bool

    init(preferNUL: Bool = true) {
        self.preferNUL = preferNUL
    }

    mutating func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        if preferNUL, buffer.contains(0) {
            detectedNUL = true
        }
        return drainCompleteLines(useNUL: detectedNUL || preferNUL)
    }

    mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        var emitted = drainCompleteLines(useNUL: detectedNUL)
        if !buffer.isEmpty {
            let remaining = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: false)
            if detectedNUL {
                if !remaining.isEmpty {
                    emitted.append(remaining)
                }
            } else {
                // Fallback for tools/tests emitting newline-delimited paths without NUL.
                for part in remaining.split(whereSeparator: \.isNewline) where !part.isEmpty {
                    emitted.append(String(part))
                }
            }
        }
        return emitted
    }

    private mutating func drainCompleteLines(useNUL: Bool) -> [String] {
        let delimiter: UInt8 = useNUL ? 0 : 0x0A
        var results: [String] = []
        var searchStart = buffer.startIndex

        while let idx = buffer[searchStart...].firstIndex(of: delimiter) {
            if idx > searchStart {
                var slice = buffer[searchStart..<idx]
                if !useNUL, slice.last == 0x0D {
                    slice = slice.dropLast()
                }
                if !slice.isEmpty {
                    results.append(String(decoding: slice, as: UTF8.self))
                }
            }
            searchStart = buffer.index(after: idx)
        }

        if searchStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<searchStart)
        }
        return results
    }
}

/// Pure path filtering, package detection, and filename matching helpers.
nonisolated enum SearchPathFilter {
    /// Bundle-like extensions Finder treats as single items (never descends into them).
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "pkg",
        "xcodeproj", "xcworkspace", "playground", "rtfd",
    ]

    /// `true` for paths *inside* a bundle. The bundle itself is kept so `Demo.app` matches.
    static func isInsidePackage(_ path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count > 1 else { return false }
        return components.dropLast().contains { component in
            packageExtensions.contains((component as NSString).pathExtension.lowercased())
        }
    }

    /// `true` when `path` falls inside an excluded folder name or excluded Global prefix.
    /// Checking relative to `rootPath` ensures searching explicitly *inside* an excluded
    /// directory (e.g., opening `~/Library/Caches` in "This Folder" mode) still works.
    static func isExcluded(
        path: String,
        rootPath: String,
        isGlobalRoot: Bool,
        excludedNames: Set<String>,
        excludedGlobalRelativePaths: [String],
        showHiddenFiles: Bool
    ) -> Bool {
        let normalizedRoot = rootPath.hasSuffix("/") && rootPath.count > 1
            ? String(rootPath.dropLast())
            : rootPath

        let relative: String
        if path == normalizedRoot {
            return false
        } else if normalizedRoot == "/" {
            relative = String(path.dropFirst())
        } else if path.hasPrefix(normalizedRoot + "/") {
            relative = String(path.dropFirst(normalizedRoot.count + 1))
        } else {
            relative = path
        }

        if isGlobalRoot {
            for prefix in excludedGlobalRelativePaths {
                let clean = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !clean.isEmpty else { continue }
                if relative == clean || relative.hasPrefix(clean + "/") {
                    return true
                }
            }
        }

        let parts = relative.split(separator: "/")
        for part in parts {
            let segment = String(part)
            if excludedNames.contains(segment) {
                return true
            }
            if !showHiddenFiles, segment.hasPrefix(".") {
                return true
            }
        }
        return false
    }

    static func matchesFilename(_ name: String, pattern: FilenameSearchPattern) -> Bool {
        switch pattern.kind {
        case .substring(let text):
            if text.isEmpty { return true }
            return name.localizedCaseInsensitiveContains(text)
        case .glob(let glob):
            return glob.withCString { patternC in
                name.withCString { nameC in
                    fnmatch(patternC, nameC, FNM_CASEFOLD) == 0
                }
            }
        }
    }

    static func relativeParent(for path: String, rootPath: String) -> String {
        let normalizedRoot = rootPath.hasSuffix("/") && rootPath.count > 1
            ? String(rootPath.dropLast())
            : rootPath
        let parent = (path as NSString).deletingLastPathComponent
        if parent == normalizedRoot { return "." }
        if normalizedRoot == "/" {
            return parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
        }
        if parent.hasPrefix(normalizedRoot + "/") {
            return String(parent.dropFirst(normalizedRoot.count + 1))
        }
        return parent
    }
}

/// Deduplicates and orders progressive concentric-ring hits so outer rings always
/// append *below* closer rings without shifting early results under the user's cursor.
nonisolated struct SearchRingMerger<Item: Sendable>: Sendable {
    enum InsertResult: Equatable, Sendable {
        case inserted
        case duplicate
        case limitReached
    }

    let limit: Int
    private var buckets: [SearchRing: [Item]] = [:]
    private var seenByPath: [String: (ring: SearchRing, index: Int)] = [:]
    private(set) var totalCount = 0
    private(set) var isLimitReached = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var countsByRing: [SearchRing: Int] {
        var result: [SearchRing: Int] = [:]
        for ring in SearchRing.allCases {
            let count = buckets[ring]?.count ?? 0
            if count > 0 {
                result[ring] = count
            }
        }
        return result
    }

    var orderedItems: [Item] {
        var combined: [Item] = []
        combined.reserveCapacity(totalCount)
        for ring in SearchRing.allCases {
            if let bucket = buckets[ring] {
                combined.append(contentsOf: bucket)
            }
        }
        return combined
    }

    @discardableResult
    mutating func insert(canonicalPath: String, ring: SearchRing, item: Item) -> InsertResult {
        if seenByPath[canonicalPath] != nil {
            return .duplicate
        }

        if totalCount >= limit {
            isLimitReached = true
            return .limitReached
        }

        let idx = buckets[ring, default: []].count
        seenByPath[canonicalPath] = (ring, idx)
        buckets[ring, default: []].append(item)
        totalCount += 1
        if totalCount >= limit {
            isLimitReached = true
        }
        return .inserted
    }

    /// Inserts a new item or updates the existing item in-place (used to attach multiple
    /// content-match snippets to a single file row without duplicating it).
    @discardableResult
    mutating func upsert(
        canonicalPath: String,
        ring: SearchRing,
        create: () -> Item,
        update: (inout Item) -> Bool
    ) -> InsertResult {
        if let loc = seenByPath[canonicalPath] {
            guard var bucket = buckets[loc.ring], bucket.indices.contains(loc.index) else {
                return .duplicate
            }
            let mutated = update(&bucket[loc.index])
            if mutated {
                buckets[loc.ring] = bucket
            }
            return .duplicate
        }

        if totalCount >= limit {
            isLimitReached = true
            return .limitReached
        }

        let item = create()
        let idx = buckets[ring, default: []].count
        seenByPath[canonicalPath] = (ring, idx)
        buckets[ring, default: []].append(item)
        totalCount += 1
        if totalCount >= limit {
            isLimitReached = true
        }
        return .inserted
    }
}

/// POSIX device+inode identity used to prevent symlink/firmlink directory cycles.
nonisolated struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    static func of(path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: st.st_dev, inode: st.st_ino)
    }

    static func ofResolvedTarget(path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return FileIdentity(device: st.st_dev, inode: st.st_ino)
    }
}

/// Result of running a streaming external search process (`mdfind`, `fd`, etc.).
nonisolated struct StreamingProcessOutcome: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case completed
        case earlyCutoff
        case timedOut
        case cancelled
    }

    let reason: Reason
    let terminationStatus: Int32
    let stderr: String
}

/// Thread-safe process lifecycle guard with hard `SIGTERM` → `SIGKILL` escalation.
nonisolated final class HardKillProcessHandle: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var started = false
    private var terminated = false
    private var reason: StreamingProcessOutcome.Reason?

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if terminated {
            throw CancellationError()
        }
        try process.run()
        started = true
    }

    func stop(reason stopReason: StreamingProcessOutcome.Reason) {
        lock.lock()
        if reason == nil {
            reason = stopReason
        }
        terminated = true
        let running = started && process.isRunning
        let pid = started ? process.processIdentifier : 0
        lock.unlock()

        guard running, pid > 0 else { return }
        process.terminate()
        // Escalate to SIGKILL if the child ignores SIGTERM or is stuck on I/O.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    var stopReason: StreamingProcessOutcome.Reason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

/// Runs a subprocess and streams delimited output lines without buffering the whole
/// stdout into RAM. Supports immediate early cutoff, hard timeout, and cancellation.
nonisolated enum StreamingProcessRunner {
    private static let readChunkSize = 16_384
    private static let maxStderrBytes = 64 * 1024

    static func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double,
        preferNUL: Bool = true,
        onLine: @escaping @Sendable (String) -> Bool
    ) async throws -> StreamingProcessOutcome {
        let handle = HardKillProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if handle.stopReason == .cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let process = handle.process
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        try handle.start()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    // Hard deadline timer so a stalled Spotlight/disk process can never hang.
                    let timeoutTimer = DispatchSource.makeTimerSource(
                        queue: DispatchQueue.global(qos: .userInitiated)
                    )
                    timeoutTimer.schedule(
                        deadline: .now() + max(0.05, timeoutSeconds),
                        leeway: .milliseconds(25)
                    )
                    timeoutTimer.setEventHandler {
                        handle.stop(reason: .timedOut)
                        try? stdoutPipe.fileHandleForReading.close()
                    }
                    timeoutTimer.resume()

                    // Drain stderr concurrently (capped to 64 KB) so the pipe never deadlocks.
                    let stderrLock = NSLock()
                    var stderrBuffer = Data()
                    let stderrGroup = DispatchGroup()
                    stderrGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { stderrGroup.leave() }
                        let fh = stderrPipe.fileHandleForReading
                        while true {
                            let chunk = (try? fh.read(upToCount: 4096)) ?? Data()
                            if chunk.isEmpty { break }
                            stderrLock.lock()
                            if stderrBuffer.count < maxStderrBytes {
                                let room = maxStderrBytes - stderrBuffer.count
                                stderrBuffer.append(chunk.prefix(room))
                            }
                            stderrLock.unlock()
                        }
                    }

                    // Stream stdout incrementally and cut off immediately when `onLine` returns false.
                    var splitter = StreamingPathSplitter(preferNUL: preferNUL)
                    let outHandle = stdoutPipe.fileHandleForReading
                    var keepGoing = true

                    while keepGoing {
                        if handle.stopReason != nil {
                            break
                        }
                        let chunk: Data
                        do {
                            chunk = try outHandle.read(upToCount: readChunkSize) ?? Data()
                        } catch {
                            break
                        }
                        if chunk.isEmpty {
                            break
                        }
                        let lines = splitter.append(chunk)
                        for line in lines {
                            if handle.stopReason != nil {
                                keepGoing = false
                                break
                            }
                            if !onLine(line) {
                                handle.stop(reason: .earlyCutoff)
                                try? outHandle.close()
                                keepGoing = false
                                break
                            }
                        }
                    }

                    if keepGoing, handle.stopReason == nil {
                        for line in splitter.finish() {
                            if !onLine(line) {
                                handle.stop(reason: .earlyCutoff)
                                break
                            }
                        }
                    }

                    try? outHandle.close()
                    timeoutTimer.cancel()
                    process.waitUntilExit()
                    stderrGroup.wait()
                    try? stderrPipe.fileHandleForReading.close()

                    stderrLock.lock()
                    let stderrText = String(decoding: stderrBuffer, as: UTF8.self)
                    stderrLock.unlock()

                    if let stopReason = handle.stopReason {
                        if stopReason == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(
                                returning: StreamingProcessOutcome(
                                    reason: stopReason,
                                    terminationStatus: process.terminationStatus,
                                    stderr: stderrText
                                )
                            )
                        }
                        return
                    }

                    continuation.resume(
                        returning: StreamingProcessOutcome(
                            reason: .completed,
                            terminationStatus: process.terminationStatus,
                            stderr: stderrText
                        )
                    )
                }
            }
        } onCancel: {
            handle.stop(reason: .cancelled)
        }
    }
}

/// Breadth-first, cycle-safe, bounded directory walker.
/// Discovers shallow matches first, tracks `(dev, ino)` to defeat symlink/mount cycles,
/// enforces `maxVisitedNodes`, `maxDepth`, and hard deadlines.
nonisolated enum CycleSafeDirectoryWalker {
    struct WalkResult: Sendable, Equatable {
        let stopReason: SearchStopReason
        let visitedNodes: Int
        let matchedCount: Int
    }

    static func walk(
        root: URL,
        pattern: FilenameSearchPattern,
        options: SearchOptions,
        isGlobalRoot: Bool,
        onMatch: @escaping @Sendable (String) -> Bool
    ) async throws -> WalkResult {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let excludedNameSet = Set(options.excludedNames)
        let deadline = ContinuousClock.now + .seconds(options.timeoutSeconds)

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var visitedDirs = Set<FileIdentity>()
            if let rootID = FileIdentity.ofResolvedTarget(path: rootPath) {
                visitedDirs.insert(rootID)
            }

            // BFS queue: (directory URL, depth of its children).
            var queue: [(URL, Int)] = [(rootURL, 0)]
            var queueHead = 0
            var visitedNodes = 0
            var matchedCount = 0
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .nameKey,
            ]

            while queueHead < queue.count {
                let (dirURL, depth) = queue[queueHead]
                queueHead += 1
                // Periodically compact consumed prefix to keep memory flat.
                if queueHead > 2048 {
                    queue.removeFirst(queueHead)
                    queueHead = 0
                }

                try Task.checkCancellation()
                if ContinuousClock.now >= deadline {
                    return WalkResult(
                        stopReason: .timedOut(seconds: options.timeoutSeconds),
                        visitedNodes: visitedNodes,
                        matchedCount: matchedCount
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
                    if visitedNodes & 63 == 0 {
                        try Task.checkCancellation()
                        if ContinuousClock.now >= deadline {
                            return WalkResult(
                                stopReason: .timedOut(seconds: options.timeoutSeconds),
                                visitedNodes: visitedNodes,
                                matchedCount: matchedCount
                            )
                        }
                    }

                    if visitedNodes > options.maxVisitedNodes {
                        return WalkResult(
                            stopReason: .nodeLimitReached(visited: visitedNodes - 1),
                            visitedNodes: visitedNodes - 1,
                            matchedCount: matchedCount
                        )
                    }

                    let name = child.lastPathComponent
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

                    if SearchPathFilter.matchesFilename(name, pattern: pattern) {
                        matchedCount += 1
                        if !onMatch(childPath) {
                            return WalkResult(
                                stopReason: .limitReached(limit: options.resultLimit),
                                visitedNodes: visitedNodes,
                                matchedCount: matchedCount
                            )
                        }
                        if matchedCount >= options.resultLimit {
                            return WalkResult(
                                stopReason: .limitReached(limit: options.resultLimit),
                                visitedNodes: visitedNodes,
                                matchedCount: matchedCount
                            )
                        }
                    }

                    let values = try? child.resourceValues(forKeys: Set(keys))
                    let isDirectory = values?.isDirectory ?? false
                    let isPackage = values?.isPackage ?? false
                    let isSymlink = values?.isSymbolicLink ?? false

                    guard isDirectory, !isPackage, !isSymlink else { continue }
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
                }
            }

            return WalkResult(
                stopReason: .completed,
                visitedNodes: visitedNodes,
                matchedCount: matchedCount
            )
        }.value
    }
}
