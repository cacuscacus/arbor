import Foundation

/// Renders a source-code file as a highlighted HTML document.
///
/// Highlighting runs in the web view with the bundled highlight.js grammar set
/// (no network). Line numbers and a header strip come from the HTML itself so
/// they survive zoom and printing.
nonisolated enum CodeHTMLRenderer {
    /// Above this size highlighting is skipped (large files stay readable and
    /// the page stays responsive).
    static let highlightLimit = 600_000

    static func html(
        code: String,
        language: SourceLanguage,
        fileName: String,
        lineCount: Int
    ) -> String {
        let escaped = escapeHTML(code)
        let tooLarge = code.utf8.count > highlightLimit
        let isPlain = language.highlighterID == "plaintext"
        let highlight = !tooLarge && !isPlain

        let notice: String
        if tooLarge {
            notice = "<span class=\"notice\">Large file — syntax highlighting skipped</span>"
        } else {
            notice = ""
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(fileName))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <div class="code-header">
          <span class="lang">\(escapeHTML(language.displayName))</span>
          <span class="meta">\(lineCount) line\(lineCount == 1 ? "" : "s") · \(formattedSize(code))</span>
          \(notice)
        </div>
        <pre class="code-block"><code class="hljs language-\(escapeHTML(language.highlighterID))">\(escaped)</code></pre>
        \(highlight ? highlightScripts : "")
        </body>
        </html>
        """
    }

    private static func formattedSize(_ text: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }

    static func escapeHTML(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + value.count / 8)
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

    /// Loads the bundled grammar set, then highlights the single code block.
    /// Syntax errors fall back to plain text instead of leaving the page blank.
    private static let highlightScripts = """
    <script src="\(MarkdownHTMLRenderer.assetScheme)://vendor/highlight.min.js"></script>
    <script>
    (function () {
      var block = document.querySelector('.code-block code');
      if (!block || !window.hljs) { return; }
      var language = (block.className.match(/language-([a-z0-9+#._-]+)/i) || [])[1];
      try {
        if (language && hljs.getLanguage(language)) {
          var result = hljs.highlight(block.textContent, { language: language, ignoreIllegals: true });
          block.innerHTML = result.value;
          block.classList.add('hljs');
        } else {
          block.classList.add('hljs');
          block.classList.add('language-plaintext');
        }
      } catch (error) {
        block.classList.add('hljs');
        console.error('highlight: ' + error);
      }
    })();
    </script>
    """

    /// Token colors mirror the GitHub palettes arbor uses elsewhere.
    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --fg: #1f2328;
      --muted: #6e7781;
      --border: rgba(0, 0, 0, 0.12);
      --gutter: rgba(120, 120, 128, 0.10);
      --header-bg: rgba(120, 120, 128, 0.08);
      --keyword: #cf222e;
      --string: #0a3069;
      --number: #0550ae;
      --comment: #6e7781;
      --function: #8250df;
      --type: #953800;
      --attr: #0550ae;
      --tag: #116329;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1e1e1e;
        --fg: #e6edf3;
        --muted: #8b949e;
        --border: rgba(255, 255, 255, 0.14);
        --gutter: rgba(255, 255, 255, 0.06);
        --header-bg: rgba(255, 255, 255, 0.06);
        --keyword: #ff7b72;
        --string: #a5d6ff;
        --number: #79c0ff;
        --comment: #8b949e;
        --function: #d2a8ff;
        --type: #ffa657;
        --attr: #79c0ff;
        --tag: #7ee787;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
    body {
      font: 12.5px/1.6 ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
      -webkit-font-smoothing: antialiased;
    }
    .code-header {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 16px;
      background: var(--header-bg);
      border-bottom: 1px solid var(--border);
      font: 11px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      position: sticky;
      top: 0;
      backdrop-filter: blur(12px);
      z-index: 1;
    }
    .code-header .lang { font-weight: 600; letter-spacing: 0.01em; }
    .code-header .meta { color: var(--muted); }
    .code-header .notice { color: #b3261e; margin-left: auto; }
    pre.code-block {
      margin: 0;
      padding: 14px 18px 32px;
      overflow-x: auto;
      tab-size: 4;
      white-space: pre;
    }
    pre.code-block code {
      display: block;
      background: none;
      border: 0;
      padding: 0;
      font: inherit;
      color: inherit;
    }
    .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-doctag, .hljs-name {
      color: var(--keyword);
    }
    .hljs-string, .hljs-regexp, .hljs-char.escape_, .hljs-meta .hljs-string {
      color: var(--string);
    }
    .hljs-number, .hljs-symbol, .hljs-bullet, .hljs-link, .hljs-variable, .hljs-template-variable {
      color: var(--number);
    }
    .hljs-comment, .hljs-quote, .hljs-code {
      color: var(--comment);
      font-style: italic;
    }
    .hljs-title, .hljs-title.function_, .hljs-section, .hljs-selector-id {
      color: var(--function);
    }
    .hljs-type, .hljs-built_in, .hljs-class .hljs-title, .hljs-title.class_ {
      color: var(--type);
    }
    .hljs-attr, .hljs-attribute, .hljs-property, .hljs-selector-attr, .hljs-selector-class {
      color: var(--attr);
    }
    .hljs-tag, .hljs-selector-pseudo, .hljs-meta-keyword {
      color: var(--tag);
    }
    .hljs-subst, .hljs-params { color: inherit; }
    .hljs-emphasis { font-style: italic; }
    .hljs-strong { font-weight: 600; }
    .hljs-addition { color: #116329; background: rgba(17, 99, 41, 0.12); }
    .hljs-deletion { color: #a40e26; background: rgba(164, 14, 38, 0.12); }
    @media (prefers-color-scheme: dark) {
      .hljs-addition { color: #7ee787; background: rgba(126, 231, 135, 0.12); }
      .hljs-deletion { color: #ff7b72; background: rgba(255, 123, 114, 0.12); }
    }
    """
}

#if DEBUG
extension CodeHTMLRenderer {
    static func runSelfCheck() {
        let language = SourceLanguage(highlighterID: "python", displayName: "Python")
        let html = html(
            code: "def f(x):\n    return \"<tag>\"",
            language: language,
            fileName: "a.py",
            lineCount: 2
        )
        assert(html.contains("language-python"), "grammar class")
        assert(html.contains("&lt;tag&gt;"), "code escaped")
        assert(html.contains("highlight.min.js"), "highlight runtime bundled")
        assert(html.contains("2 lines"), "line count in header")

        let single = CodeHTMLRenderer.html(
            code: "x",
            language: language,
            fileName: "x.py",
            lineCount: 1
        )
        assert(single.contains("1 line "), "singular line label")
        assert(!single.contains("1 lines"), "no plural for one line")
    }
}
#endif
