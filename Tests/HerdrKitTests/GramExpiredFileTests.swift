import XCTest
@testable import HerdrKit

/// herdr#298: when the store's attachment budget expires a message's file, the daemon keeps
/// the message and sends `expired_file` (the file's metadata) in place of `file`. Older
/// daemons never send it.
final class GramExpiredFileTests: XCTestCase {
    private func decode(_ extra: String, text: String = "") throws -> GramMessage {
        let json = #"{"id":"g1","direction":"agent_to_owner","from":"vetrina","text":"\#(text)","created_unix_ms":1750000000000,"read_by_owner":true\#(extra)}"#
        return try JSONDecoder().decode(GramMessage.self, from: Data(json.utf8))
    }

    private let expired = #","expired_file":{"name":"chart.png","size":873472,"mime":"image/png","sha256":"18ce5c6f97913baa79fe27d910e2f8be0f57ca89104e1ebda73840653e30be7b"}"#
    private let live = #","file":{"name":"report.zip","size":1024,"mime":"application/zip","sha256":"3d5e7f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c"}"#

    func testAnExpiredFileDecodesAsMetadataOnly() throws {
        let message = try decode(expired)
        XCTAssertNil(message.file, "an expired file is never a file to open")
        let file = try XCTUnwrap(message.expiredFile)
        XCTAssertEqual(file.name, "chart.png")
        XCTAssertEqual(file.size, 873472)
        XCTAssertEqual(file.mime, "image/png")
        XCTAssertEqual(file.sha256, "18ce5c6f97913baa79fe27d910e2f8be0f57ca89104e1ebda73840653e30be7b")
        XCTAssertEqual(message.attachmentPreview, "chart.png (expired)")
    }

    func testAbsentExpiredFileStaysNil() throws {
        let plain = try decode("", text: "hi")
        XCTAssertNil(plain.file)
        XCTAssertNil(plain.expiredFile)
        XCTAssertNil(plain.attachmentPreview)

        let withFile = try decode(live)
        XCTAssertEqual(withFile.file?.name, "report.zip")
        XCTAssertNil(withFile.expiredFile)
        XCTAssertEqual(withFile.attachmentPreview, "report.zip")
    }

    /// The daemon sends one or the other; a message carrying both is still one openable
    /// file, never also drawn as expired.
    func testAFileAndAnExpiredFileAreNeverBothOpenable() throws {
        let both = try decode(live + expired)
        XCTAssertEqual(both.file?.name, "report.zip")
        XCTAssertNil(both.expiredFile, "a message with bytes is not also expired")
        XCTAssertEqual(both.attachmentPreview, "report.zip")
    }
}
