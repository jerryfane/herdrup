// herdr: the text-input offset helpers live in `iOS/iOSTextInput.swift`, which
// the package excludes on Linux/Windows, so these cases only exist where UIKit
// (or AppKit, for the shared Apple sources) does. Without this guard the whole
// test target fails to build on Linux and the core suite cannot run there.
#if canImport(UIKit) || canImport(AppKit)
import XCTest
@testable import SwiftTerm

final class IOSTextInputOffsetTests: XCTestCase {
    func testTextInputRangeAcceptsUTF16EndOffsetForThaiInput() {
        let text = "ฟหกดเ้"
        XCTAssertEqual(text.count, 5)
        XCTAssertEqual(text.textInputUTF16Count, 6)

        let stringRange = text.textInputRange(startUTF16Offset: 6, endUTF16Offset: 6)

        XCTAssertEqual(String(text[stringRange]), "")
        XCTAssertEqual(text.textInputUTF16Offset(of: stringRange.lowerBound), 6)
    }

    func testFullRangeUsesUTF16OffsetsForThaiInput() {
        let text = "ฟหกดเ้"
        let range = text.textInputRange(startUTF16Offset: 0, endUTF16Offset: 6)

        XCTAssertEqual(String(text[range]), text)
    }

    func testDeleteRangeBeforeUTF16OffsetKeepsThaiClusterTogether() {
        let text = "ฟหกดเ้"
        let range = text.textInputCharacterRange(beforeUTF16Offset: 6)

        XCTAssertEqual(range.map { String(text[$0]) }, "เ้")
        XCTAssertEqual(range.map { text.textInputUTF16Offset(of: $0.lowerBound) }, 4)
    }

#if canImport(UIKit)
    func testTextRangeFullRangeUsesUTF16OffsetsForThaiInput() {
        let text = "ฟหกดเ้"
        let range = TextRange(from: TextPosition(offset: 0), to: TextPosition(offset: 6))

        XCTAssertEqual(String(text[range.fullRange(in: text)]), text)
    }
#endif
}
#endif
