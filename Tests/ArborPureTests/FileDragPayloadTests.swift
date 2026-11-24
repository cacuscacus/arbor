import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ArborPure

/// Regression tests for the drag payload handed to other apps (Finder,
/// browsers, Google Drive). Two real bugs motivated them:
///
/// 1. Multi-selection drags delivered the same file over and over because one
///    `NSItemProvider` had every URL registered on it, and `NSItemProvider`
///    keeps a single object per type.
/// 2. Dropped files arrived without a name (browser-invented generic names)
///    because `suggestedName` was nil and the provider exposed the file's
///    contents, which made WebKit build a nameless `File` from the data.
final class FileDragPayloadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-drag-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for name in ["alpha.txt", "beta.md", "gamma.json"] {
            try Data("payload".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Single file

    func testProviderCarriesFileName() {
        let url = directory.appendingPathComponent("alpha.txt")
        let provider = FileDragPayload.provider(for: url)
        XCTAssertEqual(provider.suggestedName, "alpha.txt")
    }

    func testProviderRegistersFileURL() {
        let provider = FileDragPayload.provider(
            for: directory.appendingPathComponent("alpha.txt")
        )
        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
            "drop targets need public.file-url; got \(provider.registeredTypeIdentifiers)"
        )
    }

    /// Content representations make some drop targets lose the name.
    func testProviderDoesNotOfferFileContents() {
        let provider = FileDragPayload.provider(
            for: directory.appendingPathComponent("alpha.txt")
        )
        XCTAssertFalse(
            provider.registeredTypeIdentifiers.contains(UTType.plainText.identifier),
            "offering file contents breaks names in WebKit drops"
        )
    }

    func testProviderLoadsTheOriginalURL() throws {
        let url = directory.appendingPathComponent("alpha.txt")
        let loaded = try loadURL(from: FileDragPayload.provider(for: url))
        XCTAssertEqual(loaded?.standardizedFileURL, url.standardizedFileURL)
    }

    // MARK: - Multi file (the "every item is the same file" regression)

    func testProvidersForSelectionAreOnePerFile() {
        let urls = ["alpha.txt", "beta.md", "gamma.json"].map(directory.appendingPathComponent)
        let providers = FileDragPayload.providers(for: urls)
        XCTAssertEqual(providers.count, urls.count)
        XCTAssertEqual(providers.map(\.suggestedName), urls.map(\.lastPathComponent))
    }

    func testEachProviderLoadsItsOwnFile() throws {
        let urls = ["alpha.txt", "beta.md", "gamma.json"].map(directory.appendingPathComponent)
        let loaded = try FileDragPayload.providers(for: urls).map { try loadURL(from: $0) }
        XCTAssertEqual(
            loaded.map { $0?.standardizedFileURL },
            urls.map { $0.standardizedFileURL }
        )
    }

    func testEmptySelectionProducesNoProviders() {
        XCTAssertTrue(FileDragPayload.providers(for: []).isEmpty)
    }

    // MARK: - AppKit dragging session (icon view)

    func testDraggingItemsAreOnePerFile() {
        let urls = ["alpha.txt", "beta.md"].map(directory.appendingPathComponent)
        let items = FileDragPayload.draggingItems(
            for: urls,
            frame: NSRect(x: 0, y: 0, width: 32, height: 32),
            contents: nil
        )
        XCTAssertEqual(items.count, urls.count)
    }

    func testPasteboardItemCarriesURLAndNameList() throws {
        let url = directory.appendingPathComponent("beta.md")
        let pasteboard = NSPasteboard(name: .init("arbor-drag-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([FileDragPayload.pasteboardItem(for: url)]))
        XCTAssertEqual(pasteboard.string(forType: .fileURL), url.absoluteString)
        let names = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String]
        XCTAssertEqual(names, [url.path])
    }

    // MARK: - Helpers

    private func loadURL(from provider: NSItemProvider) throws -> URL? {
        let expectation = expectation(description: "load file URL")
        var result: URL?
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            result = object as? URL
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return result
    }
}
