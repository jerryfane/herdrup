import XCTest
@testable import HerdrKit

/// Builds an AgentInfo without a live server. Decoding keeps the test honest:
/// if the wire shape changes, these fixtures stop compiling into valid agents.
private func agent(pane: String, seq: Int64?, status: String = "working") throws -> AgentInfo {
    let seqField = seq.map { "\"state_change_seq\":\($0)," } ?? ""
    let json = """
    {"id":"x","result":{"agents":[{"pane_id":"\(pane)",\(seqField)"agent_status":"\(status)"}]}}
    """
    let env = try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8))
    return env.result.agents[0]
}

final class RefreshPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let policy = RefreshPolicy(focusedMinInterval: 0.1, backgroundMinInterval: 1.0)

    func testFirstSightAlwaysFetches() throws {
        let a = try agent(pane: "p1", seq: 10)
        XCTAssertEqual(
            policy.decide(agent: a, state: PaneRefreshState(), focused: true, now: t0),
            .fetch
        )
    }

    /// The core of revision gating: an unchanged sequence costs nothing.
    func testUnchangedSequenceSkips() throws {
        let a = try agent(pane: "p1", seq: 10)
        let state = PaneRefreshState(lastSeenSeq: 10, lastFetch: t0)
        XCTAssertEqual(
            policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(60)),
            .skip
        )
    }

    func testChangedSequenceFetches() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeenSeq: 10, lastFetch: t0)
        XCTAssertEqual(
            policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(1)),
            .fetch
        )
    }

    /// Readability: never replace the screen under a reader who scrolled back.
    func testScrolledAwayReaderIsNotYanked() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeenSeq: 10, lastFetch: t0, readerScrolledAway: true)
        XCTAssertEqual(
            policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(5)),
            .deferToReader
        )
    }

    func testFocusedPaneRefreshesFasterThanBackground() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeenSeq: 10, lastFetch: t0)
        let soon = t0.addingTimeInterval(0.3)   // past focused floor, inside background floor
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: true, now: soon), .fetch)
        XCTAssertEqual(policy.decide(agent: a, state: state, focused: false, now: soon), .skip)
    }

    func testRateLimitHoldsEvenWhenContentChanged() throws {
        let a = try agent(pane: "p1", seq: 11)
        let state = PaneRefreshState(lastSeenSeq: 10, lastFetch: t0)
        // 50ms after a fetch, below the 100ms focused floor.
        XCTAssertEqual(
            policy.decide(agent: a, state: state, focused: true, now: t0.addingTimeInterval(0.05)),
            .skip
        )
    }

    /// A server that omits state_change_seq must still render once, not never.
    func testMissingSequenceFetchesOnceThenStops() throws {
        let a = try agent(pane: "p1", seq: nil)
        XCTAssertEqual(policy.decide(agent: a, state: PaneRefreshState(), focused: true, now: t0), .fetch)
        let after = PaneRefreshState(lastSeenSeq: nil, lastFetch: t0)
        XCTAssertEqual(policy.decide(agent: a, state: after, focused: true, now: t0.addingTimeInterval(9)), .skip)
    }
}

final class RefreshCoordinatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testIdleFleetCostsNoReadsAfterFirstPass() throws {
        var coord = RefreshCoordinator()
        let agents = try (1...5).map { try agent(pane: "p\($0)", seq: Int64(100 + $0)) }

        let first = coord.plan(agents: agents, focusedPane: "p1", now: t0)
        XCTAssertEqual(first.values.filter { $0 == .fetch }.count, 5, "every pane renders once")
        for a in agents { coord.recordFetch(pane: a.paneID, seq: a.stateChangeSeq, at: t0) }

        // Nothing moved. A second pass must fetch nothing at all — this is what
        // makes watching many agents cheap over a slow link.
        let second = coord.plan(agents: agents, focusedPane: "p1", now: t0.addingTimeInterval(30))
        XCTAssertEqual(second.values.filter { $0 == .fetch }.count, 0)
        XCTAssertTrue(second.values.allSatisfy { $0 == .skip })
    }

    func testOnlyTheChangedPaneIsFetched() throws {
        var coord = RefreshCoordinator()
        var agents = try (1...4).map { try agent(pane: "p\($0)", seq: Int64($0)) }
        _ = coord.plan(agents: agents, focusedPane: "p2", now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, seq: a.stateChangeSeq, at: t0) }

        agents[1] = try agent(pane: "p2", seq: 99)   // only p2 moved
        let plan = coord.plan(agents: agents, focusedPane: "p2", now: t0.addingTimeInterval(5))
        XCTAssertEqual(plan["p2"], .fetch)
        for pane in ["p1", "p3", "p4"] { XCTAssertEqual(plan[pane], .skip, "\(pane) should be untouched") }
    }

    func testClosedPanesDoNotLeakState() throws {
        var coord = RefreshCoordinator()
        let agents = try (1...3).map { try agent(pane: "p\($0)", seq: Int64($0)) }
        _ = coord.plan(agents: agents, focusedPane: nil, now: t0)
        for a in agents { coord.recordFetch(pane: a.paneID, seq: a.stateChangeSeq, at: t0) }
        XCTAssertNotNil(coord.state(for: "p3"))

        let survivors = Array(agents.prefix(2))
        _ = coord.plan(agents: survivors, focusedPane: nil, now: t0.addingTimeInterval(1))
        XCTAssertNil(coord.state(for: "p3"), "state for a closed pane must be dropped")
        XCTAssertNotNil(coord.state(for: "p1"))
    }

    func testScrolledAwayPaneDefersThenResumesWhenReaderReturns() throws {
        var coord = RefreshCoordinator()
        let a1 = try agent(pane: "p1", seq: 1)
        _ = coord.plan(agents: [a1], focusedPane: "p1", now: t0)
        coord.recordFetch(pane: "p1", seq: 1, at: t0)

        coord.setReaderScrolledAway(pane: "p1", true)
        let moved = try agent(pane: "p1", seq: 2)
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(1))["p1"], .deferToReader)

        coord.setReaderScrolledAway(pane: "p1", false)
        XCTAssertEqual(coord.plan(agents: [moved], focusedPane: "p1", now: t0.addingTimeInterval(2))["p1"], .fetch)
    }
}

/// Exercises the policy against sequences observed from the real server.
final class LiveRefreshTests: XCTestCase {
    func testRealFleetIsMostlyIdleUnderRevisionGating() async throws {
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: path), "no live herdr server")

        let client = HerdrClient(transport: UnixSocketTransport(path: path))
        var coord = RefreshCoordinator()

        let first = try await client.agentList()
        XCTAssertFalse(first.isEmpty)
        let now = Date()
        let plan1 = coord.plan(agents: first, focusedPane: first.first?.paneID, now: now)
        XCTAssertEqual(plan1.values.filter { $0 == .fetch }.count, first.count)
        for a in first { coord.recordFetch(pane: a.paneID, seq: a.stateChangeSeq, at: now) }

        // Immediately re-plan against a second real snapshot. On a live fleet a
        // few panes may genuinely have moved, but the great majority must not,
        // which is the property that makes polling affordable.
        let second = try await client.agentList()
        let plan2 = coord.plan(agents: second, focusedPane: second.first?.paneID, now: now.addingTimeInterval(0.2))
        let fetches = plan2.values.filter { $0 == .fetch }.count
        XCTAssertLessThan(
            fetches, max(2, second.count / 2),
            "revision gating should suppress most reads back-to-back; fetched \(fetches)/\(second.count)"
        )
    }
}
