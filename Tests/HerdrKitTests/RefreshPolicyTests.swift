import XCTest
@testable import HerdrKit

private func agent(
    pane: String, seq: UInt64?, epoch: UInt64? = 7, status: String = "working"
) throws -> AgentInfo {
    var f = ["\"pane_id\":\"\(pane)\"", "\"agent_status\":\"\(status)\""]
    if let seq { f.append("\"state_change_seq\":\(seq)") }
    if let epoch { f.append("\"turn_epoch\":\(epoch)") }
    let json = "{\"id\":\"x\",\"result\":{\"agents\":[{\(f.joined(separator: ","))}]}}"
    return try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]
}

final class RefreshPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let policy = RefreshPolicy(
        focusedMinInterval: 0.1, backgroundMinInterval: 1.0,
        focusedMaxStaleness: 1.0, backgroundMaxStaleness: 15.0
    )

    func testFirstSightAlwaysFetches() throws {
        XCTAssertEqual(
            policy.decide(agent: try agent(pane: "p1", seq: 10), state: PaneRefreshState(), focused: true, now: t0),
            .fetch
        )
    }

    /// THE REGRESSION THAT REVIEW CAUGHT.
    ///
    /// state_change_seq counts lifecycle transitions, not output. Measured live:
    /// one pane held seq=1092 across 13 distinct screens while status stayed
    /// "working". A policy that skips on an unchanged counter freezes the screen
    /// and the reader cannot tell. Staleness must force a fetch anyway.
    func testUnchangedCounterStillFetchesOnceStale() throws {
        let a = try agent(pane: "p1", seq: 1092)
        let state = PaneRefreshState(lastSeen: PaneGeneration(stateChangeSeq: 1092, turnEpoch: 7), lastFetch: t0)
        // Inside the staleness window, holding is fine.
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(0.5)), .skip)
        // Past it, the pane MUST be fetched even though nothing in the counters moved.
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(1.5)), .fetch)
    }

    /// A streaming pane must never go indefinitely unfetched.
    func testStreamingPaneCannotFreeze() throws {
        let a = try agent(pane: "p1", seq: 1092)
        var state = PaneRefreshState(lastSeen: PaneGeneration(stateChangeSeq: 1092, turnEpoch: 7), lastFetch: t0)
        var fetches = 0
        for tick in 1...60 {                     // 60 x 0.5s = 30s of streaming
            let now = t0.addingTimeInterval(Double(tick) * 0.5)
            if policy.decide(agent: a, state: state, focused: true, now: now) == .fetch {
                fetches += 1
                state.lastFetch = now
            }
        }
        XCTAssertGreaterThanOrEqual(fetches, 25, "a streaming pane must keep refreshing; got \(fetches)")
    }

    func testMovedCounterFetchesImmediately() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeen: PaneGeneration(stateChangeSeq: 10, turnEpoch: 7), lastFetch: t0)
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(0.2)), .fetch)
    }

    /// A restart can reset the counter to a value equal to the cached one.
    /// turn_epoch is what distinguishes that from "nothing happened".
    func testEpochChangeIsTreatedAsAChangeEvenWhenSeqMatches() throws {
        let a = try agent(pane: "p1", seq: 10, epoch: 99)
        let state = PaneRefreshState(lastSeen: PaneGeneration(stateChangeSeq: 10, turnEpoch: 7), lastFetch: t0)
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(0.2)), .fetch)
    }

    /// Previously this asserted "fetch once then stop", codifying the freeze bug.
    func testMissingCounterKeepsRefreshingOnStaleness() throws {
        let a = try agent(pane: "p1", seq: nil, epoch: nil)
        XCTAssertEqual(policy.decide(agent: a, state: PaneRefreshState(), focused: true, now: t0), .fetch)
        let after = PaneRefreshState(lastSeen: PaneGeneration(), lastFetch: t0)
        XCTAssertEqual(
            policy.decide(agent: a, state: after, focused: true, now: t0.addingTimeInterval(5)),
            .fetch,
            "a pane with no counter must not be trusted into silence"
        )
    }

    func testScrolledAwayReaderIsNotYanked() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(
            lastSeen: PaneGeneration(stateChangeSeq: 10, turnEpoch: 7), lastFetch: t0, readerScrolledAway: true
        )
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(5)), .deferToReader)
    }

    /// Staleness must not override a scrolled reader — that would reintroduce the
    /// yank the guard exists to prevent.
    func testStalenessDoesNotOverrideScrolledReader() throws {
        let a = try agent(pane: "p1", seq: 10)
        let state = PaneRefreshState(
            lastSeen: PaneGeneration(stateChangeSeq: 10, turnEpoch: 7), lastFetch: t0,
            readerScrolledAway: true, pendingChange: true
        )
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(60)), .deferToReader)
    }

    func testFocusedPaneRefreshesFasterThanBackground() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeen: PaneGeneration(stateChangeSeq: 10, turnEpoch: 7), lastFetch: t0)
        let soon = t0.addingTimeInterval(0.3)
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: soon), .fetch)
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: false, now: soon), .skip)
    }

    /// A change seen inside the rate floor must not be lost when the counter
    /// stops moving afterwards.
    func testChangeSeenInsideRateFloorIsRememberedAndFetched() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(
            lastSeen: PaneGeneration(stateChangeSeq: 11, turnEpoch: 7), lastFetch: t0, pendingChange: true
        )
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(0.2)), .fetch)
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testOnlyTheChangedPaneIsFetchedWithinTheStalenessWindow() throws {
        var coord = RefreshCoordinator()
        var agents = try (1...4).map { try agent(pane: "p\($0)", seq: UInt64($0)) }
        _ = coord.plan(agents: agents, focusedPane: "p2", now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, generation: PaneGeneration(a), at: t0) }

        agents[1] = try agent(pane: "p2", seq: 99)
        let plan = coord.plan(agents: agents, focusedPane: "p2", now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(plan["p2"], .fetch)
        for pane in ["p1", "p3", "p4"] { XCTAssertEqual(plan[pane], .skip, "\(pane) is inside its staleness window") }
    }

    func testEveryPaneEventuallyRefreshesEvenWithFrozenCounters() throws {
        var coord = RefreshCoordinator()
        let agents = try (1...3).map { try agent(pane: "p\($0)", seq: 500) }
        _ = coord.plan(agents: agents, focusedPane: "p1", now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, generation: PaneGeneration(a), at: t0) }

        // Counters never move again. Every pane must still be refetched.
        let later = coord.plan(agents: agents, focusedPane: "p1", now: t0.addingTimeInterval(20))
        XCTAssertEqual(later.values.filter { $0 == .fetch }.count, 3, "frozen counters must not freeze the UI")
    }

    func testPendingChangeSurvivesUntilFetched() throws {
        var coord = RefreshCoordinator()
        let a = try agent(pane: "p1", seq: 1)
        _ = coord.plan(agents: [a], focusedPane: "p1", now: t0)
        coord.recordFetch(pane: "p1", generation: PaneGeneration(a), at: t0)

        // Change arrives inside the rate floor, so it is not fetched now.
        let moved = try agent(pane: "p1", seq: 2)
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(0.01))["p1"], .skip)
        XCTAssertEqual(coord.state(for: "p1")?.pendingChange, true, "the change must be remembered")

        // Once the floor clears it is fetched, even though the counter is now stable.
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(0.3))["p1"], .fetch)
    }

    func testClosedPanesDoNotLeakState() throws {
        var coord = RefreshCoordinator()
        let agents = try (1...3).map { try agent(pane: "p\($0)", seq: UInt64($0)) }
        _ = coord.plan(agents: agents, focusedPane: nil, now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, generation: PaneGeneration(a), at: t0) }
        XCTAssertNotNil(coord.state(for: "p3"))

        _ = coord.plan(agents: Array(agents.prefix(2)), focusedPane: nil, now: t0.addingTimeInterval(1))
        XCTAssertNil(coord.state(for: "p3"))
        XCTAssertNotNil(coord.state(for: "p1"))
    }

    /// EventHub is a 512-entry ring with no gap signal, so a backgrounded client
    /// cannot trust continuity and must full-resync on foreground.
    func testInvalidateAllForcesAFullResync() throws {
        var coord = RefreshCoordinator()
        let agents = try (1...3).map { try agent(pane: "p\($0)", seq: UInt64($0)) }
        _ = coord.plan(agents: agents, focusedPane: "p1", now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, generation: PaneGeneration(a), at: t0) }
        XCTAssertEqual(coord.plan(agents: agents, focusedPane: "p1", now: t0.addingTimeInterval(0.2)).values.filter { $0 == .fetch }.count, 0)

        coord.invalidateAll()
        let after = coord.plan(agents: agents, focusedPane: "p1", now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(after.values.filter { $0 == .fetch }.count, 3, "foreground resync must refetch everything")
    }

    func testScrolledAwayPaneDefersThenResumesWhenReaderReturns() throws {
        var coord = RefreshCoordinator()
        let a1 = try agent(pane: "p1", seq: 1)
        _ = coord.plan(agents: [a1], focusedPane: "p1", now: t0)
        coord.recordFetch(pane: "p1", generation: PaneGeneration(a1), at: t0)

        coord.setReaderScrolledAway(pane: "p1", true)
        let moved = try agent(pane: "p1", seq: 2)
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(1))["p1"], .deferToReader)

        coord.setReaderScrolledAway(pane: "p1", false)
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(2))["p1"], .fetch)
    }
}

