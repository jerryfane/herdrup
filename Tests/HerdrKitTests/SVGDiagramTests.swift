import XCTest
@testable import HerdrKit

/// An agent's ```svg block is drawn in the app, so what reaches WebKit must be inert: no
/// script, no handler, nothing fetched. These read the sanitizer's output, which is exactly
/// what the renderer and the full-screen viewer are given.
final class SVGDiagramTests: XCTestCase {
    private let theme = ["fg": "#EEF0F7", "muted": "#99A0BC", "border": "#666D91"]

    func testScriptsHandlersForeignObjectsAndExternalReferencesAreRemoved() throws {
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 50" onload="alert(1)">
          <script>alert('script')</script>
          <script type="text/javascript"><![CDATA[ fetch('https://evil.example/x') ]]></script>
          <style>@import url("https://evil.example/a.css"); .t { fill: var(--fg); background: url(https://evil.example/b.png); } .g { fill: url(#grad); }</style>
          <defs><linearGradient id="grad"><stop offset="0" stop-color="red"/></linearGradient></defs>
          <rect id="box" width="10" height="10" onclick="steal()" ONMOUSEOVER="steal()" fill="url(https://evil.example/c.svg#p)"/>
          <foreignObject width="50" height="50"><div xmlns="http://www.w3.org/1999/xhtml"><iframe src="https://evil.example"></iframe></div></foreignObject>
          <image href="https://evil.example/d.png" width="10" height="10"/>
          <image xlink:href="javascript:alert(1)" width="10" height="10"/>
          <image href="data:image/png;base64,iVBORw0KGgo=" width="1" height="1"/>
          <use xlink:href="#box" x="20"/>
          <use href="https://evil.example/sprite.svg#icon"/>
          <a href="javascript:alert(2)"><text x="1" y="20" class="t">link</text></a>
          <animate attributeName="href" values="javascript:alert(3)"/>
          <set attributeName="onclick" to="alert(4)"/>
        </svg>
        """
        let svg = try XCTUnwrap(SVGDiagram.sanitize(source, variables: theme)).svg
        let lower = svg.lowercased()

        for gone in ["<script", "alert", "fetch(", "onload", "onclick", "onmouseover", "foreignobject",
                     "iframe", "evil.example", "javascript:", "@import", "<animate", "<set"] {
            XCTAssertFalse(lower.contains(gone), "\(gone) must not survive:\n\(svg)")
        }
        // What is inside the document stays: internal references, an inline raster, the
        // gradient fill and the link's text.
        XCTAssertTrue(svg.contains("xlink:href=\"#box\""), svg)
        XCTAssertTrue(svg.contains("href=\"data:image/png;base64,iVBORw0KGgo=\""), svg)
        XCTAssertTrue(svg.contains("fill: url(#grad)"), svg)
        XCTAssertTrue(svg.contains(">link</text>"), svg)
        // An external fill is not fetched: it paints nothing.
        XCTAssertTrue(svg.contains("fill=\"none\""), svg)
    }

    /// The owner's block (round 4): colours are the host page's CSS variables, which an image
    /// on its own would not have. They become the app's palette.
    func testOwnersSampleGetsThePalettesColoursAndItsOwnSize() throws {
        let source = """
        <svg viewBox="0 0 900 360" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif" font-size="13">
          <rect x="10" y="10" width="880" height="40" rx="6" fill="none" stroke="var(--border)"/>
          <text x="26" y="35" fill="var(--fg)">▶ Play</text>
          <text x="26" y="136" fill="var(--muted)">Finance manager · Up&amp;Running</text>
          <text x="40" y="200" fill="var(--accent, #7A6FF0)">fallback</text>
          <text x="40" y="220" fill="var(--unknown)">left for CSS</text>
        </svg>
        """
        let result = try XCTUnwrap(SVGDiagram.sanitize(source, variables: theme))
        XCTAssertEqual(result.width, 900)
        XCTAssertEqual(result.height, 360)
        XCTAssertTrue(result.svg.contains("stroke=\"#666D91\""), result.svg)
        XCTAssertTrue(result.svg.contains("fill=\"#EEF0F7\""), result.svg)
        XCTAssertTrue(result.svg.contains("fill=\"#99A0BC\""), result.svg)
        XCTAssertTrue(result.svg.contains("fill=\"#7A6FF0\""), result.svg)
        XCTAssertTrue(result.svg.contains("fill=\"var(--unknown)\""), result.svg)
        XCTAssertTrue(result.svg.contains(":root{--border:#666D91;--fg:#EEF0F7;--muted:#99A0BC}"), result.svg)
        XCTAssertTrue(result.svg.contains("Up&amp;Running"), "text stays escaped: \(result.svg)")
        XCTAssertTrue(result.svg.hasPrefix("<svg "), result.svg)
        XCTAssertTrue(result.svg.contains(" width=\"900\" "), result.svg)
        XCTAssertTrue(result.svg.contains("xmlns=\"http://www.w3.org/2000/svg\""), result.svg)
        // The output parses again (the renderer loads it as an image) and is stable, so the
        // same block is the same document every launch.
        XCTAssertEqual(SVGDiagram.sanitize(source, variables: theme), result)
        XCTAssertNotNil(SVGDiagram.sanitize(result.svg))
    }

    func testMalformedOrNonSVGDocumentsAreRejected() {
        XCTAssertNil(SVGDiagram.sanitize("<svg viewBox=\"0 0 10 10\"><rect width=\"4\"></svg>"), "unclosed element")
        XCTAssertNil(SVGDiagram.sanitize("<svg><g></svg>"))
        XCTAssertNil(SVGDiagram.sanitize("<html><body/></html>"), "the root must be <svg>")
        XCTAssertNil(SVGDiagram.sanitize("<svg/><svg/>"), "one root only")
        XCTAssertNil(SVGDiagram.sanitize("not xml at all"))
        XCTAssertNil(SVGDiagram.sanitize(""))
        XCTAssertNil(SVGDiagram.sanitize("<svg width=\"100000\" height=\"10\"/>"), "over the size cap")
        let huge = "<svg>" + String(repeating: "<g/>", count: SVGDiagram.maxBytes / 4) + "</svg>"
        XCTAssertNil(SVGDiagram.sanitize(huge), "over the byte cap")
    }

    func testSizeComesFromWidthHeightOrViewBox() throws {
        let both = try XCTUnwrap(SVGDiagram.sanitize("<svg width=\"200px\" height=\"80\" viewBox=\"0 0 20 8\"/>"))
        XCTAssertEqual([both.width, both.height], [200, 80])
        let widthOnly = try XCTUnwrap(SVGDiagram.sanitize("<svg width=\"300\" viewBox=\"0,0,30,10\"/>"))
        XCTAssertEqual([widthOnly.width, widthOnly.height], [300, 100])
        let percent = try XCTUnwrap(SVGDiagram.sanitize("<svg width=\"100%\" viewBox=\"0 0 40 10\"/>"))
        XCTAssertEqual([percent.width, percent.height], [40, 10])
        let bare = try XCTUnwrap(SVGDiagram.sanitize("<svg><circle r=\"5\"/></svg>"))
        XCTAssertEqual([bare.width, bare.height], [300, 150])
        XCTAssertTrue(bare.svg.contains("viewBox=\"0 0 300 150\""), "a viewBox lets the viewer scale it: \(bare.svg)")
    }

    func testXMLFenceIsAnSVGOnlyWithAnSVGRoot() {
        XCTAssertTrue(SVGDiagram.looksLikeSVG("<?xml version=\"1.0\"?>\n<!-- drawn -->\n<svg viewBox=\"0 0 1 1\"></svg>\n"))
        XCTAssertTrue(SVGDiagram.looksLikeSVG("<svg>\n</svg>"))
        XCTAssertFalse(SVGDiagram.looksLikeSVG("<svgx></svgx>"))
        XCTAssertFalse(SVGDiagram.looksLikeSVG("<project><svg/></project>"))
        XCTAssertFalse(SVGDiagram.looksLikeSVG("<?xml version=\"1.0\"?><config/>"))
    }
}
