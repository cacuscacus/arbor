import XCTest
@testable import ArborPure

final class SearchQueryParserTests: XCTestCase {

    func testParsesExtensionsAndNegationAndCombinesPositiveAsOR() {
        let parsed = SearchQueryParser.parse("auth ext:swift ext:.ts,tsx -ext:lock")
        XCTAssertEqual(parsed.textQuery, "auth")
        XCTAssertEqual(parsed.filters.count, 3)
        XCTAssertFalse(parsed.isFilterOnly)

        XCTAssertTrue(parsed.matches(name: "Auth.swift", isDirectory: false, isPackage: false, size: 100, modified: nil))
        XCTAssertTrue(parsed.matches(name: "login.tsx", isDirectory: false, isPackage: false, size: 100, modified: nil))
        XCTAssertFalse(parsed.matches(name: "Cargo.lock", isDirectory: false, isPackage: false, size: 100, modified: nil))
        XCTAssertFalse(parsed.matches(name: "README.md", isDirectory: false, isPackage: false, size: 100, modified: nil))
        // Directories do not match extension filters.
        XCTAssertFalse(parsed.matches(name: "swift", isDirectory: true, isPackage: false, size: 0, modified: nil))
    }

    func testParsesKindsWithBilingualAliasesAndNegation() {
        let imagesAndPDF = SearchQueryParser.parse("kind:imagen,pdf")
        XCTAssertTrue(imagesAndPDF.isFilterOnly)
        XCTAssertTrue(imagesAndPDF.matches(name: "photo.HEIC", isDirectory: false, isPackage: false, size: 500, modified: nil))
        XCTAssertTrue(imagesAndPDF.matches(name: "invoice.pdf", isDirectory: false, isPackage: false, size: 500, modified: nil))
        XCTAssertFalse(imagesAndPDF.matches(name: "main.swift", isDirectory: false, isPackage: false, size: 500, modified: nil))

        let foldersOnly = SearchQueryParser.parse("kind:carpeta")
        XCTAssertTrue(foldersOnly.matches(name: "src", isDirectory: true, isPackage: false, size: 0, modified: nil))
        XCTAssertFalse(foldersOnly.matches(name: "Arbor.app", isDirectory: true, isPackage: true, size: 0, modified: nil))

        let noFolders = SearchQueryParser.parse("report -kind:folder")
        XCTAssertEqual(noFolders.textQuery, "report")
        XCTAssertFalse(noFolders.matches(name: "reports", isDirectory: true, isPackage: false, size: 0, modified: nil))
        XCTAssertTrue(noFolders.matches(name: "report.md", isDirectory: false, isPackage: false, size: 42, modified: nil))
    }

    func testParsesSizeComparisonsUnitsAndRanges() {
        let large = SearchQueryParser.parse("size>1.5mb")
        XCTAssertTrue(large.isFilterOnly)
        XCTAssertTrue(large.matches(name: "big.bin", isDirectory: false, isPackage: false, size: 2_000_000, modified: nil))
        XCTAssertFalse(large.matches(name: "small.bin", isDirectory: false, isPackage: false, size: 1_500_000, modified: nil))
        // Plain directories are skipped by size filters.
        XCTAssertFalse(large.matches(name: "dir", isDirectory: true, isPackage: false, size: 9_999_999, modified: nil))

        let ranged = SearchQueryParser.parse("size:100kb..5mb")
        XCTAssertTrue(ranged.matches(name: "mid.png", isDirectory: false, isPackage: false, size: 500_000, modified: nil))
        XCTAssertFalse(ranged.matches(name: "tiny.png", isDirectory: false, isPackage: false, size: 50_000, modified: nil))
        XCTAssertFalse(ranged.matches(name: "huge.png", isDirectory: false, isPackage: false, size: 6_000_000, modified: nil))

        let binary = SearchQueryParser.parse("size>=1mib")
        XCTAssertTrue(binary.matches(name: "a", isDirectory: false, isPackage: false, size: 1_048_576, modified: nil))
        XCTAssertFalse(binary.matches(name: "b", isDirectory: false, isPackage: false, size: 1_000_000, modified: nil))
    }

