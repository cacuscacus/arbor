import XCTest
@testable import ArborPure

final class GoToFolderResolverTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var file: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-g2f-tests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Alpha Folder", isDirectory: true)
        file = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var resolver: GoToFolderResolver {
        GoToFolderResolver(currentDirectory: root)
    }

    func testBlankInputDoesNotExpand() {
        XCTAssertNil(resolver.expand("   "))
        XCTAssertNil(resolver.expand(""))
    }

    func testRelativeNameResolvesAgainstCurrentFolder() {
        XCTAssertEqual(resolver.expand("Alpha Folder")?.path, folder.path)
        XCTAssertEqual(resolver.expand("note.txt")?.path, file.path)
    }

    func testAbsolutePathExpands() {
        XCTAssertEqual(resolver.expand(folder.path)?.path, folder.path)
    }

    func testTildeExpands() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded = resolver.expand("~")
        XCTAssertEqual(expanded?.path, home.path)
    }

    func testResolveExistingFolder() throws {
        let resolved = try resolver.resolve("Alpha Folder")
        XCTAssertEqual(resolved.path, folder.path)
    }

    func testResolveRejectsMissingPath() {
        XCTAssertThrowsError(try resolver.resolve("nope")) { error in
            guard case GoToFolderResolver.Failure.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testResolveRejectsFiles() {
        XCTAssertThrowsError(try resolver.resolve("note.txt")) { error in
            guard case GoToFolderResolver.Failure.notADirectory = error else {
                return XCTFail("expected notADirectory, got \(error)")
            }
        }
    }

    func testResolveBlankThrowsEmpty() {
        XCTAssertThrowsError(try resolver.resolve("  ")) { error in
            guard case GoToFolderResolver.Failure.empty = error else {
                return XCTFail("expected empty, got \(error)")
            }
        }
    }

    func testRevealFileOpensParentAndSelectsIt() throws {
        let reveal = try resolver.resolveReveal("note.txt")
        XCTAssertEqual(reveal.folder.path, root.path)
        XCTAssertEqual(reveal.selection?.lastPathComponent, "note.txt")
    }

    func testRevealFolderSelectsNothing() throws {
        let reveal = try resolver.resolveReveal("Alpha Folder")
        XCTAssertEqual(reveal.folder.path, folder.path)
        XCTAssertNil(reveal.selection)
    }

    func testCompletionResolvesUniquePrefix() {
        let completed = resolver.completion(for: root.path + "/Al")
        XCTAssertEqual(completed, folder.path + "/")
    }

    func testCompletionResolvesRelativePrefix() {
        // "Al" from the current folder should complete to the folder itself.
        XCTAssertEqual(resolver.completion(for: "Al"), folder.path + "/")
    }

    func testNoCompletionForExactMatch() {
        XCTAssertNil(resolver.completion(for: folder.path))
    }

    func testNoCompletionForDirectoryItself() {
        XCTAssertNil(resolver.completion(for: root.path))
    }

    func testNoCompletionWhenNothingMatches() {
        XCTAssertNil(resolver.completion(for: root.path + "/zzzz"))
    }
}
