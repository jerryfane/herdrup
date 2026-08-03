import XCTest
@testable import HerdrKit

final class AgentListTests: XCTestCase {

    // MARK: - fixtures

    /// Builds an AgentInfo through the decoder, so these tests exercise the same
    /// path the wire does. Constructing it in memory would let a test pass while
    /// the JSON key was wrong.
    private func agent(
        pane: String, status: String?, name: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
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
