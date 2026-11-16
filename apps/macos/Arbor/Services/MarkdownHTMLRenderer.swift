import Foundation

/// Renders GitHub-flavored Markdown to a self-contained HTML document.
///
/// Scope is deliberately “what people put in a README”: headings, paragraphs,
/// lists (nested), fenced code, blockquotes, tables, rules, links, images,
/// emphasis, inline code and strikethrough.
///
/// Safety: the Markdown source is HTML-escaped before inline parsing, so raw
/// `<script>` is shown as text. URLs are allow-listed (http, https, mailto,
/// `data:image/*`, and local files that live under the document’s folder).
nonisolated enum MarkdownHTMLRenderer {
    /// Scheme served by `DocumentAssetSchemeHandler` (local images + bundled JS).
    static let assetScheme = "arbor-md"

    /// `docID` isolates cached asset URLs between documents.
    struct Context {
        var documentURL: URL?
        var docID: String

        var documentDirectory: URL? {
            documentURL?.deletingLastPathComponent()
        }

        /// Absolute filesystem path, without the leading slash, so WebKit
        /// parses it as URL path (``arbor-md://docID/Users/me/pic.png``).
        func assetURL(forAbsolutePath path: String) -> String {
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
            return "\(assetScheme)://\(docID)/\(encoded)"
        }
    }

    static func html(markdown: String, title: String, context: Context) -> String {
        var parser = BlockParser(markdown: markdown, context: context)
        let body = parser.parse()
        let needsMermaid = body.contains("class=\"mermaid\"")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        \(needsMermaid ? mermaidScripts : "")
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --fg: #1d1d1f;
      --bg: #ffffff;
      --muted: #6e6e73;
      --border: rgba(0, 0, 0, 0.12);
      --code-bg: rgba(120, 120, 128, 0.12);
      --quote-bar: rgba(120, 120, 128, 0.35);
      --link: #0066cc;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #f5f5f7;
        --bg: #1e1e1e;
        --muted: #98989d;
        --border: rgba(255, 255, 255, 0.16);
        --code-bg: rgba(255, 255, 255, 0.10);
        --quote-bar: rgba(255, 255, 255, 0.28);
        --link: #4da3ff;
      }
    }
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      padding: 0;
      background: var(--bg);
      color: var(--fg);
    }
    body {
      font: 15px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
    }
    .markdown-body {
      max-width: 820px;
      margin: 0 auto;
      padding: 32px 40px 72px;
      word-wrap: break-word;
    }
    h1, h2, h3, h4, h5, h6 {
      line-height: 1.25;
      margin: 1.8em 0 0.6em;
      font-weight: 650;
      letter-spacing: -0.01em;
    }
    h1 { font-size: 2em; margin-top: 0.4em; }
    h2 { font-size: 1.5em; padding-bottom: 0.25em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.05em; }
    h5, h6 { font-size: 0.95em; color: var(--muted); }
    p { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 650; }
    del { color: var(--muted); }
    hr {
      border: 0;
      border-top: 1px solid var(--border);
      margin: 2em 0;
    }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
    li { margin: 0.25em 0; }
    li > ul, li > ol { margin: 0.25em 0 0.25em; }
    blockquote {
      margin: 0 0 1em;
      padding: 0.1em 1em;
      border-left: 4px solid var(--quote-bar);
      color: var(--muted);
    }
    blockquote > :last-child { margin-bottom: 0; }
    code {
      font: 0.88em/1.5 ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
      background: var(--code-bg);
      padding: 0.15em 0.38em;
      border-radius: 5px;
    }
    pre {
      background: var(--code-bg);
      padding: 14px 16px;
      border-radius: 10px;
      overflow-x: auto;
      margin: 0 0 1em;
    }
    pre code {
      background: none;
      padding: 0;
      font-size: 0.86em;
      line-height: 1.55;
      white-space: pre;
    }
    img {
      max-width: 100%;
      height: auto;
      border-radius: 8px;
      display: block;
      margin: 1em auto;
    }
    img.inline {
      display: inline;
      margin: 0 0.15em;
      vertical-align: -0.2em;
    }
    table {
      border-collapse: collapse;
      margin: 0 0 1em;
      display: block;
      overflow-x: auto;
      max-width: 100%;
    }
    th, td {
      border: 1px solid var(--border);
      padding: 7px 12px;
      text-align: left;
    }
    th { background: var(--code-bg); font-weight: 600; }
    input[type="checkbox"] { margin-right: 0.45em; }
    .task-list { list-style: none; padding-left: 0.4em; }
    .mermaid {
      display: flex;
      justify-content: center;
      margin: 1.4em 0;
      padding: 8px;
      overflow-x: auto;
    }
    .mermaid svg { max-width: 100%; height: auto; }
    .mermaid-error {
      display: block;
      white-space: pre-wrap;
      font: 0.86em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #b3261e;
      background: rgba(179, 38, 30, 0.08);
      border-radius: 10px;
      padding: 12px 14px;
      text-align: left;
    }
    """

    /// Bundled Mermaid (vendored, no network) renders ```mermaid fences.
    private static let mermaidScripts = """
    <script src="\(assetScheme)://vendor/mermaid.min.js"></script>
    <script>
    (function () {
      if (!window.mermaid) { return; }
      var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: dark ? 'dark' : 'default',
        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
      });
      var run = function () {
        mermaid.run({ querySelector: '.mermaid' }).catch(function (error) {
          document.querySelectorAll('.mermaid').forEach(function (node) {
            node.classList.add('mermaid-error');
            if (!node.dataset.raw) { node.dataset.raw = node.textContent; }
          });
          console.error('mermaid: ' + error);
        });
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run);
      } else {
        run();
      }
    })();
    </script>
    """

    // MARK: - Escaping

    static func escapeHTML(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value).replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - URL policy

    /// Returns an allow-listed URL string, or nil when the destination is unsafe.
    static func safeURL(
        _ raw: String,
        context: Context,
        isImage: Bool
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("#") { return trimmed }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") { return nil }
        if lower.hasPrefix("data:") {
            return isImage && lower.hasPrefix("data:image/") ? trimmed : nil
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        if lower.hasPrefix("mailto:") { return isImage ? nil : trimmed }

        // Local path (relative, absolute, or file://) must stay inside the document folder.
        guard let directory = context.documentDirectory else { return nil }
        let path: String
        if lower.hasPrefix("file://") {
            guard let url = URL(string: trimmed) else { return nil }
            path = url.path
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else {
            path = trimmed
        }

        let candidate = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        // Images may legitimately live above the document (`../img/x.png`), so
        // we resolve any existing absolute path. The asset handler serves image
        // types only, which keeps the web view from reading arbitrary files.
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return context.assetURL(forAbsolutePath: candidate.path)
    }
}

// MARK: - Block parser

nonisolated private struct BlockParser {
    let lines: [String]
    var index = 0
    let context: MarkdownHTMLRenderer.Context

    init(markdown: String, context: MarkdownHTMLRenderer.Context) {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        lines = normalized.components(separatedBy: "\n")
        self.context = context
    }

    mutating func parse() -> String {
        var out: [String] = []
        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = Self.fenceInfo(line) {
                out.append(parseFencedCode(fence))
                continue
            }

            if let heading = Self.heading(line) {
                out.append("<h\(heading.level)>\(Inline.render(heading.text, context: context))</h\(heading.level)>")
                index += 1
                continue
            }

            if Self.isRule(line) {
                out.append("<hr>")
                index += 1
                continue
            }

            if Self.isBlockquote(line) {
                out.append(parseBlockquote())
                continue
            }

            if Self.tableHeader(at: index, in: lines) != nil {
                out.append(parseTable())
                continue
            }

            if Self.listItem(line) != nil {
                out.append(parseList())
                continue
            }

            out.append(parseParagraph())
        }
        return out.joined(separator: "\n")
    }

    // MARK: Blocks

    private struct Fence {
        let marker: String
        let language: String
    }

    private static func fenceInfo(_ line: String) -> Fence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["```", "~~~"] {
            if trimmed.hasPrefix(marker) {
                let info = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                return Fence(marker: marker, language: info)
            }
        }
        return nil
    }

    private mutating func parseFencedCode(_ fence: Fence) -> String {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                index += 1
                break
            }
            body.append(line)
            index += 1
        }
        let language = fence.language.split(separator: " ").first.map(String.init) ?? ""

        if language.lowercased() == "mermaid" {
            // Raw text: Mermaid reads it back from the DOM. Escaped so the
            // source cannot inject markup before Mermaid runs.
            return "<div class=\"mermaid\">\(MarkdownHTMLRenderer.escapeHTML(body.joined(separator: "\n")))</div>"
        }
        let classAttribute = language.isEmpty
            ? ""
            : " class=\"language-\(MarkdownHTMLRenderer.escapeHTML(language))\""
        return "<pre><code\(classAttribute)>\(MarkdownHTMLRenderer.escapeHTML(body.joined(separator: "\n")))</code></pre>"
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = String(rest).trimmingCharacters(in: .whitespaces)
        // Drop an optional closing sequence: "## Title ##"
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private mutating func parseBlockquote() -> String {
        var body: [String] = []
        while index < lines.count, Self.isBlockquote(lines[index]) {
            var line = lines[index].trimmingCharacters(in: .whitespaces)
            line.removeFirst() // ">"
            if line.hasPrefix(" ") { line.removeFirst() }
            body.append(line)
            index += 1
        }
        var nested = BlockParser(markdown: body.joined(separator: "\n"), context: context)
        return "<blockquote>\n\(nested.parse())\n</blockquote>"
    }

    private struct ListItem {
        let indent: Int
        let ordered: Bool
        let start: Int
        let text: String
    }

    private static func listItem(_ line: String) -> ListItem? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        guard !rest.isEmpty else { return nil }

        // Bullet: -, *, +
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            return ListItem(
                indent: indent,
                ordered: false,
                start: 1,
                text: String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            )
        }

        // Ordered: 1. / 1)
        var digits = ""
        var cursor = rest.startIndex
        while cursor < rest.endIndex, rest[cursor].isNumber {
            digits.append(rest[cursor])
            cursor = rest.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < rest.endIndex,
              rest[cursor] == "." || rest[cursor] == ")",
              let start = Int(digits)
        else { return nil }
        let afterMarker = rest.index(after: cursor)
        guard afterMarker < rest.endIndex, rest[afterMarker] == " " else { return nil }
        return ListItem(
            indent: indent,
            ordered: true,
            start: start,
            text: String(rest[rest.index(after: afterMarker)...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private mutating func parseList() -> String {
        var html: [String] = []
        var stack: [(indent: Int, ordered: Bool)] = []
        var openItems = 0

        func closeItems(_ count: Int) {
            guard count > 0 else { return }
            html.append(String(repeating: "</li>", count: count))
            openItems -= count
        }

        func closeList() {
            guard let top = stack.popLast() else { return }
            closeItems(1)
            html.append(top.ordered ? "</ol>" : "</ul>")
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                // A blank line only ends the list when the next line is not an item.
                if index < lines.count, Self.listItem(lines[index]) == nil { break }
                continue
            }

            guard var item = Self.listItem(line) else { break }

            // Continuation line of the current item (indented text).
            while index + 1 < lines.count,
                  !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  Self.listItem(lines[index + 1]) == nil,
                  Self.isIndentedContinuation(lines[index + 1], minimum: item.indent + 2)
            {
                index += 1
                item = ListItem(
                    indent: item.indent,
                    ordered: item.ordered,
                    start: item.start,
                    text: item.text + " " + lines[index].trimmingCharacters(in: .whitespaces)
                )
            }
            index += 1

            let checkbox = Self.taskCheckbox(item.text)
            let text = checkbox.text

            if stack.isEmpty {
                stack.append((item.indent, item.ordered))
                html.append(item.ordered
                    ? "<ol\(item.start != 1 ? " start=\"\(item.start)\"" : "")>"
                    : (checkbox.isTask ? "<ul class=\"task-list\">" : "<ul>"))
                html.append("<li>")
                openItems = 1
            } else if item.indent > stack[stack.count - 1].indent + 1 {
                // Nested list: keep the parent <li> open.
                stack.append((item.indent, item.ordered))
                html.append(item.ordered
                    ? "<ol\(item.start != 1 ? " start=\"\(item.start)\"" : "")>"
                    : (checkbox.isTask ? "<ul class=\"task-list\">" : "<ul>"))
                html.append("<li>")
                openItems += 1
            } else {
                while stack.count > 1, item.indent < stack[stack.count - 1].indent {
                    closeList()
                }
                let top = stack[stack.count - 1]
                if top.ordered != item.ordered {
                    closeList()
                    stack.append((item.indent, item.ordered))
                    html.append(item.ordered ? "<ol>" : (checkbox.isTask ? "<ul class=\"task-list\">" : "<ul>"))
                    html.append("<li>")
                    openItems += 1
                } else {
                    closeItems(1)
                    html.append("<li>")
                    openItems += 1
                }
            }

            let prefix: String
            if checkbox.isTask {
                prefix = "<input type=\"checkbox\" disabled\(checkbox.checked ? " checked" : "")>"
            } else {
                prefix = ""
            }
            html.append(prefix + Inline.render(text, context: context))
        }

        while !stack.isEmpty {
            closeList()
        }
        // Any remaining unbalanced item.
        closeItems(max(0, openItems))
        return html.joined()
    }

    private static func isIndentedContinuation(_ line: String, minimum: Int) -> Bool {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        return expanded.prefix { $0 == " " }.count >= minimum
    }

    private static func taskCheckbox(_ text: String) -> (isTask: Bool, checked: Bool, text: String) {
        let lowered = text.lowercased()
        if lowered.hasPrefix("[ ] ") {
            return (true, false, String(text.dropFirst(4)))
        }
        if lowered.hasPrefix("[x] ") {
            return (true, true, String(text.dropFirst(4)))
        }
        return (false, false, text)
    }

    // MARK: Tables

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableHeader(at index: Int, in lines: [String]) -> (headers: [String], alignments: [String])? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let separatorLine = lines[index + 1]
        guard headerLine.contains("|"), separatorLine.contains("-"), separatorLine.contains("|") else {
            return nil
        }
        let headers = splitRow(headerLine)
        let separators = splitRow(separatorLine)
        guard headers.count == separators.count, !headers.isEmpty else { return nil }

        var alignments: [String] = []
        for separator in separators {
            let compact = separator.replacingOccurrences(of: " ", with: "")
            guard compact.allSatisfy({ $0 == "-" || $0 == ":" }), compact.contains("-") else {
                return nil
            }
            let left = compact.hasPrefix(":")
            let right = compact.hasSuffix(":")
            switch (left, right) {
            case (true, true): alignments.append("center")
            case (false, true): alignments.append("right")
            case (true, false): alignments.append("left")
            default: alignments.append("")
            }
        }
        return (headers, alignments)
    }

    private mutating func parseTable() -> String {
        guard let table = Self.tableHeader(at: index, in: lines) else { return "" }
        index += 2

        func cell(_ tag: String, _ content: String, _ alignment: String) -> String {
            let style = alignment.isEmpty ? "" : " style=\"text-align: \(alignment)\""
            return "<\(tag)\(style)>\(Inline.render(content, context: context))</\(tag)>"
        }

        var html = ["<table>", "<thead>", "<tr>"]
        for (column, header) in table.headers.enumerated() {
            html.append(cell("th", header, table.alignments[column]))
        }
        html.append("</tr>")
        html.append("</thead>")
        html.append("<tbody>")

        while index < lines.count {
            let line = lines[index]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let cells = Self.splitRow(line)
            html.append("<tr>")
            for column in 0..<table.headers.count {
                let content = column < cells.count ? cells[column] : ""
                html.append(cell("td", content, table.alignments[column]))
            }
            html.append("</tr>")
            index += 1
        }

        html.append("</tbody>")
        html.append("</table>")
        return html.joined(separator: "\n")
    }

    // MARK: Paragraphs

    private mutating func parseParagraph() -> String {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if Self.heading(line) != nil
                || Self.isRule(line)
                || Self.isBlockquote(line)
                || Self.listItem(line) != nil
                || Self.fenceInfo(line) != nil
                || Self.tableHeader(at: index, in: lines) != nil
            {
                break
            }
            body.append(line)
            index += 1
        }

        guard !body.isEmpty else {
            index += 1
            return ""
        }

        // Trailing double space or backslash = hard line break.
        var rendered: [String] = []
        for (position, raw) in body.enumerated() {
            let isLast = position == body.count - 1
            var text = raw.trimmingCharacters(in: .whitespaces)
            var hardBreak = false
            if raw.hasSuffix("  ") || raw.hasSuffix("\\") {
                hardBreak = true
                if text.hasSuffix("\\") { text.removeLast() }
            }
            var lineHTML = Inline.render(text, context: context)
            if !isLast {
                if hardBreak { lineHTML += "<br>" }
                lineHTML += "\n"
            }
            rendered.append(lineHTML)
        }
        return "<p>\(rendered.joined())</p>"
    }
}

// MARK: - Inline parser

nonisolated private enum Inline {
    /// Destination allows one level of balanced parentheses so URLs like
    /// `javascript:alert(1)` or `Foo_(bar)` parse instead of leaking markup.
    private static let destination = #"((?:[^()\s]|\([^()]*\))+)"#

    private static let imageRegex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*"# + destination + #"(?:\s+"([^"]*)")?\s*\)"#
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]]*)\]\(\s*"# + destination + #"(?:\s+"([^"]*)")?\s*\)"#
    )
    private static let autolinkRegex = try! NSRegularExpression(
        pattern: #"&lt;(https?://[^\s&]+)&gt;"#
    )

    static func render(_ text: String, context: MarkdownHTMLRenderer.Context) -> String {
        var codeSpans: [String] = []

        // 1. Protect inline code before anything else can reformat it.
        var working = extractCodeSpans(text, into: &codeSpans)
        // 2. Escape HTML so raw tags render literally.
        working = MarkdownHTMLRenderer.escapeHTML(working)

        // 3. Images, then links (image syntax consumed first).
        working = replaceImages(in: working, context: context)
        working = replaceLinks(in: working, context: context)

        // 4. Autolinks.
        working = replace(autolinkRegex, in: working) { match in
            let url = substring(match, 1, in: working)
            return "<a href=\"\(MarkdownHTMLRenderer.escapeHTML(url))\">\(url)</a>"
        }

        // 5. Emphasis.
        working = working
            .replacingOccurrences(
                of: #"\*\*(.+?)\*\*"#,
                with: "<strong>$1</strong>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<!\w)__(.+?)__(?!\w)"#,
                with: "<strong>$1</strong>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"~~(.+?)~~"#,
                with: "<del>$1</del>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#,
                with: "<em>$1</em>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#,
                with: "<em>$1</em>",
                options: .regularExpression
            )

        // 6. Restore code spans.
        for (position, code) in codeSpans.enumerated() {
            let token = codeToken(position)
            if let range = working.range(of: token) {
                working.replaceSubrange(
                    range,
                    with: "<code>\(MarkdownHTMLRenderer.escapeHTML(code))</code>"
                )
            }
        }
        return working
    }

    private static func codeToken(_ index: Int) -> String {
        "\u{0}CODE\(index)\u{0}"
    }

    private static func extractCodeSpans(_ text: String, into storage: inout [String]) -> String {
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "`" else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            // Count the run of backticks.
            var ticks = 0
            var scan = cursor
            while scan < text.endIndex, text[scan] == "`" {
                ticks += 1
                scan = text.index(after: scan)
            }
            let fence = String(repeating: "`", count: ticks)
            guard let closing = text.range(of: fence, range: scan..<text.endIndex) else {
                result.append(fence)
                cursor = scan
                continue
            }
            let code = String(text[scan..<closing.lowerBound])
            result.append(codeToken(storage.count))
            storage.append(code)
            cursor = closing.upperBound
        }
        return result
    }

    private static func substring(
        _ match: NSTextCheckingResult,
        _ group: Int,
        in source: String
    ) -> String {
        guard group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: source)
        else { return "" }
        return String(source[range])
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in source: String,
        transform: (NSTextCheckingResult) -> String
    ) -> String {
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return source }

        var result = ""
        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            result += source[cursor..<range.lowerBound]
            result += transform(match)
            cursor = range.upperBound
        }
        result += source[cursor...]
        return result
    }

    private static func replaceImages(
        in source: String,
        context: MarkdownHTMLRenderer.Context
    ) -> String {
        replace(imageRegex, in: source) { match in
            let alt = substring(match, 1, in: source)
            let rawURL = substring(match, 2, in: source)
            guard let url = MarkdownHTMLRenderer.safeURL(rawURL, context: context, isImage: true) else {
                return alt.isEmpty ? "" : "<span class=\"broken-image\">\(alt)</span>"
            }
            let title = substring(match, 3, in: source)
            let titleAttribute = title.isEmpty
                ? ""
                : " title=\"\(MarkdownHTMLRenderer.escapeHTML(title))\""
            return "<img src=\"\(MarkdownHTMLRenderer.escapeHTML(url))\" alt=\"\(MarkdownHTMLRenderer.escapeHTML(alt))\"\(titleAttribute)>"
        }
    }

    private static func replaceLinks(
        in source: String,
        context: MarkdownHTMLRenderer.Context
    ) -> String {
        replace(linkRegex, in: source) { match in
            let label = substring(match, 1, in: source)
            let rawURL = substring(match, 2, in: source)
            guard let url = MarkdownHTMLRenderer.safeURL(rawURL, context: context, isImage: false) else {
                return label
            }
            let title = substring(match, 3, in: source)
            let titleAttribute = title.isEmpty
                ? ""
                : " title=\"\(MarkdownHTMLRenderer.escapeHTML(title))\""
            return "<a href=\"\(MarkdownHTMLRenderer.escapeHTML(url))\"\(titleAttribute)>\(label)</a>"
        }
    }
}

#if DEBUG
extension MarkdownHTMLRenderer {
    /// Parser invariants used by the launch self-check. Builds a throwaway tree
    /// so image resolution is exercised against real files.
    static func runSelfCheck() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arbor-md-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let doc = root.appendingPathComponent("README.md")
        let images = root.appendingPathComponent("images", isDirectory: true)
        let parent = root.deletingLastPathComponent()
            .appendingPathComponent("escape-\(UUID().uuidString).png")
        defer { try? fm.removeItem(at: parent) }
        do {
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: doc)
            try Data("x".utf8).write(to: images.appendingPathComponent("pic.png"))
            try Data("x".utf8).write(to: parent)
        } catch {
            assertionFailure("Markdown self-check setup failed: \(error)")
            return
        }

        let context = Context(documentURL: doc, docID: "test")
        let sample = """
        # Title

        Some **bold**, *italic*, `code` and a [link](https://example.com).

        - one
        - two
          - nested

        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1 < 2
        ```

        ![shot](images/pic.png)
        ![parent](../\(parent.lastPathComponent))
        ![missing](images/nope.png)
        <script>alert(1)</script>
        [bad](javascript:alert(1))
        [parens](https://example.com/a_(b))

        ```mermaid
        flowchart LR
          A[Start] --> B{Ok?}
          B -->|yes| C[Done]
        ```
        """
        let html = html(markdown: sample, title: "README.md", context: context)

        assert(html.contains("<h1>Title</h1>"), "heading")
        assert(html.contains("<strong>bold</strong>"), "bold")
        assert(html.contains("<em>italic</em>"), "italic")
        assert(html.contains("<code>code</code>"), "inline code")
        assert(html.contains("<a href=\"https://example.com\">link</a>"), "link")
        assert(html.contains("<ul>"), "bullet list")
        assert(html.contains("<li>two"), "list item")
        assert(html.contains("<table>"), "table")
        assert(html.contains("<td>1</td>"), "table cell")
        assert(html.contains("language-swift"), "fenced language")
        assert(html.contains("let x = 1 &lt; 2"), "code escaping")
        assert(html.contains("src=\"arbor-md://test/"), "local image via asset scheme")
        assert(!html.contains("src=\"images/"), "image src is not left relative")
        assert(html.contains("alt=\"parent\""), "parent-folder image resolves")
        assert(html.contains("broken-image"), "missing image degrades to alt text")
        assert(html.contains("&lt;script&gt;"), "raw HTML escaped")
        assert(!html.contains("<script>alert"), "no script injection")
        assert(!html.contains("javascript:"), "javascript URL rejected")
        assert(html.contains("<div class=\"mermaid\">"), "mermaid fence rendered as container")
        assert(html.contains("flowchart LR"), "mermaid source preserved")
        assert(html.contains("mermaid.min.js"), "mermaid runtime is bundled")
        assert(
            !html.contains("<pre><code class=\"language-mermaid\""),
            "mermaid must not stay a code block"
        )

        // Documents without diagrams must not pay for the 2.5 MB runtime.
        let plainHTML = MarkdownHTMLRenderer.html(
            markdown: "# Just text\n\nNo diagrams here.",
            title: "plain.md",
            context: context
        )
        assert(!plainHTML.contains("mermaid.min.js"), "mermaid runtime is lazy")
        assert(
            html.contains("<a href=\"https://example.com/a_(b)\">parens</a>"),
            "balanced parentheses in URLs"
        )
    }
}
#endif
