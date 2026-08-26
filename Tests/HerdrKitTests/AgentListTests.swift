import XCTest
@testable import HerdrKit

final class AgentListTests: XCTestCase {

    // MARK: - fixtures

    /// Builds an AgentInfo through the decoder, so these tests exercise the same
    /// path the wire does. Constructing it in memory would let a test pass while
    /// the JSON key was wrong.
    private func agent(
        pane: String, status: String?, name: String? = nil, completedUnixMs: Int64? = nil,
        archivedBy: String? = nil, archivedAt: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        if let completedUnixMs { obj["last_completed_turn"] = ["completed_unix_ms": completedUnixMs] }
        if let archivedBy {
            obj["archived"] = ["at": archivedAt ?? "2026-08-26T18:00:00Z", "by": archivedBy]
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    // MARK: - archived agents (issue #173)

    /// The `archived` block decodes through the wire path and drives `isArchived`.
    /// An agent with no block is active. Building the JSON keeps the keys honest.
    func testArchivedBlockDecodesAndDrivesIsArchived() throws {
        let archived = try agent(pane: "p1", status: "idle", name: "huurjacht",
                                 archivedBy: "jerry", archivedAt: "2026-08-26T18:00:00Z")
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.archived?.by, "jerry")
        XCTAssertEqual(archived.archived?.at, "2026-08-26T18:00:00Z")
        let active = try agent(pane: "p2", status: "idle")
        XCTAssertFalse(active.isArchived)
        XCTAssertNil(active.archived)
    }

    /// Archived agents are pulled OUT of the live status sections and collected in
    /// `archived` (most-recently-archived first), and never counted toward needsYou.
    func testArchivedAgentsPartitionOutOfLiveSections() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "blocked"),                                  // live, needsYou
            try agent(pane: "p2", status: "idle", name: "old", archivedBy: "a", archivedAt: "2026-08-26T10:00:00Z"),
            try agent(pane: "p3", status: "idle", name: "new", archivedBy: "b", archivedAt: "2026-08-26T20:00:00Z"),
        ])
        // Live sections/rows exclude the two archived agents.
        XCTAssertEqual(list.rows.map(\.info.paneID), ["p1"])
        XCTAssertFalse(list.rows.contains { $0.info.isArchived })
        XCTAssertEqual(list.needsYouCount, 1)
        // Archived collected separately, most-recently-archived first.
        XCTAssertEqual(list.archived.map(\.info.paneID), ["p3", "p2"])
    }

    /// Within a group, order is most-recently-active first (largest
    /// completed_unix_ms), then agents with no completed turn, with paneID as the
    /// stable final tiebreak. paneIDs are chosen so recency — not paneID — decides.
    func testWithinGroupSortsByMostRecentlyActive() throws {
        let list = AgentList(agents: [
            try agent(pane: "p3", status: "working", completedUnixMs: 100),   // older
            try agent(pane: "p1", status: "working", completedUnixMs: 900),   // newest
            try agent(pane: "p2", status: "working", completedUnixMs: nil),   // never ran
        ])
        let working = list.rows.filter { $0.group == .working }.map(\.info.paneID)
        XCTAssertEqual(working, ["p1", "p3", "p2"],
                       "expected most-recent-first (p1=900, then p3=100), no-timestamp last (p2) "
                       + "— not paneID order p1<p2<p3")
    }

    // MARK: - federation fields (daemon W3+)

    /// A remote agent carries machine_id / reachability / last_known_status; they
    /// decode through the same wire path, and only an `unreachable` agent surfaces
    /// as offline. A local agent leaves them nil and is never offline. Building the
    /// JSON keeps the keys honest — a wrong CodingKey would fail these.
    func testFederationFieldsDecodeAndDriveOffline() throws {
        let remote = try JSONDecoder().decode(
            AgentInfo.self,
            from: JSONSerialization.data(withJSONObject: [
                "pane_id": "mcb-air/w1:p2",
                "name": "mcb-air/build",
                "agent_status": "idle",
                "machine_id": "mcb-air",
                "reachability": "unreachable",
                "last_known_status": "working",
            ]))
        XCTAssertEqual(remote.machineID, "mcb-air")
        XCTAssertEqual(remote.reachability, "unreachable")
        XCTAssertEqual(remote.lastKnownStatus, "working")
        XCTAssertTrue(remote.isUnreachable, "an unreachable agent must read as offline")

        // A local agent has none of the federation fields, and is not offline.
        let local = try agent(pane: "p1", status: "working")
        XCTAssertNil(local.machineID)
        XCTAssertNil(local.reachability)
        XCTAssertNil(local.lastKnownStatus)
        XCTAssertFalse(local.isUnreachable)

        // Only "unreachable" is offline; reachable/degraded and any unknown newer
        // value are treated as reachable (the safe default is "not offline").
        for value in ["reachable", "degraded", "some_future_state"] {
            let a = try JSONDecoder().decode(
                AgentInfo.self,
                from: JSONSerialization.data(withJSONObject: ["pane_id": "x", "reachability": value]))
            XCTAssertFalse(a.isUnreachable, "reachability=\(value) must not read as offline")
        }
    }

    // MARK: - the three ways of not knowing

    /// AXIS: absent, indefinite and unrecognised are three different situations
    /// and the type refuses to merge them.
    ///
    /// Asserting only "none of them is .blocked" would pass against a mapping
    /// that collapsed all three into one case, which is the defect. Each is
    /// therefore pinned to its own value AND checked to differ from the others.
    func testTheThreeUnknownsAreDistinct() {
        let absent = AgentStatus(wire: nil)
        let indefinite = AgentStatus(wire: "unknown")
        let unrecognised = AgentStatus(wire: "waiting_approval")

        XCTAssertEqual(absent, .absent)
        XCTAssertEqual(indefinite, .indefinite)
        XCTAssertEqual(unrecognised, .unrecognised("waiting_approval"))

        XCTAssertNotEqual(absent, indefinite, "absent and indefinite collapsed into one case")
        XCTAssertNotEqual(indefinite, unrecognised, "indefinite and unrecognised collapsed into one case")
        XCTAssertNotEqual(absent, unrecognised, "absent and unrecognised collapsed into one case")
    }

    /// The unrecognised payload is carried verbatim, not normalised or dropped.
    /// Without this, `.unrecognised("")` would satisfy the test above and the
    /// diagnostic value — knowing WHICH unknown state arrived — would be gone.
    func testUnrecognisedCarriesTheRawStringVerbatim() {
        guard case .unrecognised(let raw) = AgentStatus(wire: "Waiting_Approval") else {
            return XCTFail("a novel status did not become .unrecognised")
        }
        XCTAssertEqual(raw, "Waiting_Approval",
                       "the raw value was normalised or replaced; a diagnostic cannot name what arrived")
    }

    /// Every documented wire value maps to its own case. This is the premise for
    /// the novel-status test below: if "blocked" did not map, that test would be
    /// comparing two unrecognised values and proving nothing.
    func testEveryKnownWireValueMaps() {
        XCTAssertEqual(AgentStatus(wire: "idle"), .idle)
        XCTAssertEqual(AgentStatus(wire: "working"), .working)
        XCTAssertEqual(AgentStatus(wire: "blocked"), .blocked)
        XCTAssertEqual(AgentStatus(wire: "done"), .done)
    }

    // MARK: - the regression this issue exists for

    /// AXIS: a status from a NEWER herdr must not be sorted into the quiet group.
    ///
    /// This is the defect the whole file guards. A `default: .idle` mapping would
    /// place an agent that is blocked on a human into the one section that starts
    /// collapsed, and nothing anywhere would report it.
    ///
    /// The assertion is deliberately NOT "is not idle" — that would also pass if
    /// the row were sorted into `.stopped`, which is a different wrong answer.
    /// It pins the exact group AND its position relative to the quiet ones.
    func testANovelStatusSortsAboveWorkingAndIdleNotIntoThem() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "idle"),
            try agent(pane: "p2", status: "waiting_approval"),
            try agent(pane: "p3", status: "working"),
        ])

        let novel = try XCTUnwrap(list.rows.first { $0.info.paneID == "p2" })
        XCTAssertEqual(novel.group, .unrecognised,
                       "a status this build does not know was given a definite meaning")
        XCTAssertLessThan(novel.group, .working,
                          "an uninterpretable agent sorted below working; a new blocked-like state "
                          + "would be buried where nobody looks")
        XCTAssertLessThan(novel.group, .idle,
                          "an uninterpretable agent sorted into or below the collapsed group")

        // And it must actually reach the user: the quiet state cannot hold one.
        XCTAssertFalse(list.isQuiet,
                       "the screen would say all-clear while holding a row it could not read")
    }

    /// AXIS: an agent whose status field is ABSENT surfaces like any other
    /// not-knowing.
    ///
    /// This was wrong at first review and the fix was unguarded until this test
    /// existed: reverting `.absent` to group as `.idle` left the whole suite
    /// green. `agent.list` returns only agent terminals — herdr's `agent_info`
    /// bails unless `terminal.is_agent_terminal()` — so an absent status is an
    /// older server or a gap, never "not an agent", and must not be read as a
    /// definite idle.
    func testAnAbsentStatusSurfacesRatherThanReadingAsIdle() throws {
        let list = AgentList(agents: [
            try agent(pane: "old-server", status: nil),
            try agent(pane: "p2", status: "idle"),
        ])
        let row = try XCTUnwrap(list.rows.first { $0.info.paneID == "old-server" })

        XCTAssertEqual(row.status, .absent, "the premise: this row's status field is missing")
        XCTAssertEqual(row.group, .unrecognised,
                       "an agent with no status was given the definite meaning 'idle'")
        XCTAssertLessThan(row.group, .idle, "it sorted into or below the collapsed group")
        XCTAssertFalse(list.isQuiet,
                       "the screen claimed all-clear while holding an agent it could not read")
    }

    /// AXIS: the headline count follows the GROUP, not the retained status.
    ///
    /// A blocked agent whose pane has since vanished belongs in `.stopped`. It
    /// kept its blocked status for the detail view, and the count read that
    /// status directly — so the screen said "nothing needs you" and "1 needs
    /// you" at the same time. Reverting the fix left the suite green until this
    /// test existed.
    func testAStoppedAgentDoesNotCountEvenIfItsLastStatusWasBlocked() throws {
        let list = AgentList(
            agents: [try agent(pane: "gone", status: "blocked")],
            livePaneIDs: ["someone-else"]
        )
        let row = try XCTUnwrap(list.rows.first)
        XCTAssertEqual(row.status, .blocked, "the premise: the row retains its blocked status")
        XCTAssertEqual(row.group, .stopped, "the premise: the pane is absent from the census")

        XCTAssertEqual(list.needsYouCount, 0,
                       "the count read the stale status; the screen reports both all-clear and "
                       + "one-waiting at once")
        XCTAssertTrue(list.isQuiet)
    }

    /// The unrecognised group must never start collapsed — sorting it high is
    /// pointless if the section is shut by default.
    func testOnlyTheIdleGroupStartsCollapsed() {
        for group in AgentGroup.allCases {
            XCTAssertEqual(group.startsCollapsed, group == .idle,
                           "\(group.label) has the wrong collapse default; a collapsed group must "
                           + "not be able to hide something wanting attention")
        }
    }

    // MARK: - grouping and order

    func testGroupsSortNeedsYouFirstAndIdleLast() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "idle"),
            try agent(pane: "p2", status: "working"),
            try agent(pane: "p3", status: "blocked"),
        ])
        XCTAssertEqual(list.sections.map(\.group), [.needsYou, .working, .idle])
        XCTAssertEqual(list.rows.first?.info.paneID, "p3", "a blocked agent was not first")
    }

    /// Empty sections are omitted rather than rendered as bare headings.
    func testEmptyGroupsAreOmitted() throws {
        let list = AgentList(agents: [try agent(pane: "p1", status: "idle")])
        XCTAssertEqual(list.sections.map(\.group), [.idle])
    }

    /// AXIS: the order within a group does not depend on the order the server
    /// answered in.
    ///
    /// Without a tiebreak, two refreshes returning the same agents in a
    /// different order would reshuffle the list under the user's thumb. The two
    /// inputs here are REVERSES of each other, so a sort that preserved input
    /// order would produce different output and fail.
    func testOrderWithinAGroupIsStableAgainstServerOrder() throws {
        // THE INPUT ORDERS ARE BUILT FROM THESE ARRAYS so that the premise is
        // assertable. Written with the two lists inline, this test SURVIVED its
        // premise mutation: making both inputs identical left it green, because
        // both sides then trivially matched the expected order and nothing had
        // exercised a differing server order at all. Measured, not theorised.
        let firstOrder = ["a", "b", "c"]
        let secondOrder = ["c", "b", "a"]
        XCTAssertNotEqual(firstOrder, secondOrder,
                          "the two server orders are identical; this test cannot detect "
                          + "order-dependence and is not about what it claims")

        let first = AgentList(agents: try firstOrder.map { try agent(pane: $0, status: "working") })
        let second = AgentList(agents: try secondOrder.map { try agent(pane: $0, status: "working") })

        XCTAssertEqual(first.rows.map(\.info.paneID), ["a", "b", "c"])
        XCTAssertEqual(second.rows.map(\.info.paneID), first.rows.map(\.info.paneID),
                       "list order followed the server's response order; it will churn between refreshes")
    }

    // MARK: - liveness

    /// A pane missing from the census is stopped, whatever it last reported.
    func testAPaneAbsentFromTheCensusIsStopped() throws {
        let list = AgentList(
            agents: [try agent(pane: "gone", status: "working")],
            livePaneIDs: ["still-here"]
        )
        let row = try XCTUnwrap(list.rows.first)
        XCTAssertEqual(row.group, .stopped,
                       "a pane herdr no longer lists was grouped by its stale status")
        XCTAssertEqual(row.status, .working,
                       "the last reported status was discarded; the detail view has nothing to show")
    }

    /// AXIS: no census means "unknown liveness", NOT "everything died".
    ///
    /// Inferring death from missing evidence would mark every agent stopped the
    /// instant a census call failed — turning a transient error into a screen
    /// that says all your work crashed.
    func testNoCensusTreatsEveryAgentAsLive() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "working"),
            try agent(pane: "p2", status: "blocked"),
        ], livePaneIDs: nil)
        // THE ROWS MUST EXIST FIRST. Asserting "none is stopped" is trivially
        // true of an empty list, and this test passed with every agent removed
        // — an absence assertion with nothing establishing the presence it is
        // about.
        XCTAssertEqual(list.rows.count, 2, "no rows were built; the assertion below is vacuous")
        XCTAssertFalse(list.rows.contains { $0.group == .stopped },
                       "a missing census was read as evidence of death")
    }

    // MARK: - the count and the quiet state

    /// The headline number counts only positively-blocked agents. Inflating it
    /// with maybes would make the one number on the screen untrustworthy.
    func testNeedsYouCountsOnlyPositivelyBlockedAgents() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "blocked"),
            try agent(pane: "p2", status: "waiting_approval"),
            try agent(pane: "p3", status: "unknown"),
            try agent(pane: "p4", status: nil),
        ])
        XCTAssertEqual(list.needsYouCount, 1,
                       "the headline count included an agent whose state is not known to be blocking")
        // But the uninterpretable ones must still be visible somewhere.
        XCTAssertTrue(list.sections.contains { $0.group == .unrecognised },
                      "agents with uninterpretable status vanished from the screen entirely")
    }

    func testQuietRequiresNothingBlockedAndNothingUnrecognised() throws {
        let quiet = AgentList(agents: [
            try agent(pane: "p1", status: "idle"),
            try agent(pane: "p2", status: "done"),
        ])
        // Same trap: `isQuiet` is true of an empty list, and this passed with
        // the fixture removed entirely. Pin that the quiet rows are actually
        // present and actually quiet-by-status before concluding anything.
        XCTAssertEqual(quiet.rows.map(\.status), [.idle, .done],
                       "the quiet fixture is not present; isQuiet below proves nothing")
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertEqual(quiet.needsYouCount, 0)

        let notQuiet = AgentList(agents: [try agent(pane: "p1", status: "unknown")])
        XCTAssertFalse(notQuiet.isQuiet,
                       "an agent the server could not read still allowed an all-clear")
    }

    func testAnEmptyListIsQuiet() {
        let list = AgentList(agents: [])
        XCTAssertTrue(list.isQuiet)
        XCTAssertEqual(list.needsYouCount, 0)
        XCTAssertTrue(list.sections.isEmpty)
    }
}
