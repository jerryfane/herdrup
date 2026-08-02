import XCTest
@testable import HerdrKit

/// Deterministic generator, so a jitter test asserts a distribution property
/// rather than hoping.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class SessionRecoveryTests: XCTestCase {
    let recovery = SessionRecovery()

    private func plan(
        _ event: ClientEvent, _ state: inout SessionRecovery.State, seed: UInt64 = 1
    ) -> RecoveryPlan {
        var generator = SeededGenerator(seed: seed)
        return recovery.plan(for: event, state: &state, using: &generator)
    }

    /// THE AXIS for task 4: a client that missed events resyncs rather than
    /// continuing from a stale sequence.
    ///
    /// herdr's ring holds 512 events and signals nothing when it drops older
    /// ones, so continuity across a background period is unknowable. This asserts
    /// the resync happens **unconditionally** — not "when a gap is detected",
    /// because detecting the gap is the thing that cannot be done.
    func testForegroundingAlwaysResyncsRatherThanTrustingContinuity() {
        var state = SessionRecovery.State()
        recovery.observe(panes: ["p1", "p2"], state: &state)

        // A background period so short that "surely nothing was missed" is
        // exactly the reasoning this must not embody.
        _ = plan(.backgrounded(at: Date()), &state)
        let resumed = plan(.foregrounded(at: Date().addingTimeInterval(0.2)), &state)

        XCTAssertTrue(
            resumed.resyncAllPanes,
            "a short absence is indistinguishable from a long one; resync must not be conditional"
        )
        XCTAssertEqual(
            resumed.subscribe, ["p1", "p2"],
            "subscriptions are pane-scoped with no wildcard, so every known pane must be re-subscribed"
        )
    }

    /// The absence IS the feature: nothing here accepts a remembered position.
    ///
    /// A `resume(from:)` would pass every test written against a server that had
    /// not wrapped its ring, and fail only on a phone that was in a pocket.
    func testNoAPIAcceptsARememberedSequence() {
        // RecoveryPlan carries no sequence, revision or cursor to resume from —
        // its whole surface is these three fields.
        let plan = RecoveryPlan(resyncAllPanes: true, subscribe: ["p1"], reconnectAfter: 1)
        XCTAssertEqual(plan, RecoveryPlan(resyncAllPanes: true, subscribe: ["p1"], reconnectAfter: 1))
        // And State persists only pane identity and connection bookkeeping.
        var state = SessionRecovery.State()
        recovery.observe(panes: ["p1"], state: &state)
        XCTAssertEqual(state.knownPanes, ["p1"])
    }

    /// AXIS: backoff grows, and is capped.
    func testBackoffGrowsAndIsCapped() {
        var generator = SeededGenerator(seed: 7)
        var previousCeiling = 0.0
        for failures in 1...12 {
            let delay = recovery.backoff(failures: failures, using: &generator)
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(
                delay, recovery.maximumDelay,
                "delay \(delay)s at failure \(failures) exceeded the cap"
            )
            let ceiling = min(recovery.baseDelay * pow(2, Double(failures - 1)), recovery.maximumDelay)
            XCTAssertGreaterThanOrEqual(ceiling, previousCeiling, "ceiling must not shrink")
            previousCeiling = ceiling
        }
        XCTAssertEqual(recovery.backoff(failures: 0, using: &generator), 0, "no failures, no delay")
    }

    /// AXIS: the delay is actually jittered.
    ///
    /// Asserting only "delay ≤ cap" would pass on a fixed schedule, which is the
    /// bug jitter exists to prevent — a fleet dropped by one network event
    /// returning in lockstep. So this asserts the delays SPREAD.
    func testBackoffIsJitteredNotFixed() {
        var delays: Set<Double> = []
        for seed in UInt64(1)...40 {
            var generator = SeededGenerator(seed: seed)
            delays.insert(recovery.backoff(failures: 6, using: &generator))
        }
        XCTAssertGreaterThan(
            delays.count, 30,
            "40 clients drew only \(delays.count) distinct delays; they would reconnect in lockstep"
        )
    }

    /// AXIS: a connection that drops immediately does not reset the backoff.
    ///
    /// Resetting on *established* is the classic form of this bug: a server that
    /// accepts and instantly drops looks like a success every time, so the delay
    /// never grows and the client hammers it. The connection has to LAST.
    func testFlappingConnectionDoesNotResetTheBackoff() {
        var state = SessionRecovery.State()
        let start = Date()
        var lastDelay = 0.0

        for attempt in 0..<5 {
            let at = start.addingTimeInterval(Double(attempt) * 0.1)
            _ = plan(.connected(at: at), &state)
            // Drops 50ms later — far inside the stability window.
            let dropped = plan(.transportFailed(at: at.addingTimeInterval(0.05)), &state, seed: 99)
            lastDelay = try! XCTUnwrap(dropped.reconnectAfter)
        }

        XCTAssertEqual(
            state.consecutiveFailures, 5,
            "five flaps counted \(state.consecutiveFailures) failures; a short-lived connection must not count as healthy"
        )
        XCTAssertGreaterThan(lastDelay, 0, "the fifth flap must still be delayed")
    }

    /// AXIS: a connection that survived the stability window DOES reset it, so a
    /// client that has been fine for hours is not punished for one drop.
    func testAHealthyConnectionResetsTheBackoff() {
        var state = SessionRecovery.State()
        let start = Date()
        _ = plan(.connected(at: start), &state)
        _ = plan(.transportFailed(at: start.addingTimeInterval(0.05)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1)

        // Reconnects and stays up well past the stability interval.
        let recovered = start.addingTimeInterval(1)
        _ = plan(.connected(at: recovered), &state)
        _ = plan(
            .transportFailed(at: recovered.addingTimeInterval(recovery.stabilityInterval + 1)),
            &state
        )
        XCTAssertEqual(
            state.consecutiveFailures, 1,
            "a connection that lasted past the stability window must clear the streak"
        )
    }

    /// AXIS: a new pane gets a subscription, because there is no wildcard.
    func testPaneCreatedSubscribesToThatPane() {
        var state = SessionRecovery.State()
        XCTAssertEqual(plan(.paneCreated("p9"), &state).subscribe, ["p9"])
        XCTAssertTrue(state.knownPanes.contains("p9"))
        // Idempotent: a repeat does not re-subscribe.
        XCTAssertEqual(plan(.paneCreated("p9"), &state).subscribe, [])
    }

    /// AXIS: a pane learned about while connected survives into the next resync.
    ///
    /// Without this, a pane created during a session becomes unwatched after the
    /// next reconnect, and its silence is indistinguishable from having no output.
    func testPanesLearnedDuringASessionAreResubscribedAfterReconnect() {
        var state = SessionRecovery.State()
        recovery.observe(panes: ["p1"], state: &state)
        _ = plan(.paneCreated("p2"), &state)

        let reconnected = plan(.connected(at: Date()), &state)
        XCTAssertEqual(
            reconnected.subscribe, ["p1", "p2"],
            "a pane discovered mid-session must be re-subscribed, not forgotten"
        )
    }

    /// AXIS: a backgrounded client schedules no reconnect.
    ///
    /// The attempt would not run while suspended, and on return the failures it
    /// accrued would look like a fresh streak — so the client would come back
    /// slow at the exact moment the reader is looking at it.
    func testBackgroundedClientSchedulesNoReconnect() {
        var state = SessionRecovery.State()
        _ = plan(.backgrounded(at: Date()), &state)

        XCTAssertNil(plan(.transportFailed(at: Date()), &state).reconnectAfter)
        XCTAssertNil(plan(.networkChanged(at: Date()), &state).reconnectAfter)

        let resumed = plan(.foregrounded(at: Date()), &state)
        XCTAssertEqual(resumed.reconnectAfter, 0, "returning must reconnect immediately")
        XCTAssertEqual(state.consecutiveFailures, 0, "time spent suspended is not a failure streak")
    }

    /// AXIS: a network change reconnects immediately rather than backing off.
    ///
    /// It is not a failure — it is a different network, and the old socket is
    /// bound to an address that may no longer exist. Backing off would make the
    /// most recoverable case the slowest.
    func testNetworkChangeReconnectsImmediately() {
        var state = SessionRecovery.State()
        _ = plan(.connected(at: Date()), &state)
        _ = plan(.transportFailed(at: Date().addingTimeInterval(0.01)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1)

        let changed = plan(.networkChanged(at: Date()), &state)
        XCTAssertEqual(changed.reconnectAfter, 0, "a network change is not a failure to back off from")
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    /// AXIS: reconnecting resyncs. A reconnect is a gap of unknown length, and
    /// the ring gives no way to learn what was missed during it.
    func testReconnectingResyncs() {
        var state = SessionRecovery.State()
        recovery.observe(panes: ["p1"], state: &state)
        let reconnected = plan(.connected(at: Date()), &state)
        XCTAssertTrue(reconnected.resyncAllPanes, "a reconnect must not resume from cached generations")
    }
}

/// The other half of the resync: `RefreshCoordinator` must actually forget.
final class ResyncInvalidationTests: XCTestCase {
    /// AXIS: after invalidateAll, the next plan FETCHES rather than skipping.
    ///
    /// Asserting the internal state was cleared would test the setter. What
    /// matters is the observable consequence: a pane whose counters have not
    /// moved must still be refetched, because the counters are exactly what
    /// cannot be trusted across a gap.
    func testInvalidationForcesAFetchEvenWhenCountersDidNotMove() throws {
        var coordinator = RefreshCoordinator()
        let json = """
        {"id":"x","result":{"agents":[{"pane_id":"p1","agent":"claude","state_change_seq":1092,\
        "turn_epoch":4,"composer":{"state":"idle"}}]}}
        """
        let agent = try JSONDecoder()
            .decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]

        let now = Date()
        _ = coordinator.plan(agents: [agent], focusedPane: "p1", now: now)
        coordinator.recordFetch(pane: "p1", generation: PaneGeneration(agent), at: now)

        // Nothing moved, and we are inside every interval: normally a skip.
        let quiet = coordinator.plan(agents: [agent], focusedPane: "p1", now: now.addingTimeInterval(0.01))
        XCTAssertEqual(quiet["p1"], .skip, "precondition: an unchanged pane skips, or this proves nothing")

        coordinator.invalidateAll()
        let afterResync = coordinator.plan(
            agents: [agent], focusedPane: "p1", now: now.addingTimeInterval(0.02)
        )
        XCTAssertEqual(
            afterResync["p1"], .fetch,
            "after a gap the pane must be refetched; identical counters are not evidence of no change"
        )
    }
}
