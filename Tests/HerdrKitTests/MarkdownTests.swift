import XCTest
@testable import HerdrKit

/// The Markdown → HTML converter is the real logic behind the app's formatted
/// `.md` preview; the app only decides when to call it. Verified here on Linux.
final class MarkdownTests: XCTestCase {

    private func html(_ md: String) -> String { Markdown.toStyledHTML(md) }

    func testHeadingsByLevel() {
        let out = html("# One\n## Two\n### Three")
        XCTAssertTrue(out.contains("<h1>One</h1>"))
        XCTAssertTrue(out.contains("<h2>Two</h2>"))
        XCTAssertTrue(out.contains("<h3>Three</h3>"))
    }

    func testBoldItalicInlineCode() {
        let out = Markdown.inline("a **bold** and *italic* and `code()` here")
        XCTAssertTrue(out.contains("<strong>bold</strong>"), out)
        XCTAssertTrue(out.contains("<em>italic</em>"), out)
        XCTAssertTrue(out.contains("<code>code()</code>"), out)
    }

    func testLink() {
        let out = Markdown.inline("see [herdr](https://herdr.dev/docs)")
        XCTAssertTrue(out.contains("<a href=\"https://herdr.dev/docs\">herdr</a>"), out)
    }

    func testHtmlIsEscaped() {
        // Angle brackets and ampersands in prose must not become live markup.
        let out = Markdown.inline("tags <script> & <b> stay literal")
        XCTAssertTrue(out.contains("&lt;script&gt;"), out)
        XCTAssertTrue(out.contains("&amp;"), out)
        XCTAssertFalse(out.contains("<script>"), out)
    }

    func testCodeSpanContentIsNotParsedAsMarkup() {
        // Inside a code span, ** and < are literal, not markup.
        let out = Markdown.inline("`a **b** <c>`")
        XCTAssertTrue(out.contains("<code>a **b** &lt;c&gt;</code>"), out)
        XCTAssertFalse(out.contains("<strong>"), out)
    }

    func testUnorderedAndOrderedLists() {
        let ul = html("- one\n- two\n- three")
        XCTAssertTrue(ul.contains("<ul>"), ul)
        XCTAssertEqual(ul.components(separatedBy: "<li>").count - 1, 3, ul)

        let ol = html("1. first\n2. second")
        XCTAssertTrue(ol.contains("<ol>"), ol)
        XCTAssertTrue(ol.contains("<li>first</li>"), ol)
    }

    func testFencedCodeBlock() {
        let out = html("```\nlet x = 1 < 2\n```")
        XCTAssertTrue(out.contains("<pre><code>let x = 1 &lt; 2</code></pre>"), out)
    }

    func testGitHubTable() {
        let out = html("| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |")
        XCTAssertTrue(out.contains("<table>"), out)
        XCTAssertTrue(out.contains("<th>A</th>"), out)
        XCTAssertTrue(out.contains("<td>1</td>"), out)
        XCTAssertTrue(out.contains("<td>4</td>"), out)
    }

    func testBlockquoteAndHorizontalRule() {
        let out = html("> quoted line\n\n---")
        XCTAssertTrue(out.contains("<blockquote>"), out)
        XCTAssertTrue(out.contains("<hr>"), out)
    }

    func testParagraphsSeparatedByBlankLine() {
        let out = html("first para\n\nsecond para")
        XCTAssertTrue(out.contains("<p>first para</p>"), out)
        XCTAssertTrue(out.contains("<p>second para</p>"), out)
    }

    func testDocumentIsSelfContained() {
        let out = html("# Title\n\nbody")
        XCTAssertTrue(out.hasPrefix("<!doctype html>"), out)
        XCTAssertTrue(out.contains("<style>"), out)
        XCTAssertTrue(out.contains("prefers-color-scheme: dark"), out)
    }

    // MARK: - Injection safety

    func testEscapeCoversQuotes() {
        let out = Markdown.escape("say \"hi\" it's")
        XCTAssertTrue(out.contains("&quot;"), out)
        XCTAssertTrue(out.contains("&#39;"), out)
    }

    func testLinkAttributeInjectionIsNeutralized() {
        // A quote in the URL must be escaped so it can't break out of href="..."
        // and inject a live event handler.
        let out = Markdown.inline(#"[x](https://a.com/"onmouseover="alert(1))"#)
        XCTAssertFalse(out.contains("\"onmouseover=\""), out)  // no live attribute
        XCTAssertTrue(out.contains("&quot;"), out)  // the quote is escaped
    }

    func testUnsafeSchemesAreDroppedNotLinked() {
        let js = Markdown.inline("[click](javascript:alert(1))")
        XCTAssertFalse(js.lowercased().contains("href"), js)  // no link at all
        XCTAssertTrue(js.contains("click"), js)  // text preserved

        let data = Markdown.inline("[x](data:text/html,<script>1</script>)")
        XCTAssertFalse(data.lowercased().contains("href=\"data:"), data)
    }

    func testSafeSchemesAreLinked() {
        XCTAssertTrue(Markdown.inline("[a](https://x.com)").contains(#"<a href="https://x.com">a</a>"#))
        XCTAssertTrue(Markdown.inline("[a](mailto:x@y.com)").contains(#"href="mailto:x@y.com""#))
        XCTAssertTrue(Markdown.inline("[a](/docs)").contains(#"href="/docs""#))
    }

    func testDocumentHasStrictCSP() {
        let out = html("# x")
        XCTAssertTrue(out.contains("Content-Security-Policy"), out)
        XCTAssertTrue(out.contains("default-src 'none'"), out)
    }

    func testDeeplyNestedBlockquoteDoesNotCrash() {
        // A hostile deeply-nested quote must render bounded, not overflow the stack.
        let out = html(String(repeating: ">", count: 500) + " boom")
        XCTAssertTrue(out.contains("<blockquote>"), "should still render a bounded quote")
    }
}
