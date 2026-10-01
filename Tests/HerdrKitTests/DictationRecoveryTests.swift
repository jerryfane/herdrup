import XCTest
@testable import HerdrKit

final class DictationRecoveryTests: XCTestCase {
    private var recovery = DictationRecovery()

    override func setUp() {
        recovery = DictationRecovery()
    }

    private func active(result: Bool = false, final: Bool = false, failed: Bool = false) -> DictationRecovery.Next {
        recovery.after(activeSegment: true, hasResult: result, isFinal: final, failed: failed)
    }

    private func retired(result: Bool = false, final: Bool = false, failed: Bool = false) -> DictationRecovery.Next {
        recovery.after(activeSegment: false, hasResult: result, isFinal: final, failed: failed)
    }

    func testActiveFinalStartsNextSegment() {
        XCTAssertEqual(active(result: true), .keepListening)
        XCTAssertEqual(active(result: true, final: true), .nextSegment)
    }

    /// A callback carrying a partial AND a fatal error ends the task: roll, rather than
    /// leave the segment waiting for results that never come.
    func testErrorWithResultRolls() {
        XCTAssertEqual(active(result: true, failed: true), .roll)
    }

    /// The third failure in a row stops dictation.
    func testThirdConsecutiveFailureStops() {
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(result: true, failed: true), .roll)
        XCTAssertEqual(active(failed: true), .stop)
    }

    /// A rolled segment's late final is not progress on the active task: it neither clears
    /// the strike count nor starts a segment.
    func testRetiredSegmentResultDoesNotClearStrikes() {
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(retired(result: true, final: true), .keepListening)
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(retired(result: true, final: true), .keepListening)
        XCTAssertEqual(active(failed: true), .stop)
    }

    func testRetiredSegmentErrorIsNotAStrike() {
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(retired(failed: true), .keepListening)
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(failed: true), .stop)
    }

    func testActiveResultClearsStrikes() {
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(result: true), .keepListening)
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(failed: true), .roll)
        XCTAssertEqual(active(failed: true), .stop)
    }
}
