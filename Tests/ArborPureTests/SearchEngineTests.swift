import XCTest
@testable import ArborPure

final class SearchEngineTests: XCTestCase {

    private final class LockedList<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Element] = []

        func append(_ item: Element) -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage.append(item)
            return storage.count
        }

        var snapshot: [Element] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - StreamingPathSplitter

    func testSplitterHandlesNULAcrossArbitraryChunkBoundariesAndNewlinesInFilenames() {
        var splitter = StreamingPathSplitter(preferNUL: true)
        let raw = "/tmp/hello\nworld.txt\0/tmp/café-🚀.pdf\0/tmp/last.md\0"
        let bytes = Data(raw.utf8)

        var collected: [String] = []
        // Feed 3 bytes at a time so multibyte UTF-8 and NUL delimiters split mid-sequence.
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 3, bytes.count)
            collected.append(contentsOf: splitter.append(bytes.subdata(in: offset..<end)))
            offset = end
        }
        collected.append(contentsOf: splitter.finish())

        XCTAssertEqual(collected, [
            "/tmp/hello\nworld.txt",
            "/tmp/café-🚀.pdf",
            "/tmp/last.md",
        ])
    }

    func testSplitterFallsBackToNewlinesWhenNoNULPresent() {
        var splitter = StreamingPathSplitter(preferNUL: true)
        var collected: [String] = []
        collected.append(contentsOf: splitter.append(Data("/a/one.txt\r\n/a/tw".utf8)))
        collected.append(contentsOf: splitter.append(Data("o.txt\n/a/three.txt".utf8)))
        collected.append(contentsOf: splitter.finish())

        XCTAssertEqual(collected, ["/a/one.txt", "/a/two.txt", "/a/three.txt"])
    }

    // MARK: - SearchPathFilter

    func testIsInsidePackageKeepsBundleItselfButSkipsInternals() {
        XCTAssertFalse(SearchPathFilter.isInsidePackage("/Applications/Arbor.app"))
        XCTAssertTrue(SearchPathFilter.isInsidePackage("/Applications/Arbor.app/Contents/Info.plist"))
        XCTAssertFalse(SearchPathFilter.isInsidePackage("/Users/me/Project.xcodeproj"))
        XCTAssertTrue(SearchPathFilter.isInsidePackage("/Users/me/Project.xcodeproj/project.pbxproj"))
    }

    func testIsExcludedSkipsGlobalPathsInGlobalModeButAllowsExplicitFolderSearch() {
        let excludedNames = Set(SearchOptions.defaultExcludedNames)
        let globalPrefixes = SearchOptions.defaultExcludedGlobalRelativePaths

        // Global search rooted at $HOME skips Library/Caches and CloudStorage.
        XCTAssertTrue(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Library/Caches/foo/bar.json",
                rootPath: "/Users/me",
                isGlobalRoot: true,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: false
            )
        )
        XCTAssertTrue(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Library/CloudStorage/iCloud/doc.pdf",
                rootPath: "/Users/me",
                isGlobalRoot: true,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: false
            )
        )

        // Explicit folder search *inside* ~/Library/Caches must still return files there!
        XCTAssertFalse(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Library/Caches/foo/bar.json",
                rootPath: "/Users/me/Library/Caches",
                isGlobalRoot: false,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: false
            )
        )

        // Hidden files respect showHiddenFiles toggle.
        XCTAssertTrue(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Workspace/.env",
                rootPath: "/Users/me/Workspace",
                isGlobalRoot: false,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: false
            )
        )
        XCTAssertFalse(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Workspace/.env",
                rootPath: "/Users/me/Workspace",
                isGlobalRoot: false,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: true
            )
        )

        // Excluded names (.git, node_modules) stay excluded even with showHiddenFiles=true.
        XCTAssertTrue(
            SearchPathFilter.isExcluded(
                path: "/Users/me/Workspace/app/node_modules/pkg/index.js",
                rootPath: "/Users/me/Workspace",
                isGlobalRoot: false,
                excludedNames: excludedNames,
                excludedGlobalRelativePaths: globalPrefixes,
                showHiddenFiles: true
            )
        )
    }

    func testNextExpandedLimitProgressesThroughPresets() {
        XCTAssertEqual(SearchOptions.nextExpandedLimit(after: 200), 500)
        XCTAssertEqual(SearchOptions.nextExpandedLimit(after: 500), 2_000)
        XCTAssertEqual(SearchOptions.nextExpandedLimit(after: 2_000), 5_000)
        XCTAssertNil(SearchOptions.nextExpandedLimit(after: 5_000))
    }

    // MARK: - SearchRingMerger

    func testRingMergerDeduplicatesAndKeepsInnerRingsFirst() {
        var merger = SearchRingMerger<String>(limit: 10)

        // Ring 0 direct hit
        XCTAssertEqual(merger.insert(canonicalPath: "/w/a.pdf", ring: .currentFolderDirect, item: "a"), .inserted)
        // Ring 2 global hit arrives before Ring 1 finishes
        XCTAssertEqual(merger.insert(canonicalPath: "/home/g1.pdf", ring: .global, item: "g1"), .inserted)
        // Ring 1 subtree hit arrives after Ring 2 — still placed ahead of Ring 2!
        XCTAssertEqual(merger.insert(canonicalPath: "/w/sub/b.pdf", ring: .currentFolderSubtree, item: "b"), .inserted)
        // Duplicate from outer ring is ignored
        XCTAssertEqual(merger.insert(canonicalPath: "/w/a.pdf", ring: .global, item: "a-dup"), .duplicate)
        XCTAssertEqual(merger.insert(canonicalPath: "/w/sub/b.pdf", ring: .global, item: "b-dup"), .duplicate)

        XCTAssertEqual(merger.orderedItems, ["a", "b", "g1"])
        XCTAssertEqual(merger.totalCount, 3)
        XCTAssertEqual(merger.countsByRing[.currentFolderDirect], 1)
        XCTAssertEqual(merger.countsByRing[.currentFolderSubtree], 1)
        XCTAssertEqual(merger.countsByRing[.global], 1)
        XCTAssertFalse(merger.isLimitReached)
    }

    func testRingMergerEnforcesLimitStrictly() {
        var merger = SearchRingMerger<Int>(limit: 3)
        XCTAssertEqual(merger.insert(canonicalPath: "/1", ring: .currentFolderDirect, item: 1), .inserted)
        XCTAssertEqual(merger.insert(canonicalPath: "/2", ring: .currentFolderSubtree, item: 2), .inserted)
        XCTAssertEqual(merger.insert(canonicalPath: "/3", ring: .global, item: 3), .inserted)
        XCTAssertTrue(merger.isLimitReached)
        XCTAssertEqual(merger.insert(canonicalPath: "/4", ring: .global, item: 4), .limitReached)
        XCTAssertEqual(merger.orderedItems, [1, 2, 3])
    }

    // MARK: - StreamingProcessRunner

    func testStreamingProcessRunnerCutsOffInfiniteProducerEarly() async throws {
        let received = LockedList<String>()
        let start = ContinuousClock.now

        // Infinite NUL-delimited producer — without early cutoff this would hang forever.
        let outcome = try await StreamingProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while true; do printf '/tmp/item-%d.txt\\0' \"$i\"; i=$((i+1)); done"],
            timeoutSeconds: 5.0,
            preferNUL: true
        ) { line in
            received.append(line) < 15
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(outcome.reason, .earlyCutoff)
        let items = received.snapshot
        XCTAssertEqual(items.count, 15)
        XCTAssertEqual(items.first, "/tmp/item-0.txt")
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testStreamingProcessRunnerEnforcesHardTimeoutWithoutHanging() async throws {
        let start = ContinuousClock.now
        let outcome = try await StreamingProcessRunner.run(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeoutSeconds: 0.25,
            preferNUL: true
        ) { _ in true }

        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(outcome.reason, .timedOut)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testStreamingProcessRunnerRespectsTaskCancellation() async {
        let start = ContinuousClock.now
        let task = Task {
            try await StreamingProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["30"],
                timeoutSeconds: 10.0,
                preferNUL: true
            ) { _ in true }
        }

        try? await Task.sleep(for: .milliseconds(120))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - CycleSafeDirectoryWalker

    func testWalkerDefeatsSymlinkCycleAndSkipsPackagesAndExcludedDirs() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arbor-walk-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Build structure:
        // root/top-match.txt
        // root/sub/deep-match.txt
        // root/sub/loop -> root (symlink cycle!)
        // root/node_modules/ignored-match.txt
        // root/Demo.app/Contents/inside-match.txt
        // root/match.app (bundle itself SHOULD match!)
        let sub = root.appendingPathComponent("sub")
        let nm = root.appendingPathComponent("node_modules")
        let appContents = root.appendingPathComponent("Demo.app/Contents")
        let matchApp = root.appendingPathComponent("match.app")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try fm.createDirectory(at: appContents, withIntermediateDirectories: true)
        try fm.createDirectory(at: matchApp, withIntermediateDirectories: true)

        fm.createFile(atPath: root.appendingPathComponent("top-match.txt").path, contents: Data())
        fm.createFile(atPath: sub.appendingPathComponent("deep-match.txt").path, contents: Data())
        fm.createFile(atPath: nm.appendingPathComponent("ignored-match.txt").path, contents: Data())
        fm.createFile(atPath: appContents.appendingPathComponent("inside-match.txt").path, contents: Data())
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: root)

        let matches = LockedList<String>()

        let result = try await CycleSafeDirectoryWalker.walk(
            root: root,
            pattern: FilenameSearchPattern("match"),
            options: SearchOptions(resultLimit: 100, timeoutSeconds: 5.0),
            isGlobalRoot: false
        ) { path in
            _ = matches.append((path as NSString).lastPathComponent)
            return true
        }

        let foundMatches = matches.snapshot
        XCTAssertEqual(result.stopReason, .completed)
        // Shallow matches come before deep matches (BFS), bundle itself matches, internals & node_modules skipped.
        XCTAssertTrue(foundMatches.contains("top-match.txt"))
        XCTAssertTrue(foundMatches.contains("match.app"))
        XCTAssertTrue(foundMatches.contains("deep-match.txt"))
        XCTAssertFalse(foundMatches.contains("ignored-match.txt"))
        XCTAssertFalse(foundMatches.contains("inside-match.txt"))

        let topIdx = foundMatches.firstIndex(of: "top-match.txt")!
        let deepIdx = foundMatches.firstIndex(of: "deep-match.txt")!
        XCTAssertLessThan(topIdx, deepIdx)
    }

    func testWalkerEnforcesMaxVisitedNodesAndMaxDepth() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arbor-limits-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("d1/d2/d3")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        fm.createFile(atPath: root.appendingPathComponent("f0.txt").path, contents: Data())
        fm.createFile(atPath: root.appendingPathComponent("d1/f1.txt").path, contents: Data())
        fm.createFile(atPath: deep.appendingPathComponent("f3.txt").path, contents: Data())

        let found = LockedList<String>()
        let depthResult = try await CycleSafeDirectoryWalker.walk(
            root: root,
            pattern: FilenameSearchPattern(".txt"),
            options: SearchOptions(resultLimit: 100, timeoutSeconds: 5.0, maxDepth: 1),
            isGlobalRoot: false
        ) { path in
            _ = found.append((path as NSString).lastPathComponent)
            return true
        }

        let depthMatches = found.snapshot
        XCTAssertEqual(depthResult.stopReason, .completed)
        XCTAssertTrue(depthMatches.contains("f0.txt"))
        XCTAssertTrue(depthMatches.contains("f1.txt"))
        XCTAssertFalse(depthMatches.contains("f3.txt"))

        // Now create >120 files and verify maxVisitedNodes guardrail triggers cleanly.
        for i in 0..<130 {
            fm.createFile(atPath: root.appendingPathComponent("item-\(i).log").path, contents: Data())
        }
        let nodeResult = try await CycleSafeDirectoryWalker.walk(
            root: root,
            pattern: FilenameSearchPattern("never-matches"),
            options: SearchOptions(resultLimit: 100, timeoutSeconds: 5.0, maxVisitedNodes: 100),
            isGlobalRoot: false
        ) { _ in true }

        if case .nodeLimitReached(let visited) = nodeResult.stopReason {
            XCTAssertEqual(visited, 100)
        } else {
            XCTFail("Expected .nodeLimitReached, got \(nodeResult.stopReason)")
        }
    }

    // MARK: - SearchPreferencesStore

    @MainActor
    func testSearchPreferencesStorePersistsOverridesAndResetsCleanly() {
        let suiteName = "arbor.test.searchPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.resultLimit, SearchOptions.defaultResultLimit)
        XCTAssertEqual(store.timeoutSeconds, SearchOptions.defaultTimeoutSeconds)
        XCTAssertTrue(store.progressiveScoping)
        XCTAssertFalse(store.openGlobalInNewTab)

        store.resultLimit = 2_000
        store.timeoutSeconds = 20
        store.maxDepth = 6
        store.progressiveScoping = false
        store.openGlobalInNewTab = true
        store.excludedNames = SearchPreferencesStore.parseCSVList(" .git, build , , dist ")

        let reloaded = SearchPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.resultLimit, 2_000)
        XCTAssertEqual(reloaded.timeoutSeconds, 20)
        XCTAssertEqual(reloaded.maxDepth, 6)
        XCTAssertFalse(reloaded.progressiveScoping)
        XCTAssertTrue(reloaded.openGlobalInNewTab)
        XCTAssertEqual(reloaded.excludedNames, [".git", "build", "dist"])

        let options = reloaded.makeOptions(showHiddenFiles: true, resultLimitOverride: 5_000, timeoutOverride: 30)
        XCTAssertEqual(options.resultLimit, 5_000)
        XCTAssertEqual(options.timeoutSeconds, 30)
        XCTAssertEqual(options.maxDepth, 6)
        XCTAssertTrue(options.showHiddenFiles)

        reloaded.resetDefaults()
        XCTAssertEqual(reloaded.resultLimit, SearchOptions.defaultResultLimit)
        XCTAssertEqual(reloaded.maxDepth, 0)
        XCTAssertTrue(reloaded.progressiveScoping)
        XCTAssertFalse(reloaded.openGlobalInNewTab)
    }
}
