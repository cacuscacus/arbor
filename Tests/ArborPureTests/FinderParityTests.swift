import XCTest
@testable import ArborPure

final class FinderParityTests: XCTestCase {

    // MARK: - ArchiveNameResolver

    func testArchiveNameSingleAndMultiAndCollisionAvoidance() {
        let dir = URL(fileURLWithPath: "/tmp/docs")
        let single = ArchiveNameResolver.uniqueArchiveURL(
            for: [URL(fileURLWithPath: "/tmp/docs/report.pdf")],
            in: dir,
            fileExists: { _ in false }
        )
        XCTAssertEqual(single.lastPathComponent, "report.zip")

        let existing: Set<String> = ["/tmp/docs/Archive.zip", "/tmp/docs/Archive 2.zip"]
        let multi = ArchiveNameResolver.uniqueArchiveURL(
            for: [
                URL(fileURLWithPath: "/tmp/docs/a.txt"),
                URL(fileURLWithPath: "/tmp/docs/b.txt"),
            ],
            in: dir,
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(multi.lastPathComponent, "Archive 3.zip")
    }

    func testExtractionNameAvoidsClobberingExistingFolder() {
        let dir = URL(fileURLWithPath: "/tmp/downloads")
        let existing: Set<String> = ["/tmp/downloads/backup"]
        let dest = ArchiveNameResolver.uniqueExtractionURL(
            for: URL(fileURLWithPath: "/tmp/downloads/backup.zip"),
            in: dir,
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(dest.lastPathComponent, "backup 2")
        XCTAssertTrue(ArchiveNameResolver.isSupportedArchive(URL(fileURLWithPath: "/tmp/a.ZIP")))
        XCTAssertFalse(ArchiveNameResolver.isSupportedArchive(URL(fileURLWithPath: "/tmp/a.tar.gz")))
    }

    // MARK: - StatusBarSummary

    func testStatusBarSummaryFormatsCountsSelectionAndFreeSpace() {
        let empty = StatusBarSummary.format(itemCount: 1, selectedCount: 0, selectedBytes: 0, availableBytes: nil)
        XCTAssertEqual(empty, "1 item")

        let selectedFiles = StatusBarSummary.format(
            itemCount: 42,
            selectedCount: 3,
            selectedBytes: 2_500_000,
            availableBytes: 100_000_000_000
        )
        XCTAssertTrue(selectedFiles.contains("42 items"))
        XCTAssertTrue(selectedFiles.contains("3 selected"))
        XCTAssertTrue(selectedFiles.contains("available"))

        let selectedFolder = StatusBarSummary.format(
            itemCount: 10,
            selectedCount: 1,
            selectedBytes: 0,
            availableBytes: nil
        )
        XCTAssertEqual(selectedFolder, "10 items · 1 selected")
    }

    // MARK: - FileClipboardState

    func testClipboardSupportsCopyRepeatablePasteCutOneShotAndFinderOverride() {
        var state = FileClipboardState()

        // 1. Copy in Arbor -> Paste is non-destructive copy (keeps clipboard).
        state.record(paths: ["/a.txt"], intent: .copy, pasteboardChangeCount: 10)
        let copyPaste = state.resolve(externalPasteboardPaths: ["/a.txt"], currentPasteboardChangeCount: 10, forceMove: false)
        XCTAssertEqual(copyPaste, FileClipboardResolution(paths: ["/a.txt"], isMove: false, clearsInternalAfterPaste: false))

        // 2. Cmd+Opt+V (forceMove) on copied items -> Move + clears clipboard.
        let optMove = state.resolve(externalPasteboardPaths: ["/a.txt"], currentPasteboardChangeCount: 10, forceMove: true)
        XCTAssertEqual(optMove, FileClipboardResolution(paths: ["/a.txt"], isMove: true, clearsInternalAfterPaste: true))

        // 3. Cut in Arbor -> Paste is Move + clears clipboard.
        state.record(paths: ["/b.txt"], intent: .cut, pasteboardChangeCount: 11)
        let cutPaste = state.resolve(externalPasteboardPaths: [], currentPasteboardChangeCount: 11, forceMove: false)
        XCTAssertEqual(cutPaste, FileClipboardResolution(paths: ["/b.txt"], isMove: true, clearsInternalAfterPaste: true))

        // 4. External app (Finder) copies a newer file -> changeCount advances -> Finder wins!
        let finderPaste = state.resolve(externalPasteboardPaths: ["/from-finder.png"], currentPasteboardChangeCount: 12, forceMove: false)
        XCTAssertEqual(finderPaste, FileClipboardResolution(paths: ["/from-finder.png"], isMove: false, clearsInternalAfterPaste: false))
    }

    // MARK: - TypeAheadMatcher

    func testTypeAheadPrefixTimeoutAndDiacriticMatching() {
        var matcher = TypeAheadMatcher(timeout: 0.85)
        let candidates = ["Alpha", "App", "Café.pdf", "README.md", "Resources"]
        let t0 = Date(timeIntervalSince1970: 1_000)

        // Multi-char prefix refines match ("r" -> README.md, "e" -> README.md, "s" -> Resources).
        XCTAssertEqual(matcher.match(typing: "r", at: t0, candidates: candidates, currentIndex: nil), 3)
        XCTAssertEqual(matcher.match(typing: "e", at: t0.addingTimeInterval(0.1), candidates: candidates, currentIndex: 3), 3)
        XCTAssertEqual(matcher.match(typing: "s", at: t0.addingTimeInterval(0.2), candidates: candidates, currentIndex: 3), 4)

        // After timeout, buffer resets and matches diacritics case-insensitively.
        let t1 = t0.addingTimeInterval(1.2)
        XCTAssertEqual(matcher.match(typing: "c", at: t1, candidates: candidates, currentIndex: 4), 2)
        XCTAssertEqual(matcher.match(typing: "a", at: t1.addingTimeInterval(0.1), candidates: candidates, currentIndex: 2), 2)
        XCTAssertEqual(matcher.match(typing: "f", at: t1.addingTimeInterval(0.2), candidates: candidates, currentIndex: 2), 2)
        XCTAssertEqual(matcher.match(typing: "e", at: t1.addingTimeInterval(0.3), candidates: candidates, currentIndex: 2), 2)
    }

    func testTypeAheadRepeatedSingleKeyCyclesThroughMatches() {
        var matcher = TypeAheadMatcher(timeout: 0.85)
        let candidates = ["Alpha", "App", "Assets", "Beta"]
        let t0 = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(matcher.match(typing: "a", at: t0, candidates: candidates, currentIndex: nil), 0)
        XCTAssertEqual(matcher.match(typing: "a", at: t0.addingTimeInterval(0.2), candidates: candidates, currentIndex: 0), 1)
        XCTAssertEqual(matcher.match(typing: "a", at: t0.addingTimeInterval(0.4), candidates: candidates, currentIndex: 1), 2)
        XCTAssertEqual(matcher.match(typing: "a", at: t0.addingTimeInterval(0.6), candidates: candidates, currentIndex: 2), 0)

        XCTAssertNil(TypeAheadMatcher.printableInput(from: " "))
        XCTAssertNil(TypeAheadMatcher.printableInput(from: "/"))
        XCTAssertNil(TypeAheadMatcher.printableInput(from: "\u{F700}"))
        XCTAssertEqual(TypeAheadMatcher.printableInput(from: "z"), "z")
    }

    // MARK: - UniqueItemNameResolver

    func testUniqueItemNameResolverHandlesCaseInsensitiveFolderAndFileCollisions() {
        let existing: Set<String> = [
            "Untitled Folder",
            "untitled folder 2",
            "untitled.txt",
            "UNTITLED 2.TXT",
            "Makefile",
        ]
        XCTAssertEqual(
            UniqueItemNameResolver.uniqueName(preferred: "untitled folder", existingNames: existing, isDirectory: true),
            "untitled folder 3"
        )
        XCTAssertEqual(
            UniqueItemNameResolver.uniqueName(preferred: "untitled.txt", existingNames: existing, isDirectory: false),
            "untitled 3.txt"
        )
        XCTAssertEqual(
            UniqueItemNameResolver.uniqueName(preferred: "Makefile", existingNames: existing, isDirectory: false),
            "Makefile 2"
        )
        XCTAssertEqual(
            UniqueItemNameResolver.uniqueName(preferred: "fresh.swift", existingNames: existing, isDirectory: false),
            "fresh.swift"
        )
    }

    // MARK: - FolderSizeCalculator

    func testFolderSizeCalculatorDeduplicatesHardlinksAndDefeatsSymlinkLoop() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arbor-folder-size-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.bin")
        let fileB = nested.appendingPathComponent("b.bin")
        let hardlinkA = nested.appendingPathComponent("a-hardlink.bin")
        let loopLink = nested.appendingPathComponent("loop-to-root")

        let payload = Data(repeating: 0xAB, count: 65_536) // 64 KB
        try payload.write(to: fileA)
        try payload.write(to: fileB)
        try fm.linkItem(at: fileA, to: hardlinkA)
        try fm.createSymbolicLink(at: loopLink, withDestinationURL: root)

        let snapshot = await FolderSizeCalculator.calculate(url: root)
        XCTAssertTrue(snapshot.isComplete)
        // Must count 2 unique regular files (~128 KB allocated), NOT 3 (~192 KB) or infinite loop.
        XCTAssertGreaterThanOrEqual(snapshot.totalBytes, 128 * 1024)
        XCTAssertLessThan(snapshot.totalBytes, 180 * 1024)
        XCTAssertEqual(snapshot.itemCount, 5) // nested, a.bin, b.bin, a-hardlink.bin, loop-to-root
        XCTAssertTrue(snapshot.formattedSummary.contains("5 items"))
    }

    // MARK: - TransferProgressFormatter

    func testTransferProgressFormatterRulesAndSubtitles() {
        XCTAssertFalse(TransferProgressFormatter.shouldRevealImmediately(totalItems: 1, totalBytes: 1_000_000))
        XCTAssertTrue(TransferProgressFormatter.shouldRevealImmediately(totalItems: 6, totalBytes: nil))
        XCTAssertTrue(TransferProgressFormatter.shouldRevealImmediately(totalItems: 1, totalBytes: 25 * 1024 * 1024))

        XCTAssertNil(
            TransferProgressFormatter.fractionCompleted(
                completedItems: 0,
                totalItems: 1,
                completedBytes: nil,
                totalBytes: nil
            )
        )
        XCTAssertEqual(
            TransferProgressFormatter.fractionCompleted(
                completedItems: 2,
                totalItems: 4,
                completedBytes: nil,
                totalBytes: nil
            ),
            0.5
        )
        XCTAssertEqual(
            TransferProgressFormatter.fractionCompleted(
                completedItems: 0,
                totalItems: 1,
                completedBytes: 250,
                totalBytes: 1_000
            ),
            0.25
        )

        let cancelling = TransferProgressFormatter.subtitle(
            completedItems: 1,
            totalItems: 5,
            currentItemName: "video.mov",
            completedBytes: nil,
            totalBytes: nil,
            isCancelling: true
        )
        XCTAssertEqual(cancelling, "Cancelling…")

        let running = TransferProgressFormatter.subtitle(
            completedItems: 1,
            totalItems: 5,
            currentItemName: "video.mov",
            completedBytes: nil,
            totalBytes: nil,
            isCancelling: false
        )
        XCTAssertEqual(running, "2 of 5 · video.mov")
    }
}
