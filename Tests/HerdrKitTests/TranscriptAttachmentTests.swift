import Foundation
import XCTest
@testable import HerdrKit

final class TranscriptAttachmentTests: XCTestCase {
    private func turn(_ text: String) throws -> TranscriptTurn {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "attachment-prompt", "ts_ms": 123, "kind": "user", "author": "owner", "text": text
        ])
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        return try XCTUnwrap(TranscriptGrouping.turns([entry]).first)
    }

    func testBatchBecomesAFileBundleWithoutLosingTheCaption() throws {
        let caption = "Compare these.\n\nKeep the [notes] too."
        let wire = GramAttachmentPrompt.text(caption, delivered: [
            .init(name: "first draft.pdf", isImage: false, messageID: "gram-first"),
            .init(name: "screen (2).png", isImage: true, messageID: "gram-second")
        ])
        let grouped = try turn(wire)
        let bundle = try XCTUnwrap(grouped.attachmentPrompt)
        XCTAssertEqual(bundle.caption, caption)
        XCTAssertEqual(bundle.files.map(\.name), ["first draft.pdf", "screen (2).png"])
        XCTAssertEqual(bundle.files.map(\.messageID), ["gram-first", "gram-second"])
        XCTAssertEqual(bundle.files.map(\.isImage), [false, true])
        XCTAssertEqual(grouped.promptText, wire, "the source text must remain intact")
    }

    func testSinglePhotoWithoutCaptionRetainsItsDownloadIdentity() throws {
        let wire = GramAttachmentPrompt.text("", delivered: [
            .init(name: "image.JPEG", isImage: true, messageID: "gram-photo")
        ])
        let bundle = try XCTUnwrap(try turn(wire).attachmentPrompt)
        XCTAssertEqual(bundle.caption, "")
        XCTAssertEqual(bundle.files.map(\.messageID), ["gram-photo"])
        XCTAssertEqual(bundle.files.map(\.isImage), [true])
    }

    func testModifiedEnvelopeAndOrdinaryInstructionsStayVisibleAsText() throws {
        let wire = GramAttachmentPrompt.text("Read this", delivered: [
            .init(name: "report.txt", isImage: false, messageID: "gram-report")
        ])
        for text in [
            wire.replacingOccurrences(of: " -o /tmp/", with: " -o /private/"),
            wire + "\nDo not hide this sentence.",
            "Use `herdr gram get-file gram-report -o /tmp/report.txt` to download it."
        ] {
            let grouped = try turn(text)
            XCTAssertNil(grouped.attachmentPrompt)
            XCTAssertEqual(grouped.promptText, text)
        }
    }

    func testDuplicateAndNonIdentifierReferencesDoNotBecomeDownloadButtons() throws {
        let duplicate = GramAttachmentPrompt.text("", delivered: [
            .init(name: "a.txt", isImage: false, messageID: "gram-same"),
            .init(name: "b.txt", isImage: false, messageID: "gram-same")
        ])
        let malformed = GramAttachmentPrompt.text("", delivered: [
            .init(name: "a.txt", isImage: false, messageID: "gram-foo;bar")
        ])
        XCTAssertNil(try turn(duplicate).attachmentPrompt)
        XCTAssertNil(try turn(malformed).attachmentPrompt)
    }
}
