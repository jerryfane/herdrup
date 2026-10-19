import XCTest
@testable import HerdrKit

/// The predicate that decides whether returning to the foreground reseeds the live
/// terminal. It replaced a scene-phase check that fired unconditionally, so the case
/// these tests exist for is the one that must NOT fire: a stream that stayed alive.
final class StreamLivenessTests: XCTestCase {
    private let stuckTimeout: TimeInterval = 50   // Coordinator.streamStuckTimeout

    /// THE MAC CASE, and the reason for the change. The process kept running while
    /// another Space was front, so the server's 20s ping kept landing. Nothing was
    /// missed, so a reseed would destroy a live terminal (and the reader's selection)
    /// to repair nothing.
    func testAStreamStillReceivingPingsIsNotStale() {
        let now = Date()
        let liveness = StreamLiveness(lastFrameAt: now.addingTimeInterval(-20))
        XCTAssertFalse(
            liveness.isStale(now: now, timeout: stuckTimeout),
            "a stream one ping-interval old is alive; reseeding it discards the reader's selection for no gain"
        )
    }

    /// THE IOS CASE, which must keep working: suspended for minutes, so output really
    /// was lost and the reseed is the honest repair (herdr#62).
    func testAStreamSilentPastTheStuckTimeoutIsStale() {
        let now = Date()
        let liveness = StreamLiveness(lastFrameAt: now.addingTimeInterval(-300))
        XCTAssertTrue(
            liveness.isStale(now: now, timeout: stuckTimeout),
            "five minutes of silence is a real gap and must still reseed"
        )
    }

    /// The boundary is the same number the reconnect watchdog uses, so a stream the
    /// watchdog would NOT yet act on must not be declared dead here either. Off-by-one
    /// in this direction is the destructive one: it reseeds a working pane.
    func testTheBoundaryIsExclusiveAtExactlyTheTimeout() {
        let now = Date()
        XCTAssertFalse(
            StreamLiveness(lastFrameAt: now.addingTimeInterval(-stuckTimeout))
                .isStale(now: now, timeout: stuckTimeout),
            "at exactly the timeout the watchdog has not reconnected yet, so this must not claim the stream is dead"
        )
        XCTAssertTrue(
            StreamLiveness(lastFrameAt: now.addingTimeInterval(-stuckTimeout - 1))
                .isStale(now: now, timeout: stuckTimeout),
            "one second past it is stale"
        )
    }

    /// A stream that has delivered nothing has no screen worth preserving, so the
    /// conservative answer costs the reader nothing. Pinned because the opposite default
    /// would silently skip the reseed on a pane that never connected.
    func testAStreamThatNeverDeliveredAFrameIsStale() {
        XCTAssertTrue(
            StreamLiveness().isStale(timeout: stuckTimeout),
            "no frame ever received must read as stale, not as healthy"
        )
    }

    /// The CALLER's timeout is the only threshold that decides. Pinned because the type's
    /// whole justification is that it carries no threshold of its own — if it did, it would
    /// drift from the reconnect watchdog the moment `streamStuckTimeout` were retuned, and
    /// nothing would fail. Review proved the gap: replacing `> timeout` with `> 50` left the
    /// suite green, because every other test passes exactly 50.
    func testTheCallersTimeoutIsTheOneThatDecides() {
        let now = Date()
        let liveness = StreamLiveness(lastFrameAt: now.addingTimeInterval(-30))
        XCTAssertFalse(
            liveness.isStale(now: now, timeout: stuckTimeout),
            "30s of silence is alive against the 50s watchdog threshold"
        )
        XCTAssertTrue(
            liveness.isStale(now: now, timeout: 20),
            "the same 30s must read stale against a 20s timeout; a hardcoded 50 would not"
        )
    }

    /// `noteFrame` is what the terminal calls on every frame; without it advancing, a
    /// long-lived pane would eventually look dead and reseed itself mid-session.
    func testNotingAFrameClearsPriorStaleness() {
        let now = Date()
        let liveness = StreamLiveness(lastFrameAt: now.addingTimeInterval(-300))
        XCTAssertTrue(liveness.isStale(now: now, timeout: stuckTimeout))
        liveness.noteFrame(at: now)
        XCTAssertEqual(liveness.lastFrameAt, now)
        XCTAssertFalse(
            liveness.isStale(now: now, timeout: stuckTimeout),
            "a fresh frame must make the stream live again"
        )
    }
}
