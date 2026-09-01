import XCTest
@testable import HerdrKit
@testable import AgentActivityState

/// THE CROSS-TARGET TESTS, and the first in this repo that can see both HerdrKit and the Live
/// Activity's state type at once.
///
/// I reported this seam as impossible: the widget links only WidgetKit/SwiftUI/ActivityKit and
/// cannot link HerdrKit, and a HerdrKit dependency would duplicate `Shared/`'s symbols in the
/// app binary. Both are true of the SHIPPED BINARIES and neither reaches a test target, which
/// is linked into the test bundle and into nothing else. A reviewer pointed that out; the fix
/// was one word in Package.swift.
///
/// What that buys is the thing the previous head lacked. `AgentList.activityContent` is the
/// whole mapping the lock screen renders, so these tests execute the PATH rather than pinning a
/// helper beside it — the earlier five tests pinned `activityLead` while the app-side call site
/// stayed invisible to every target, and the one-line revert to the buggy expression passed all
/// 446 tests.
final class ActivityContentTests: XCTestCase {

    // MARK: - fixtures

    /// Same decoder-first construction as AgentListTests, for the same reason: an in-memory
    /// AgentInfo can hold a shape the wire cannot produce.
    private func agent(
        pane: String, status: String?, name: String? = nil, completedUnixMs: Int64? = nil,
        lastKnownStatus: String? = nil, machineID: String? = nil, reachability: String? = nil,
        archivedBy: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        if let completedUnixMs { obj["last_completed_turn"] = ["completed_unix_ms": completedUnixMs] }
        if let lastKnownStatus { obj["last_known_status"] = lastKnownStatus }
        if let machineID { obj["machine_id"] = machineID }
        if let reachability { obj["reachability"] = reachability }
        // Archived agents are pulled out of `rows` entirely by AgentList's init, which is the
        // property one of the residual mutants exploits.
        if let archivedBy { obj["archived"] = ["at": "2026-08-26T18:00:00Z", "by": archivedBy] }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    /// The six row kinds the headline rule distinguishes. `.stopped` comes from LIVENESS, not
    /// from a status word, so it is expressed by omitting the pane from the census.
    private enum Kind: String, CaseIterable {
        case needsYouConfirmed, needsYouUnconfirmed, unrecognised, working, idle, stopped
    }

    private func list(_ kinds: [Kind]) throws -> AgentList {
        var infos: [AgentInfo] = []
        var live: Set<String> = []
        for (i, k) in kinds.enumerated() {
            let pane = "p\(i)"
            switch k {
            case .needsYouConfirmed:
                infos.append(try agent(pane: pane, status: "blocked", name: k.rawValue))
                live.insert(pane)
            case .needsYouUnconfirmed:
                infos.append(try agent(pane: pane, status: "unknown", name: k.rawValue,
                                       lastKnownStatus: "blocked", machineID: "m\(i)",
                                       reachability: "degraded"))
                live.insert(pane)
            case .unrecognised:
                infos.append(try agent(pane: pane, status: "wat", name: k.rawValue))
                live.insert(pane)
            case .working:
                infos.append(try agent(pane: pane, status: "working", name: k.rawValue))
                live.insert(pane)
            case .idle:
                infos.append(try agent(pane: pane, status: "idle", name: k.rawValue))
                live.insert(pane)
            case .stopped:
                // Present in the roster, absent from the census: that is what stopped IS.
                infos.append(try agent(pane: pane, status: "working", name: k.rawValue))
            }
        }
        return AgentList(agents: infos, livePaneIDs: live)
    }

    /// The production mapping, reproduced by CALLING it — `App/LiveActivityController` is a
    /// field copy of exactly this and no test target can see `App/`.
    private func state(_ l: AgentList) -> AgentActivityState {
        let c = l.activityContent
        return AgentActivityState(
            headline: c.headline,
            status: AgentActivityStatus(rawValue: c.statusWord) ?? .needsYou,
            needsYouCount: c.needsYouCount,
            unconfirmedCount: c.unconfirmedCount,
            workingCount: c.workingCount,
            totalCount: c.totalCount,
            workingSince: c.workingSinceUnixSeconds)
    }

    // MARK: - the premise: HerdrKit can only emit words this enum accepts

    /// The mapping crosses a module boundary as a String, so the fallback in the app
    /// (`?? .needsYou`) is either unreachable or a silent bug. This makes it unreachable by
    /// assertion rather than by comment.
    func testEveryStatusWordHerdrKitCanEmitIsAValidActivityStatus() throws {
        var seen: Set<String> = []
        for n in 1...3 {
            for combo in combinations(of: Kind.allCases, length: n) {
                let word = try list(combo).activityContent.statusWord
                XCTAssertNotNil(AgentActivityStatus(rawValue: word),
                                "HerdrKit emitted '\(word)', which AgentActivityStatus rejects")
                seen.insert(word)
            }
        }
        XCTAssertEqual(seen, ["needsYou", "working", "idle", "stopped"],
                       "every activity status must be reachable, or the untested word is dead code")
    }

    /// An empty roster still produces a decodable state rather than a crash or an empty
    /// headline, since the activity can exist before the first list arrives.
    func testAnEmptyRosterProducesTheNoAgentsState() {
        let c = AgentList(agents: []).activityContent
        XCTAssertEqual(c.headline, "No agents")
        XCTAssertEqual(c.statusWord, "idle")
        XCTAssertEqual(c.totalCount, 0)
        XCTAssertNil(c.workingSinceUnixSeconds)
    }

    // MARK: - THE PROPERTY: one surface may not contradict itself

    /// The defect this whole rule exists to remove is a single surface disagreeing with
    /// itself: a red Stopped dot above the text "2 working", both derived from one list. Two
    /// heads fixed instances of it. This asserts the CLASS instead, over every roster shape of
    /// size 1-3 (258 lists), by requiring the summary line to agree with the status the dot is
    /// drawn from.
    ///
    /// A reviewer's enumeration measured 9 contradicting shapes before the headline rule and 5
    /// after. This test is what makes the remaining 5 fail rather than be counted.
    func testTheSummaryLineNeverContradictsTheStatusDot() throws {
        for n in 1...3 {
            for combo in combinations(of: Kind.allCases, length: n) {
                let s = state(try list(combo))
                let line = AgentActivitySummary.line(s)
                let shape = combo.map(\.rawValue).joined(separator: "+")
                switch s.status {
                case .needsYou:
                    // Must speak about attention, never about work, and never a bare label.
                    XCTAssertTrue(line.contains("need you"),
                                  "[\(shape)] needs-you dot over the line '\(line)'")
                case .working:
                    XCTAssertEqual(line, "\(s.workingCount) working",
                                   "[\(shape)] working dot over the line '\(line)'")
                case .idle, .stopped:
                    // Nothing is waiting and nothing is working, so the line is the label
                    // itself; anything else would be a count the dot does not support.
                    XCTAssertEqual(line, s.status.label,
                                   "[\(shape)] \(s.status.rawValue) dot over the line '\(line)'")
                }
            }
        }
    }

    /// THE SHAPE THE PREVIOUS HEAD LEFT OPEN, named explicitly so a regression reads as itself
    /// rather than as one failure among 258. An unrecognised lead used to produce
    /// needsYouCount == 0, so the line fell through to the working branch: an amber needs-you
    /// dot above "2 working", painted amber.
    func testAnUnrecognisedLeadDoesNotAnnounceWork() throws {
        let s = state(try list([.unrecognised, .working, .working]))
        XCTAssertEqual(s.status, .needsYou, "an uninterpretable agent must surface, not sink")
        XCTAssertEqual(AgentActivitySummary.line(s), "1 may need you",
                       "an unrecognised agent is a MAYBE: it must not be asserted, nor hidden behind a working count")
        XCTAssertEqual(s.workingCount, 2, "the working agents are still counted, just not announced")
    }

    /// And the divergence from the roster's own count is deliberate, so it is pinned rather
    /// than left to be discovered as an inconsistency. The roster shows the unrecognised row in
    /// its own section; the lock screen has no sections, so it carries the row in the count.
    func testTheRosterCountAndTheActivityCountDivergeDeliberately() throws {
        let l = try list([.unrecognised, .working])
        XCTAssertEqual(l.needsYouCount, 0, "the roster counts only genuinely blocked agents")
        XCTAssertEqual(l.activityContent.needsYouCount, 1, "the activity carries what it cannot draw as a row")
        XCTAssertEqual(l.activityContent.unconfirmedCount, 1, "and carries it as doubt, not as fact")
        XCTAssertFalse(l.isQuiet, "the roster already refuses to call this all-clear")
    }

    // MARK: - the boundaries three surviving mutants exploited

    /// M1 (`case .stopped: return 4`) and M2 (`case .idle: return 6`) both made stopped TIE
    /// with idle, and because rows arrive group-sorted with stopped before idle, first-min-wins
    /// then handed the headline to stopped. Both survived all five of the previous head's tests.
    func testAStoppedPaneLosesToAnIdleOne() throws {
        let l = try list([.stopped, .idle])
        XCTAssertEqual(l.activityLead?.info.name, Kind.idle.rawValue,
                       "a live idle agent is what the session IS doing; a gone pane is not")
        XCTAssertEqual(l.activityContent.statusWord, "idle")
        XCTAssertEqual(AgentActivitySummary.line(state(l)), "Idle",
                       "'Idle - 2 agents' tells the reader a live agent is quiet; 'Stopped' asserts a whole-session fact that is false")
    }

    /// The order the rows arrive in must not decide this, since that is exactly how the two
    /// tie mutants won: they relied on stopped preceding idle in the group sort.
    func testTheStoppedIdleBoundaryIsIndependentOfRowOrder() throws {
        for combo in [[Kind.stopped, .idle], [.idle, .stopped]] {
            XCTAssertEqual(try list(combo).activityContent.statusWord, "idle",
                           "row order changed the headline for \(combo.map(\.rawValue))")
        }
    }

    /// M3 (`case .needsYou: return r.hasUnconfirmedState ? 4 : 0`) dropped an UNCONFIRMED
    /// needs-you row to idle's rank, so working outranked it. An unconfirmed blocked agent is
    /// still the most important thing on the screen; the doubt belongs in the wording, not in
    /// whether it is mentioned at all.
    func testAnUnconfirmedNeedsYouStillOutranksWorkAndIdle() throws {
        let l = try list([.needsYouUnconfirmed, .working, .idle])
        XCTAssertEqual(l.activityLead?.info.name, Kind.needsYouUnconfirmed.rawValue)
        XCTAssertEqual(l.activityContent.statusWord, "needsYou")
        XCTAssertEqual(AgentActivitySummary.line(state(l)), "1 may need you",
                       "the doubt goes in the wording; it must not remove the row from the headline")
    }

    /// The floor above must not become a ceiling: a CONFIRMED row still wins the name.
    func testAConfirmedNeedsYouStillOutranksAnUnconfirmedOne() throws {
        let l = try list([.needsYouUnconfirmed, .needsYouConfirmed])
        XCTAssertEqual(l.activityLead?.info.name, Kind.needsYouConfirmed.rawValue)
        XCTAssertEqual(AgentActivitySummary.line(state(l)), "2 need you · 1 stale",
                       "both are counted and the doubt is named")
    }

    // MARK: - the two duplicated wording tables

    /// THE MECHANICAL CROSS-CHECK. `AgentList.needsYouSummary` and `AgentActivitySummary.line`
    /// are duplicated because the widget cannot link HerdrKit, and until now each was pinned
    /// only against its own local copy: editing one plus its own table passed everything while
    /// the two surfaces drifted apart. The "change both" comment was the only guard.
    func testTheTwoWordingTablesAgree() throws {
        // (needsYou, unconfirmed) pairs both tables enumerate, including the boundary where
        // every waiting agent is a maybe and the one where none is.
        for (needsYou, unconfirmed) in [(1, 0), (1, 1), (5, 5), (2, 1), (3, 0), (4, 2)] {
            var kinds = [Kind](repeating: .needsYouUnconfirmed, count: unconfirmed)
            kinds += [Kind](repeating: .needsYouConfirmed, count: needsYou - unconfirmed)
            let l = try list(kinds)
            XCTAssertEqual(l.needsYouCount, needsYou, "fixture premise for (\(needsYou),\(unconfirmed))")
            XCTAssertEqual(l.unconfirmedNeedsYouCount, unconfirmed, "fixture premise for (\(needsYou),\(unconfirmed))")
            XCTAssertEqual(l.needsYouSummary, AgentActivitySummary.line(state(l)),
                           "the two wording tables disagree at (\(needsYou),\(unconfirmed))")
        }
    }

    // MARK: - helpers

    /// Every ordered combination WITH repetition, so a roster of two working agents and a
    /// roster of one are both covered, and so row order is exercised in both directions.
    private func combinations(of kinds: [Kind], length: Int) -> [[Kind]] {
        guard length > 1 else { return kinds.map { [$0] } }
        return combinations(of: kinds, length: length - 1).flatMap { rest in
            kinds.map { [$0] + rest }
        }
    }

    // MARK: - the three fields a mutation battery found unpinned

    /// A reviewer ran three mutants against the head that merged as #204 and ALL THREE SURVIVED
    /// all 456 tests: `totalCount: rows.count` -> `0`, `headline: lead?.title ?? "No agents"` ->
    /// the bare constant, and `workingSinceUnixSeconds: Double($0) / 1000` -> `Double($0)`,
    /// which hands the lock screen MILLISECONDS where it expects seconds — a 1000x timer error.
    ///
    /// All three were coverage gaps rather than product defects; the shipped code is correct in
    /// each place, which is why that PR was approved rather than blocked. They are pinned here
    /// because a correct field with no test is one edit away from being a wrong field, and
    /// because the tests that were supposed to cover this mapping asserted `activityLead` and
    /// `statusWord` while leaving three of the seven mapped fields untouched.

    /// The headline must NAME the lead agent. The surviving mutant returned the empty-roster
    /// constant for every roster, and only the empty-roster test asserted headline at all.
    func testTheHeadlineNamesTheLeadAgentOnANonEmptyRoster() throws {
        // A blocked agent leads over a working one, so the expected headline is unambiguous.
        let l = AgentList(agents: [
            try agent(pane: "p0", status: "working", name: "busy-one"),
            try agent(pane: "p1", status: "blocked", name: "waiting-one"),
        ], livePaneIDs: ["p0", "p1"])
        XCTAssertEqual(l.activityLead?.info.name, "waiting-one", "premise: the blocked agent leads")
        XCTAssertEqual(l.activityContent.headline, "waiting-one",
                       "the headline must name the lead agent, not fall back to the empty-roster constant")
        // And it is the lead's name specifically, not just any non-constant string.
        XCTAssertNotEqual(l.activityContent.headline, "busy-one")
    }

    /// totalCount must count every live row. The surviving mutant returned 0 always, and passed
    /// because the only assertion on totalCount was the empty roster, which expects 0.
    func testTotalCountCountsEveryLiveRow() throws {
        for n in 1...4 {
            let kinds = [Kind](repeating: .working, count: n)
            XCTAssertEqual(try list(kinds).activityContent.totalCount, n,
                           "totalCount must equal the live row count, not a constant")
        }
        // A stopped pane is still a ROW on the lock screen's "N agents" readout, so it counts.
        let mixed = try list([.working, .stopped, .idle])
        XCTAssertEqual(mixed.activityContent.totalCount, 3,
                       "a stopped row is still an agent in the session; it is demoted as headline, not removed")
    }

    /// workingSince must be SECONDS. The surviving mutant passed milliseconds straight through,
    /// which the widget would render as a timer roughly 1000x too long, and it survived because
    /// no fixture set completedUnixMs so the `word == "working"` gate's true branch never ran.
    func testWorkingSinceIsSecondsNotMilliseconds() throws {
        let ms: Int64 = 1_723_000_000_000          // 2024-08-07T02:26:40Z in ms
        let l = AgentList(agents: [try agent(pane: "p0", status: "working",
                                             name: "busy-one", completedUnixMs: ms)],
                          livePaneIDs: ["p0"])
        XCTAssertEqual(l.activityContent.statusWord, "working", "premise: the working gate must be open")
        let since = try XCTUnwrap(l.activityContent.workingSinceUnixSeconds,
                                 "a working lead with a completed turn must carry a start time")
        XCTAssertEqual(since, Double(ms) / 1000, accuracy: 0.001,
                       "workingSince must be SECONDS; passing the millisecond value through is a 1000x timer error")
        // DELETED: a magnitude check `XCTAssertLessThan(since, 1e11)` used to sit here as a
        // "sanity" guard. A reviewer measured it in both directions and showed it is dominated by
        // the exact equality above — /1000 -> Double fails both, while /1000 -> /100000 fails the
        // equality and PASSES the magnitude check. Because the equality is exact against a
        // hardcoded constant, no production-only mutant exists that the magnitude check catches
        // and the equality misses. It looked like a guard and was ceremony, so it is gone rather
        // than left to reassure the next reader.
    }

    /// And the gate itself: a non-working lead carries NO start time, so a dropped gate cannot
    /// hide behind the value assertion above.
    ///
    /// THE LEAD MUST CARRY A TIMESTAMP FOR THIS TO TEST ANYTHING. The first version of this
    /// test gave the completed turn to the WORKING agent and left the leading blocked agent
    /// without one, so `since` was nil whatever the gate did — and a mutant replacing
    /// `word == "working"` with an always-true condition passed it. Caught by running that
    /// mutant, not by reading. The blocked lead therefore has its own `completedUnixMs`: with
    /// the gate intact that value must be suppressed, and with the gate dropped it leaks.
    func testOnlyAWorkingLeadCarriesAStartTime() throws {
        let ms: Int64 = 1_723_000_000_000
        let l = AgentList(agents: [
            try agent(pane: "p0", status: "working", name: "busy-one", completedUnixMs: ms),
            // The LEAD, and it has a completed turn of its own — that is what makes the gate
            // observable rather than incidentally satisfied.
            try agent(pane: "p1", status: "blocked", name: "waiting-one", completedUnixMs: ms + 5_000),
        ], livePaneIDs: ["p0", "p1"])
        XCTAssertEqual(l.activityContent.statusWord, "needsYou", "premise: the blocked agent leads")
        XCTAssertNotNil(l.activityLead?.info.lastCompletedTurn?.completedUnixMs,
                        "premise: the lead carries a timestamp, so a dropped gate would publish it")
        XCTAssertNil(l.activityContent.workingSinceUnixSeconds,
                     "only a WORKING lead has a current turn to time; a needs-you lead's last turn is not a live timer")
    }

    // MARK: - the residual mutants #207's review left surviving

    /// F1. activityContent's unconfirmedCount filter is a SECOND COPY of the hasUnconfirmedState
    /// predicate, and the distinction it must preserve was a real shipped defect: the marker
    /// version excludes fully unreachable peers, because the roster CARD draws those an offline
    /// badge instead of a stale chip. A surface with no rows to mark has nothing to substitute,
    /// so counting with the marker's exclusion reports a dead machine's stale guess as CONFIRMED.
    ///
    /// The mutant `hasUnconfirmedState -> showsUnconfirmedMarker` survived all 460 tests because
    /// no fixture here was UNREACHABLE — only degraded. AgentListTests pins this on the roster
    /// side (testUnreachablePeerStillCountsAsUnconfirmed); the activity side had no equivalent.
    func testAnUnreachablePeerStillCountsAsUnconfirmedInTheActivity() throws {
        let l = AgentList(agents: [
            try agent(pane: "p0", status: "unknown", name: "dead-machine",
                      lastKnownStatus: "blocked", machineID: "mcb", reachability: "unreachable"),
        ], livePaneIDs: ["p0"])
        // The premises that make this test about the COUNT rather than about grouping.
        let row = try XCTUnwrap(l.rows.first)
        XCTAssertEqual(row.group, .needsYou, "premise: a last-known-blocked peer escalates to needs-you")
        XCTAssertTrue(row.hasUnconfirmedState, "premise: its state is unconfirmed")
        XCTAssertFalse(row.showsUnconfirmedMarker,
                       "premise: the MARKER is suppressed for an unreachable peer — that is the exclusion the count must not inherit")
        XCTAssertEqual(l.activityContent.unconfirmedCount, 1,
                       "a fully unreachable peer's stale guess must be counted as unconfirmed; using the marker's exclusion here reports it as fact")
        XCTAssertEqual(l.activityContent.needsYouCount, 1, "and it is still in the attention total")
    }

    /// F2. workingSince must come from the LEAD, not from rows.first. Those differ exactly when
    /// the roster's sort order and the headline rule disagree — which is by design: `rows` sorts
    /// by AgentGroup rawValue where stopped(1) precedes working(3), while activityLead ranks
    /// stopped LAST. The mutant `lead? -> rows.first?` survived because the existing test used a
    /// single-agent roster where the two coincide.
    func testWorkingSinceComesFromTheLeadNotTheFirstRow() throws {
        let leadMs: Int64 = 1_723_000_000_000
        let strayMs: Int64 = 1_600_000_000_000      // distinctly different, so a swap is visible
        let l = AgentList(agents: [
            // Absent from the census => stopped, and it sorts FIRST in `rows` while ranking LAST
            // for the headline. This is the row a rows.first? mutant would read.
            try agent(pane: "p0", status: "working", name: "gone-one", completedUnixMs: strayMs),
            try agent(pane: "p1", status: "working", name: "live-one", completedUnixMs: leadMs),
        ], livePaneIDs: ["p1"])
        XCTAssertEqual(l.rows.first?.group, .stopped, "premise: the stopped row sorts first")
        XCTAssertEqual(l.activityLead?.info.name, "live-one", "premise: the working row leads")
        let since = try XCTUnwrap(l.activityContent.workingSinceUnixSeconds)
        XCTAssertEqual(since, Double(leadMs) / 1000, accuracy: 0.001,
                       "the timer must start from the LEAD's turn; reading rows.first publishes a gone pane's last turn instead")
        XCTAssertNotEqual(since, Double(strayMs) / 1000, accuracy: 0.001)
    }

    /// F4. activityLead's comment states that min(by:) keeps the FIRST row of the winning rank, so
    /// the server's own order decides within a rank. No test held that: changing `<` to `<=`
    /// survived all 460 tests, because Swift's min(by:) replaces the incumbent whenever the
    /// predicate says the newcomer sorts earlier — so a non-strict comparison silently makes the
    /// LAST row of a rank win instead of the first.
    func testWithinARankTheFirstRowWins() throws {
        let l = AgentList(agents: [
            try agent(pane: "p0", status: "blocked", name: "first-waiting"),
            try agent(pane: "p1", status: "blocked", name: "second-waiting"),
        ], livePaneIDs: ["p0", "p1"])
        let firstOfRank = try XCTUnwrap(l.rows.first { $0.group == .needsYou })
        XCTAssertEqual(l.rows.filter { $0.group == .needsYou }.count, 2,
                       "premise: two rows share the winning rank, so the tiebreak is exercised")
        XCTAssertEqual(l.activityLead?.info.paneID, firstOfRank.info.paneID,
                       "the first row of the winning rank must win, as activityLead's comment claims; a non-strict comparison hands it to the last")
        XCTAssertEqual(l.activityContent.headline, firstOfRank.title,
                       "and the headline follows the same row")
    }

    /// F5. totalCount is the live row count and must exclude ARCHIVED agents, which AgentList's
    /// init pulls out of `rows` entirely. The mutant `rows.count -> rows.count + archived.count`
    /// survived because no fixture here had an archived agent.
    func testTotalCountExcludesArchivedAgents() throws {
        let l = AgentList(agents: [
            try agent(pane: "p0", status: "working", name: "live-one"),
            try agent(pane: "p1", status: "idle", name: "released-one", archivedBy: "jerry"),
        ], livePaneIDs: ["p0", "p1"])
        XCTAssertEqual(l.archived.count, 1, "premise: one agent is archived, so the exclusion is exercised")
        XCTAssertEqual(l.rows.count, 1, "premise: archived agents are not live rows")
        XCTAssertEqual(l.activityContent.totalCount, 1,
                       "the lock screen's agent count is the LIVE roster; a released pane is not part of the session")
    }
}
