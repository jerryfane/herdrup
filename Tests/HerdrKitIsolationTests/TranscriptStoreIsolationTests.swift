import XCTest
import HerdrKit

/// `TranscriptStore.pageTurns` is the init's default argument, which the caller evaluates
/// in its own context: it has to be readable off the main actor. This target builds with
/// warnings as errors, so a main-actor-isolated constant fails to compile here.
final class TranscriptStoreIsolationTests: XCTestCase {
    func testPageTurnsIsReadableOffTheMainActor() {
        XCTAssertEqual(TranscriptStore.pageTurns, 20)
    }
}
