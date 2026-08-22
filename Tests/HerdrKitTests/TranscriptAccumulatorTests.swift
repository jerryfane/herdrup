import XCTest
@testable import HerdrKit

final class TranscriptAccumulatorTests: XCTestCase {
    func testEmptyStart() {
        let acc = TranscriptAccumulator()
        XCTAssertEqual(acc.committed, "")
        XCTAssertEqual(acc.text(withPartial: ""), "")
        XCTAssertEqual(acc.text(withPartial: "hello"), "hello")
    }

    func testCommitAccumulatesWithSingleSpaces() {
        var acc = TranscriptAccumulator()
        acc.commit("hello")
        XCTAssertEqual(acc.committed, "hello")
        XCTAssertEqual(acc.text(withPartial: "world"), "hello world")
        acc.commit("world")
        XCTAssertEqual(acc.committed, "hello world")
        XCTAssertEqual(acc.text(withPartial: ""), "hello world")
    }

    /// THE BUG THIS FIXES: once text is committed, a SHORTER partial (the recognizer
    /// re-segmenting near its ceiling) must not drop the earlier text.
    func testShorterPartialNeverLosesCommitted() {
        var acc = TranscriptAccumulator()
        acc.commit("one two three four five")
        // The recognizer's next window comes back as just "six" — the head must survive.
        let text = acc.text(withPartial: "six")
        XCTAssertEqual(text, "one two three four five six")
        XCTAssertTrue(text.hasPrefix(acc.committed), "output fell below committed")
        // An empty partial (a gap between segments) still returns everything committed.
        XCTAssertEqual(acc.text(withPartial: ""), "one two three four five")
    }

    func testPartialWhitespaceIsTrimmed() {
        var acc = TranscriptAccumulator()
        acc.commit("hi")
        XCTAssertEqual(acc.text(withPartial: "  there \n"), "hi there")
        // Committing a whitespace-only partial is a no-op.
        acc.commit("   ")
        XCTAssertEqual(acc.committed, "hi")
    }

    func testResetClears() {
        var acc = TranscriptAccumulator()
        acc.commit("something")
        acc.reset()
        XCTAssertEqual(acc.committed, "")
        XCTAssertEqual(acc.text(withPartial: "fresh"), "fresh")
    }
}
