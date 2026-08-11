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
}