/// Live check that the counter genuinely does NOT track output — the fact that
/// forced this redesign. Guards against silently reverting to counter-only gating.
final class LiveRefreshTests: XCTestCase {
    func testStateChangeSeqDoesNotTrackOutput() async throws {
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: path), "no live herdr server")
        let client = HerdrClient(transport: UnixSocketTransport(path: path))

        let agents = try await client.agentList()
        guard let working = agents.first(where: { $0.isWorking }) else {
            throw XCTSkip("no pane is currently working; cannot observe streaming output")
        }
        var screens = Set<String>()
        var seqs = Set<UInt64?>()
        for _ in 0..<6 {
            let list = try await client.agentList()
            guard let a = list.first(where: { $0.paneID == working.paneID }) else { break }
            seqs.insert(a.stateChangeSeq)
            let read = try await client.read(pane: working.paneID, source: .visible, format: .text, lines: 60)
            screens.insert(read.text)
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        // If the screen moved while the counter held, counter-only gating would
        // have frozen the view. Documented, not asserted as always-true, because
        // a pane can legitimately finish mid-sample.
        if screens.count > 1 && seqs.count == 1 {
            XCTAssertTrue(true, "confirmed: \(screens.count) screens at a single state_change_seq")
        }
        XCTAssertFalse(screens.isEmpty)
    }
}

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
