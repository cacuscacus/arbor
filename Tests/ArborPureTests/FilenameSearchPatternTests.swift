import XCTest
@testable import ArborPure

final class FilenameSearchPatternTests: XCTestCase {
    func testPlainTextIsSubstring() {
        let pattern = FilenameSearchPattern("report")
        XCTAssertFalse(pattern.isGlob)
        XCTAssertEqual(pattern.literalText, "report")
        XCTAssertFalse(pattern.isEmpty)
    }

    func testWhitespaceIsTrimmed() {
        let pattern = FilenameSearchPattern("  report  ")
        XCTAssertEqual(pattern.literalText, "report")
    }

    func testStarMakesGlob() {
        XCTAssertTrue(FilenameSearchPattern("*.png").isGlob)
        XCTAssertTrue(FilenameSearchPattern("report-??.txt").isGlob)
    }

    func testBracketNameIsTreatedAsGlob() {
        // `corchetes[1].txt` is a glob character class, not a literal —
        // this is exactly why the literal fallback exists.
        let pattern = FilenameSearchPattern("corchetes[1].txt")
        XCTAssertTrue(pattern.isGlob)
    }

    func testLiteralFallbackKeepsText() {
        let pattern = FilenameSearchPattern("corchetes[1].txt")
        let fallback = pattern.literalFallback
        XCTAssertFalse(fallback.isGlob)
        XCTAssertEqual(fallback.literalText, "corchetes[1].txt")
    }

    func testSubstringLiteralFallbackIsIdentity() {
        let pattern = FilenameSearchPattern("note")
        XCTAssertEqual(pattern.literalFallback, pattern)
    }

    func testEmptyPattern() {
        XCTAssertTrue(FilenameSearchPattern("").isEmpty)
        XCTAssertTrue(FilenameSearchPattern("   ").isEmpty)
    }

    func testMetacharactersInsideClassDoNotMakeGlob() {
        // `[?]` is a character class containing `?` — no unescaped wildcard.
        let pattern = FilenameSearchPattern("report[?].txt")
        XCTAssertTrue(pattern.isGlob) // opens a class, so still a glob
        let classOnly = FilenameSearchPattern("photo[]")
        XCTAssertTrue(classOnly.isGlob)
    }
}