    func testParsesModifiedRelativeKeywordsDurationsAndISODates() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15, minute: 0))!
        let twoHoursAgo = now.addingTimeInterval(-2 * 3_600)
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 86_400)

        let today = SearchQueryParser.parse("modified:today")
        XCTAssertTrue(today.matches(name: "a.txt", isDirectory: false, isPackage: false, size: 1, modified: twoHoursAgo, now: now))
        XCTAssertFalse(today.matches(name: "b.txt", isDirectory: false, isPackage: false, size: 1, modified: threeDaysAgo, now: now))

        let lastWeek = SearchQueryParser.parse("mod:7d")
        XCTAssertTrue(lastWeek.matches(name: "a.txt", isDirectory: false, isPackage: false, size: 1, modified: threeDaysAgo, now: now))
        XCTAssertFalse(lastWeek.matches(name: "b.txt", isDirectory: false, isPackage: false, size: 1, modified: sixtyDaysAgo, now: now))

        let olderThan30d = SearchQueryParser.parse("modified>30d")
        XCTAssertTrue(olderThan30d.matches(name: "old.log", isDirectory: false, isPackage: false, size: 1, modified: sixtyDaysAgo, now: now))
        XCTAssertFalse(olderThan30d.matches(name: "new.log", isDirectory: false, isPackage: false, size: 1, modified: threeDaysAgo, now: now))

        let inNovember = SearchQueryParser.parse("modified:2026-11")
        XCTAssertTrue(inNovember.matches(name: "nov.md", isDirectory: false, isPackage: false, size: 1, modified: threeDaysAgo, now: now))
        XCTAssertFalse(inNovember.matches(name: "sep.md", isDirectory: false, isPackage: false, size: 1, modified: sixtyDaysAgo, now: now))

        let afterOct = SearchQueryParser.parse("modified>2026-10-01")
        XCTAssertTrue(afterOct.matches(name: "nov.md", isDirectory: false, isPackage: false, size: 1, modified: threeDaysAgo, now: now))
        XCTAssertFalse(afterOct.matches(name: "sep.md", isDirectory: false, isPackage: false, size: 1, modified: sixtyDaysAgo, now: now))
    }

    func testQuotedTokensStayLiteralAndIncompleteTokensAreForgiving() {
        let quoted = SearchQueryParser.parse("\"size>10mb\" ext:swift")
        XCTAssertEqual(quoted.textQuery, "size>10mb")
        XCTAssertEqual(quoted.filters.count, 1)

        // While user is mid-typing `ext:` or `size>` or `foo:bar`, parser never crashes.
        let typing = SearchQueryParser.parse("notes ext: size> kind:notakind foo:bar")
        XCTAssertTrue(typing.filters.isEmpty)
        XCTAssertEqual(typing.textQuery, "notes ext: size> kind:notakind foo:bar")
    }

    func testChipRemovalAndInsertionEditQueryCleanly() {
        let parsed = SearchQueryParser.parse("invoice ext:pdf size>1mb modified:7d")
        XCTAssertEqual(parsed.filters.count, 3)

        let withoutSize = parsed.removingFilter(at: 1)
        XCTAssertEqual(withoutSize, "invoice ext:pdf modified:7d")

        let appended = SearchQueryParser.parse(withoutSize).appendingFilter("kind:document")
        XCTAssertEqual(appended, "invoice ext:pdf modified:7d kind:document")

        // Appending an already-present token is a no-op.
        let deduped = SearchQueryParser.parse(appended).appendingFilter("ext:pdf")
        XCTAssertEqual(deduped, appended)
    }

    func testNativeBackendPushdownArgumentsAreGenerated() {
        let parsed = SearchQueryParser.parse("config ext:swift,rs -ext:lock size>50kb modified:7d")

        let fdArgs = parsed.fdArguments()
        XCTAssertTrue(fdArgs.contains("--extension"))
        XCTAssertTrue(fdArgs.contains("swift"))
        XCTAssertTrue(fdArgs.contains("rs"))
        XCTAssertTrue(fdArgs.contains("--size"))
        XCTAssertTrue(fdArgs.contains("+50000b"))
        XCTAssertTrue(fdArgs.contains("--changed-within"))

        let rgArgs = parsed.ripgrepGlobArguments()
        XCTAssertEqual(rgArgs, ["--glob", "*.rs", "--glob", "*.swift", "--glob", "!*.lock"])

        let spotlightClauses = parsed.spotlightPredicateClauses()
        XCTAssertTrue(spotlightClauses.contains(where: { $0.contains("kMDItemFSSize > 50000") }))
        XCTAssertTrue(spotlightClauses.contains(where: { $0.contains("kMDItemFSContentChangeDate >= $time.now(-604800)") }))
        XCTAssertTrue(spotlightClauses.contains(where: { $0.contains("*.swift") && $0.contains("*.rs") }))
    }
}
