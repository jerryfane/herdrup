import XCTest
@testable import HerdrKit

final class MermaidDiagramTests: XCTestCase {

    func testWidthBucketRoundsDownToAStepAndNeverBelowOne() {
        XCTAssertEqual(MermaidDiagram.widthBucket(358), 320)
        XCTAssertEqual(MermaidDiagram.widthBucket(360), 360)
        XCTAssertEqual(MermaidDiagram.widthBucket(719.5), 680)
        XCTAssertEqual(MermaidDiagram.widthBucket(12), 40)
        XCTAssertEqual(MermaidDiagram.widthBucket(0), 40)
        XCTAssertEqual(MermaidDiagram.widthBucket(.nan), 40)
    }

    func testFittedKeepsAspectWithinTheColumnAndCapsTallDiagrams() {
        // Smaller than the column: drawn at its own size.
        XCTAssertTrue(MermaidDiagram.fitted(width: 200, height: 100, maxWidth: 320) == (200, 100))
        // Wider than the column: shrunk to the column width.
        XCTAssertTrue(MermaidDiagram.fitted(width: 640, height: 320, maxWidth: 320) == (320, 160))
        // Taller than 1.2 columns: capped at 1.2 columns high, narrower to keep its aspect.
        let tall = MermaidDiagram.fitted(width: 300, height: 3000, maxWidth: 320)
        XCTAssertEqual(tall.height, 384, accuracy: 0.001)
        XCTAssertEqual(tall.width, 38.4, accuracy: 0.001)
        XCTAssertTrue(MermaidDiagram.fitted(width: 0, height: 10, maxWidth: 320) == (0, 0))
    }

    /// The image cache must never hand back a render made for another diagram, theme or width,
    /// and must hit for the same three.
    func testCacheKeyCoversSourceThemeAndWidth() {
        let key = MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 320)
        XCTAssertEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 320))
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->C", theme: "dark", widthBucket: 320))
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark@1.2", widthBucket: 320))
        XCTAssertNotEqual(key, MermaidDiagram.cacheKey(source: "graph TD\nA-->B", theme: "dark", widthBucket: 360))
    }

    func testAccessibilityLabelNamesTheFirstLine() {
        XCTAssertEqual(MermaidDiagram.accessibilityLabel("\n  sequenceDiagram  \n  A->>B: hi"),
                       "Mermaid diagram, sequenceDiagram")
        XCTAssertEqual(MermaidDiagram.accessibilityLabel(" \n"), "Mermaid diagram")
    }

    func testViewerDocumentIsInertAndKeepsTheDrawing() {
        let svg = #"<svg viewBox="0 0 10 10"><script>alert(1)</script><SCRIPT type="x">x</SCRIPT ><g><text>Node</text></g></svg>"#
        let doc = MermaidDiagram.viewerDocument(svg: svg, background: "#13162A")
        XCTAssertFalse(doc.lowercased().contains("<script"))
        XCTAssertFalse(doc.contains("alert(1)"))
        XCTAssertTrue(doc.contains(#"<svg viewBox="0 0 10 10"><g><text>Node</text></g></svg>"#))
        XCTAssertTrue(doc.contains("default-src 'none'"))
        XCTAssertTrue(doc.contains("background: #13162A"))
    }
}
