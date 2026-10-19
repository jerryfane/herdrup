import XCTest
@testable import HerdrKit

/// `GramFile.downloadedLabel`, the "<done> of <size>" line the owner feed and the Saved list
/// show while an attachment downloads.
final class GramFileLabelTests: XCTestCase {
    func testNoMeasurementGivesNoLabel() {
        XCTAssertNil(GramFile.downloadedLabel(received: 4096, total: 0, fileSize: 3072))
    }

    /// The reply is base64, so the received wire bytes are scaled by 3/4 to name file bytes.
    func testReceivedWireBytesAreScaledToFileBytes() {
        XCTAssertEqual(GramFile.downloadedLabel(received: 4096, total: 1_398_101, fileSize: 1_048_576),
                       "3 KB of 1.0 MB")
        XCTAssertEqual(GramFile.downloadedLabel(received: 800, total: 2000, fileSize: 1200),
                       "600 B of 1 KB")
    }

    /// The JSON envelope pushes the wire past 4/3 of the file; the label never passes the size.
    func testDoneIsCappedAtTheFileSize() {
        XCTAssertEqual(GramFile.downloadedLabel(received: 2000, total: 2000, fileSize: 1000),
                       "1000 B of 1000 B")
    }
}
