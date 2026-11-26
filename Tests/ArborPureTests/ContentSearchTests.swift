import XCTest
@testable import ArborPure

final class ContentSearchTests: XCTestCase {

    private final class LockedMap<Key: Hashable, Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Key: Value] = [:]

        func set(_ key: Key, _ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = value
        }

        var snapshot: [Key: Value] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - ContentMatchSnippet

    func testSnippetTrimsLeadingWhitespaceAndTracksUTF8Offsets() {
        // "    café auth_token 🚀\n"
        // UTF-8 byte offsets:
        // "    " (4) + "café" (c=1,a=1,f=1,é=2 -> 5) + " " (1) = 10 -> "auth_token" is [10, 20)
        let raw = "    café auth_token 🚀\n"
        let snippet = ContentMatchSnippet.make(
            lineNumber: 42,
            rawLine: raw,
            utf8Start: 10,
            utf8End: 20
        )

        XCTAssertEqual(snippet.lineNumber, 42)
        XCTAssertEqual(snippet.lineText, "café auth_token 🚀")
        XCTAssertEqual(snippet.matchStart, 5) // "café " is 5 characters
        XCTAssertEqual(snippet.matchLength, 10)

        let startIdx = snippet.lineText.index(snippet.lineText.startIndex, offsetBy: snippet.matchStart)
        let endIdx = snippet.lineText.index(startIdx, offsetBy: snippet.matchLength)
        XCTAssertEqual(String(snippet.lineText[startIdx..<endIdx]), "auth_token")
    }

    func testSnippetWindowsLongMinifiedLineAroundMatch() {
        let prefix = String(repeating: "x", count: 400)
        let suffix = String(repeating: "y", count: 400)
        let raw = prefix + "NEEDLE_TOKEN" + suffix

        let snippet = ContentMatchSnippet.make(
            lineNumber: 1,
            rawLine: raw,
            utf8Start: 400,
            utf8End: 412,
            maxCharacters: 120
        )

        XCTAssertLessThanOrEqual(snippet.lineText.count, 122) // maxCharacters + leading/trailing ellipsis
        XCTAssertTrue(snippet.lineText.hasPrefix("…"))
        XCTAssertTrue(snippet.lineText.hasSuffix("…"))

        let startIdx = snippet.lineText.index(snippet.lineText.startIndex, offsetBy: snippet.matchStart)
        let endIdx = snippet.lineText.index(startIdx, offsetBy: snippet.matchLength)
        XCTAssertEqual(String(snippet.lineText[startIdx..<endIdx]), "NEEDLE_TOKEN")
    }

    // MARK: - RipgrepJSONParser

    func testRipgrepJSONParserParsesMatchAndIgnoresNonMatchEvents() {
        let beginLine = #"{"type":"begin","data":{"path":{"text":"/tmp/a.swift"}}}"#
        let summaryLine = #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":10}}}"#
        let matchLine = #"{"type":"match","data":{"path":{"text":"/tmp/a.swift"},"lines":{"text":"    let token = fetchAuthToken()\n"},"line_number":17,"submatches":[{"match":{"text":"AuthToken"},"start":21,"end":30}]}}"#

        XCTAssertNil(RipgrepJSONParser.parseLine(beginLine))
        XCTAssertNil(RipgrepJSONParser.parseLine(summaryLine))
        XCTAssertNil(RipgrepJSONParser.parseLine("not json at all"))

        let event = RipgrepJSONParser.parseLine(matchLine)
        XCTAssertEqual(event?.path, "/tmp/a.swift")
        XCTAssertEqual(event?.snippet.lineNumber, 17)
        XCTAssertEqual(event?.snippet.lineText, "let token = fetchAuthToken()")
        XCTAssertEqual(event?.snippet.matchStart, 17)
        XCTAssertEqual(event?.snippet.matchLength, 9)
    }

    func testRipgrepJSONParserDecodesBase64BytesPayload() {
        let pathB64 = Data("/tmp/raw.txt".utf8).base64EncodedString()
        let lineB64 = Data("hello world\n".utf8).base64EncodedString()
        let json = """
        {"type":"match","data":{"path":{"bytes":"\(pathB64)"},"lines":{"bytes":"\(lineB64)"},"line_number":3,"submatches":[{"start":6,"end":11}]}}
        """

        let event = RipgrepJSONParser.parseLine(json)
        XCTAssertEqual(event?.path, "/tmp/raw.txt")
        XCTAssertEqual(event?.snippet.lineNumber, 3)
        XCTAssertEqual(event?.snippet.lineText, "hello world")
        XCTAssertEqual(event?.snippet.matchStart, 6)
        XCTAssertEqual(event?.snippet.matchLength, 5)
    }

    // MARK: - ContentFileScanner

    func testContentFileScannerSkipsBinaryAndOversizedFilesAndCapsPerFileMatches() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("arbor-content-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Binary file containing NUL byte plus query string -> must be skipped.
        let binURL = dir.appendingPathComponent("blob.bin")
        var binData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        binData.append(Data("secret_key".utf8))
        try binData.write(to: binURL)

        // Text file with 6 matching lines -> capped at 3.
        let txtURL = dir.appendingPathComponent("notes.txt")
        let lines = (1...6).map { "line \($0): SECRET_KEY_\($0)" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: txtURL)

        XCTAssertTrue(ContentFileScanner.isLikelyBinary(binData))
        XCTAssertFalse(ContentFileScanner.isLikelyBinary(Data(lines.utf8)))

        XCTAssertEqual(
            ContentFileScanner.scanFile(at: binURL.path, query: "secret_key", maxFileSizeBytes: 1_000_000, maxMatches: 5),
            []
        )

        // Size limit smaller than file -> skipped.
        XCTAssertEqual(
            ContentFileScanner.scanFile(at: txtURL.path, query: "secret_key", maxFileSizeBytes: 10, maxMatches: 5),
            []
        )

        let hits = ContentFileScanner.scanFile(
            at: txtURL.path,
            query: "secret_key",
            maxFileSizeBytes: 1_000_000,
            maxMatches: 3
        )
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(hits[0].matchStart, 8)
        XCTAssertEqual(hits[0].matchLength, 10)
    }

    func testFallbackWalkAndScanDefeatsSymlinkCycleAndRespectsExclusions() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arbor-cwalk-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("src")
        let nm = root.appendingPathComponent("node_modules")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: nm, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("alpha needle beta\n".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data("deep NEEDLE here\n".utf8).write(to: sub.appendingPathComponent("child.swift"))
        try Data("ignored needle\n".utf8).write(to: nm.appendingPathComponent("lib.js"))
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: root)

        let found = LockedMap<String, [ContentMatchSnippet]>()
        let result = try await ContentFileScanner.walkAndScan(
            root: root,
            query: "needle",
            options: SearchOptions(resultLimit: 50, timeoutSeconds: 5.0),
            isGlobalRoot: false
        ) { path, snippets in
            found.set((path as NSString).lastPathComponent, snippets)
            return true
        }

        XCTAssertEqual(result.stopReason, .completed)
        let map = found.snapshot
        XCTAssertEqual(Set(map.keys), ["top.txt", "child.swift"])
        XCTAssertEqual(map["top.txt"]?.first?.lineNumber, 1)
        XCTAssertEqual(map["child.swift"]?.first?.lineNumber, 1)
    }

    // MARK: - SearchPreferencesStore Content Fields

    @MainActor
    func testSearchPreferencesStorePersistsContentSearchOptions() {
        let suiteName = "arbor.test.contentPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.maxContentFileSizeMB, SearchOptions.defaultMaxContentFileSizeMB)
        XCTAssertTrue(store.respectGitignoreInContent)
        XCTAssertEqual(store.maxMatchesPerFile, SearchOptions.defaultMaxMatchesPerFile)
        XCTAssertFalse(store.deepGlobalContentScan)

        store.maxContentFileSizeMB = 25
        store.respectGitignoreInContent = false
        store.maxMatchesPerFile = 10
        store.deepGlobalContentScan = true

        let reloaded = SearchPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.maxContentFileSizeMB, 25)
        XCTAssertFalse(reloaded.respectGitignoreInContent)
        XCTAssertEqual(reloaded.maxMatchesPerFile, 10)
        XCTAssertTrue(reloaded.deepGlobalContentScan)

        let opts = reloaded.makeOptions(showHiddenFiles: false, deepGlobalContentOverride: false)
        XCTAssertEqual(opts.maxContentFileSizeMB, 25)
        XCTAssertEqual(opts.maxContentFileSizeBytes, 25 * 1_024 * 1_024)
        XCTAssertFalse(opts.respectGitignoreInContent)
        XCTAssertEqual(opts.maxMatchesPerFile, 10)
        XCTAssertFalse(opts.deepGlobalContentScan)

        reloaded.resetDefaults()
        XCTAssertEqual(reloaded.maxContentFileSizeMB, SearchOptions.defaultMaxContentFileSizeMB)
        XCTAssertTrue(reloaded.respectGitignoreInContent)
        XCTAssertEqual(reloaded.maxMatchesPerFile, SearchOptions.defaultMaxMatchesPerFile)
        XCTAssertFalse(reloaded.deepGlobalContentScan)
    }

    func testRingMergerUpsertAccumulatesSnippetsWithoutDuplicatingFileSlots() {
        struct Hit: Equatable {
            let name: String
            var lines: [Int]
        }
        var merger = SearchRingMerger<Hit>(limit: 2)
        XCTAssertEqual(
            merger.upsert(
                canonicalPath: "/a.swift",
                ring: .currentFolderSubtree,
                create: { Hit(name: "a.swift", lines: [10]) },
                update: { _ in false }
            ),
            .inserted
        )
        XCTAssertEqual(
            merger.upsert(
                canonicalPath: "/a.swift",
                ring: .currentFolderSubtree,
                create: { Hit(name: "a.swift", lines: [20]) },
                update: { $0.lines.append(20); return true }
            ),
            .duplicate
        )
        XCTAssertEqual(merger.totalCount, 1)
        XCTAssertEqual(merger.orderedItems, [Hit(name: "a.swift", lines: [10, 20])])
    }
}
