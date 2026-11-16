import XCTest
@testable import ArborPure

final class MarkdownRendererTests: XCTestCase {
    private var root: URL!
    private var doc: URL!
    private var images: URL!
    private var parentImage: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-md-tests-\(UUID().uuidString)", isDirectory: true)
        doc = root.appendingPathComponent("README.md")
        images = root.appendingPathComponent("images", isDirectory: true)
        parentImage = root.deletingLastPathComponent()
            .appendingPathComponent("escape-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: doc)
        try Data("x".utf8).write(to: images.appendingPathComponent("pic.png"))
        try Data("x".utf8).write(to: parentImage)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
        addTeardownBlock { try? FileManager.default.removeItem(at: self.parentImage) }
    }

    private func render(_ markdown: String) -> String {
        MarkdownHTMLRenderer.html(
            markdown: markdown,
            title: doc.lastPathComponent,
            context: MarkdownHTMLRenderer.Context(documentURL: doc, docID: "test")
        )
    }

    func testHeadingsAndEmphasis() {
        let html = render("# Title\n\nSome **bold**, *italic*, `code`.")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    func testLinks() {
        let html = render("[link](https://example.com)")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
    }

    func testBalancedParenthesesInLinkTarget() {
        let html = render("[parens](https://example.com/a_(b))")
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a_(b)\">parens</a>"))
    }

    func testTables() {
        let html = render("| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<td>1</td>"))
        XCTAssertTrue(html.contains("<th>a</th>"))
    }

    func testFencedCodeEscapesContent() {
        let html = render("```swift\nlet x = 1 < 2\n```")
        XCTAssertTrue(html.contains("language-swift"))
        XCTAssertTrue(html.contains("let x = 1 &lt; 2"))
        XCTAssertFalse(html.contains("<pre><code class=\"language-swift\">let x = 1 <"))
    }

    func testLists() {
        let html = render("- one\n- two\n  - nested")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>two"))
        XCTAssertTrue(html.contains("nested"))
    }

    func testRawHtmlIsEscaped() {
        let html = render("<script>alert(1)</script>")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>alert"))
    }

    func testJavascriptUrlsAreRejected() {
        let html = render("[click](javascript:alert(1))")
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("href="))
        XCTAssertTrue(html.contains("click"))
    }

    func testLocalImageResolvesThroughAssetScheme() {
        let html = render("![shot](images/pic.png)")
        XCTAssertTrue(html.contains("src=\"\(MarkdownHTMLRenderer.assetScheme)://test/"))
        XCTAssertFalse(html.contains("src=\"images/pic.png\""))
    }

    func testParentRelativeImageResolves() {
        let html = render("![up](../\(parentImage.lastPathComponent))")
        XCTAssertTrue(html.contains("alt=\"up\""))
        XCTAssertTrue(html.contains(MarkdownHTMLRenderer.assetScheme))
    }

    func testMissingImageFallsBackToAltText() {
        let html = render("![gone](images/nope.png)")
        XCTAssertTrue(html.contains("broken-image"))
        XCTAssertTrue(html.contains("gone"))
    }

    func testRemoteImagePassesThrough() {
        let html = render("![remote](https://example.com/x.png)")
        XCTAssertTrue(html.contains("src=\"https://example.com/x.png\""))
    }

    func testMermaidFenceBecomesContainer() {
        let html = render("```mermaid\nflowchart LR\n  A --> B\n```")
        XCTAssertTrue(html.contains("<div class=\"mermaid\">"))
        XCTAssertTrue(html.contains("flowchart LR"))
        XCTAssertTrue(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("<pre><code class=\"language-mermaid\""))
    }

    func testMermaidSourceIsEscaped() {
        let html = render("```mermaid\nA[\"<b>\"]\n```")
        XCTAssertTrue(html.contains("&lt;b&gt;"))
    }

    func testNoMermaidRuntimeWithoutDiagram() {
        let html = render("# Just text\n\nNo diagrams here.")
        XCTAssertFalse(html.contains("mermaid.min.js"))
    }
}
