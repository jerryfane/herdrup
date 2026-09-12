import CoreText
import UIKit
import XCTest
@testable import Herdr

final class TerminalFontTests: XCTestCase {
    func testNerdSymbolFallbackPreservesPrimaryTextFace() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        let textFace = resolvedFont(for: "A", from: font)
        let symbolFace = resolvedFont(for: "\u{f07b}", from: font)

        XCTAssertEqual(CTFontCopyPostScriptName(textFace) as String, "IBMPlexMono")
        XCTAssertEqual(CTFontCopyPostScriptName(symbolFace) as String, "SymbolsNFM")

        var character = UniChar(0xf07b)
        var glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(symbolFace, &character, &glyph, 1))
        XCTAssertNotEqual(glyph, 0)

        assertSystemFallback(resolvedFont(for: "漢", from: font))
        assertSystemFallback(resolvedFont(for: "\u{263a}\u{fe0f}", from: font))
    }

    private func resolvedFont(for text: String, from font: UIFont) -> CTFont {
        CTFontCreateForString(
            font as CTFont,
            text as CFString,
            CFRange(location: 0, length: (text as NSString).length)
        )
    }

    private func assertSystemFallback(
        _ font: CTFont,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let name = CTFontCopyPostScriptName(font) as String
        XCTAssertNotEqual(name, "SymbolsNFM", file: file, line: line)
        XCTAssertNotEqual(name, "LastResort", file: file, line: line)
    }
}
