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
}
