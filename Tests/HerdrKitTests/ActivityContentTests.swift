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
        lastKnownStatus: String? = nil, machineID: String? = nil, reachability: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        if let completedUnixMs { obj["last_completed_turn"] = ["completed_unix_ms": completedUnixMs] }
        if let lastKnownStatus { obj["last_known_status"] = lastKnownStatus }
        if let machineID { obj["machine_id"] = machineID }
        if let reachability { obj["reachability"] = reachability }
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
}
