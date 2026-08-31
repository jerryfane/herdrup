import Foundation
import XCTest
@testable import HerdrKit

final class AgentRosterRefreshStateTests: XCTestCase {
    private func agent(pane: String, status: String, name: String? = nil) throws -> AgentInfo {
        var object: [String: Any] = ["pane_id": pane, "agent_status": status]
        if let name { object["name"] = name }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    private func account(id: String, label: String) throws -> CredentialAccount {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "kind": "claude", "label": label, "active": true,
        ])
        return try JSONDecoder().decode(CredentialAccount.self, from: data)
    }

    private func snapshot(
        status: String,
        name: String = "jarvis",
        accountLabel: String = "work"
    ) throws -> AgentRosterSnapshot {
        AgentRosterSnapshot(
            agents: [try agent(pane: "w1:p1", status: status, name: name)],
            accounts: [try account(id: "acc-1", label: accountLabel)]
        )
    }

    func testIdenticalRefreshIsACompleteNoOp() throws {
        let original = try snapshot(status: "working")
        let state = AgentRosterRefreshState(displayed: original)

        XCTAssertEqual(state.receiving(original), state)
    }

    func testChangedRefreshAppliesImmediatelyWhileIdle() throws {
        let original = try snapshot(status: "working")
        let changed = try snapshot(status: "blocked")
        let result = AgentRosterRefreshState(displayed: original).receiving(changed)

        XCTAssertEqual(result.displayed, changed)
        XCTAssertNil(result.pending)
    }

    func testScrollingCoalescesToNewestRefreshThenAppliesItOnce() throws {
        let original = try snapshot(status: "working")
        let first = try snapshot(status: "blocked")
        let newest = try snapshot(status: "idle", name: "jarvis-new")
        var state = AgentRosterRefreshState(displayed: original).settingScrolling(true)

        state = state.receiving(first)
        state = state.receiving(newest)
        XCTAssertEqual(state.displayed, original, "scrolling must not rearrange visible rows")
        XCTAssertEqual(state.pending, newest, "only the newest fetched roster is retained")

        let settled = state.settingScrolling(false)
        XCTAssertEqual(settled.displayed, newest)
        XCTAssertNil(settled.pending)
        XCTAssertFalse(settled.isScrolling)
        XCTAssertEqual(settled.settingScrolling(false), settled, "an idle callback must not republish")
    }

    func testReturningToDisplayedStateClearsPendingChange() throws {
        let original = try snapshot(status: "working")
        let changed = try snapshot(status: "blocked")
        var state = AgentRosterRefreshState(displayed: original).settingScrolling(true)

        state = state.receiving(changed)
        XCTAssertEqual(state.pending, changed)
        state = state.receiving(original)
        XCTAssertNil(state.pending, "the newest server response wins, even when it returns to the displayed state")
        XCTAssertEqual(state.settingScrolling(false).displayed, original)
    }

    func testLatestPreservesPendingAccountDataAcrossBestEffortFailure() throws {
        let original = try snapshot(status: "working", accountLabel: "old")
        let changed = try snapshot(status: "blocked", accountLabel: "new")
        let state = AgentRosterRefreshState(displayed: original)
            .settingScrolling(true)
            .receiving(changed)

        XCTAssertEqual(state.latest.accounts.first?.label, "new")
        XCTAssertEqual(state.displayed.accounts.first?.label, "old")
    }

    func testSnapshotCachesTheDerivedListAndLiveness() throws {
        let live = try agent(pane: "w1:p1", status: "working")
        let stopped = try agent(pane: "w1:p2", status: "working")
        let roster = AgentRosterSnapshot(
            agents: [live, stopped],
            livePaneIDs: ["w1:p1"]
        )

        XCTAssertEqual(roster.agentList.rows.map(\.group), [.stopped, .working])
        XCTAssertEqual(roster.agentList.rows.first?.info.paneID, "w1:p2")
    }

    func testStaleLoadCannotClearANewerPendingRoster() throws {
        let old = try snapshot(status: "working", name: "old")
        let new = try snapshot(status: "blocked", name: "new")
        var gate = AgentRosterLoadGate()
        let stalledRequest = gate.begin()
        let newerRequest = gate.begin()
        var state = AgentRosterRefreshState(displayed: old).settingScrolling(true)

        if gate.accepts(newerRequest) { state = state.receiving(new) }
        // The stalled request carries the scroll-start snapshot. Without the gate,
        // receiving(old) would clear the newer pending value because old == displayed.
        if gate.accepts(stalledRequest) { state = state.receiving(old) }

        XCTAssertEqual(state.pending, new)
        XCTAssertEqual(state.settingScrolling(false).displayed, new)
        XCTAssertFalse(gate.accepts(stalledRequest))
        XCTAssertTrue(gate.accepts(newerRequest))
    }
}
