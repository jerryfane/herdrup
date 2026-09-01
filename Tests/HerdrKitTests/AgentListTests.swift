import XCTest
@testable import HerdrKit

final class AgentListTests: XCTestCase {

    // MARK: - fixtures

    /// Builds an AgentInfo through the decoder, so these tests exercise the same
    /// path the wire does. Constructing it in memory would let a test pass while
    /// the JSON key was wrong.
    private func agent(
        pane: String, status: String?, name: String? = nil, completedUnixMs: Int64? = nil,
        archivedBy: String? = nil, archivedAt: String? = nil, terminalID: String? = nil,
        inputPending: Bool? = nil, lastKnownStatus: String? = nil, machineID: String? = nil,
        reachability: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        if let terminalID { obj["terminal_id"] = terminalID }
        if let completedUnixMs { obj["last_completed_turn"] = ["completed_unix_ms": completedUnixMs] }
        if let inputPending { obj["input_pending"] = inputPending }
        if let lastKnownStatus { obj["last_known_status"] = lastKnownStatus }
        if let machineID { obj["machine_id"] = machineID }
        if let reachability { obj["reachability"] = reachability }
        if let archivedBy {
            obj["archived"] = ["at": archivedAt ?? "2026-08-26T18:00:00Z", "by": archivedBy]
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    /// An ARCHIVED agent exactly as the server emits one: `pane_id` EMPTY, because the
    /// pane is genuinely released, with `terminal_id` carrying the durable identity.
    ///
    /// This shape is the whole point. The original archived fixtures gave each archived
    /// agent its own non-empty pane id — a state the server never produces — so every
    /// row had a distinct id and the identity collision these tests now guard was
    /// unreachable. The fixture, not the assertion, was the bug.
    private func archivedAgent(
        terminalID: String, name: String?, at: String, by: String = "jerry"
    ) throws -> AgentInfo {
        try agent(pane: "", status: "idle", name: name,
                  archivedBy: by, archivedAt: at, terminalID: terminalID)
    }

    // MARK: - needs-you escalation

    /// An agent showing a plan-approval / AskUserQuestion menu reaches `needsYou` even
    /// though its status string is not the literal "blocked". Before this, grouping read
    /// only the status, so the row sat in `working` while the input router already treated
    /// it as awaiting a menu answer: the list and the router disagreed about one fact.
    func testInputPendingReachesNeedsYouWithoutBlockedStatus() throws {
        let row = AgentRow(info: try agent(pane: "p1", status: "working", inputPending: true))
        XCTAssertEqual(row.group, .needsYou)
        XCTAssertEqual(row.status, .working, "the raw status is still reported verbatim")
        // Control: the same row without the flag stays in `working`, so the assertion
        // above is about `input_pending` and not about the fixture.
        let control = AgentRow(info: try agent(pane: "p1", status: "working"))
        XCTAssertEqual(control.group, .working)
    }

    /// A federated peer that misses ONE poll gets `agent_status: "unknown"` with the real
    /// state moved to `last_known_status`. A blocked agent on that machine must stay in
    /// `needsYou` instead of vanishing into `unrecognised` with everything else on the peer.
    func testDegradedPeerKeepsABlockedAgentInNeedsYou() throws {
        let row = AgentRow(info: try agent(pane: "p1", status: "unknown",
                                           lastKnownStatus: "blocked", machineID: "mcb-air"))
        XCTAssertEqual(row.group, .needsYou)
        XCTAssertEqual(row.status, .indefinite, "the status itself is still not known")
    }

    /// Escalation is one-way. A last-known status that is not `blocked` must NOT pull the
    /// row down into a quieter section: `unrecognised` sorts above `working` and `idle` on
    /// purpose, and "this machine went quiet on us" is the louder, truer thing to show.
    func testDegradedPeerDoesNotDemoteANonBlockedLastKnownStatus() throws {
        for last in ["working", "idle", "done"] {
            let row = AgentRow(info: try agent(pane: "p1", status: "unknown",
                                               lastKnownStatus: last, machineID: "mcb-air"))
            XCTAssertEqual(row.group, .unrecognised, "last_known_status \(last) must not demote")
        }
    }

    /// A pane that no longer exists needs nothing from anybody, so a stale `input_pending`
    /// cannot resurrect it into `needsYou`.
    func testStoppedPaneIsNeverEscalated() throws {
        let row = AgentRow(info: try agent(pane: "p1", status: "blocked", inputPending: true),
                           isLive: false)
        XCTAssertEqual(row.group, .stopped)
    }

    /// The input_pending escalation is written to fire for ANY status, so pin EVERY status
    /// it can arrive with, not just one. A review mutant that narrowed it to
    /// `status == .working` survived the whole 427-test suite because the only fixture
    /// built "working"; the idle-plus-input_pending shape is the more common one in
    /// practice, since an agent parked on a menu often reports idle.
    func testInputPendingEscalatesFromEveryLiveStatus() throws {
        for status in ["idle", "working", "done", "unknown", "blocked", "wat"] {
            let row = AgentRow(info: try agent(pane: "p1", status: status, inputPending: true))
            XCTAssertEqual(row.group, .needsYou, "input_pending must escalate from \(status)")
        }
        // Controls: the SAME statuses without the flag must land where grouping puts them,
        // so the loop above is about input_pending and not about the fixture.
        for (status, expected) in [("idle", AgentGroup.idle), ("working", .working),
                                   ("done", .idle), ("unknown", .unrecognised),
                                   ("blocked", .needsYou), ("wat", .unrecognised)] {
            let row = AgentRow(info: try agent(pane: "p1", status: status))
            XCTAssertEqual(row.group, expected, "control for \(status)")
        }
    }

    /// The `status == .indefinite` precondition on the last-known escalation is
    /// load-bearing: a LIVE status is authoritative, and `last_known_status` only means
    /// anything once the daemon has blanked the live one to "unknown". A review mutant
    /// that dropped the precondition survived the full suite, so pin it directly. The
    /// shape is real: a fixture elsewhere in this file builds status "idle" with a
    /// last-known "working".
    func testLastKnownBlockedIsIgnoredWhileTheLiveStatusIsKnown() throws {
        for status in ["idle", "working", "done"] {
            let row = AgentRow(info: try agent(pane: "p1", status: status,
                                               lastKnownStatus: "blocked", machineID: "mcb-air"))
            XCTAssertNotEqual(row.group, .needsYou,
                              "a live \(status) status must not be overridden by a stale blocked value")
        }
        // And the case it IS for: the daemon blanked the live status, so last-known decides.
        let blanked = AgentRow(info: try agent(pane: "p1", status: "unknown",
                                               lastKnownStatus: "blocked", machineID: "mcb-air"))
        XCTAssertEqual(blanked.group, .needsYou)
    }

    /// A degraded peer is 1 to 2 missed polls, not offline, so `isUnreachable` is false
    /// while the status is nevertheless unconfirmed. The row needs a staleness marker, and
    /// the render keys on this predicate, so pin both arms plus the fresh case.
    func testDegradedReachabilityIsUnconfirmedButNotUnreachable() throws {
        let degraded = try agent(pane: "p1", status: "unknown", lastKnownStatus: "blocked",
                                 machineID: "mcb-air", reachability: "degraded")
        XCTAssertTrue(degraded.hasUnconfirmedStatus)
        XCTAssertFalse(degraded.isUnreachable)
        let gone = try agent(pane: "p2", status: "unknown", machineID: "mcb-air",
                             reachability: "unreachable")
        XCTAssertTrue(gone.hasUnconfirmedStatus)
        XCTAssertTrue(gone.isUnreachable)
        let live = try agent(pane: "p3", status: "idle", machineID: "mcb-air",
                             reachability: "reachable")
        XCTAssertFalse(live.hasUnconfirmedStatus)
        // A newer server's unknown string must read as FRESH, never stamp every row stale.
        let newer = try agent(pane: "p4", status: "idle", machineID: "mcb-air",
                              reachability: "some-future-state")
        XCTAssertFalse(newer.hasUnconfirmedStatus)
        // A local agent carries no reachability at all.
        XCTAssertFalse(try agent(pane: "p5", status: "idle").hasUnconfirmedStatus)
    }

    /// EVERY CONJUNCT of `showsUnconfirmedMarker` gets its own assertion, because a review
    /// found all three one-conjunct mutants surviving the full 430-test suite. The UI
    /// receipt cannot see them either: the mock fixture has no stopped or unreachable
    /// degraded row, so its marker count stays 1 under all three.
    func testShowsUnconfirmedMarkerRequiresEveryConjunct() throws {
        let degraded = try agent(pane: "p1", status: "unknown", lastKnownStatus: "blocked",
                                 machineID: "mcb-air", reachability: "degraded")
        // The positive case, so the negatives below cannot pass by the rule never firing.
        XCTAssertTrue(AgentRow(info: degraded).showsUnconfirmedMarker)

        // isLive: a pane that is gone is not presenting anything to qualify. Dropping this
        // conjunct puts a stale chip on a stopped row.
        XCTAssertFalse(AgentRow(info: degraded, isLive: false).showsUnconfirmedMarker,
                       "a stopped row must not be marked; it renders no live state at all")

        // !isUnreachable: that case already REPLACES the status with an offline mark, so
        // marking it too says the same thing twice. Dropping this conjunct double-marks.
        let gone = try agent(pane: "p2", status: "unknown", lastKnownStatus: "blocked",
                             machineID: "mcb-air", reachability: "unreachable")
        XCTAssertFalse(AgentRow(info: gone).showsUnconfirmedMarker,
                       "an unreachable row takes the offline treatment instead of the chip")

        // hasUnconfirmedStatus: a live local row is never marked.
        XCTAssertFalse(AgentRow(info: try agent(pane: "p3", status: "blocked")).showsUnconfirmedMarker)
    }

    /// `unconfirmedNeedsYouCount` counts only rows that are BOTH unconfirmed and in
    /// needs-you. Dropping the group test was the strongest surviving mutant: the marker
    /// rule itself does not look at the group, so a degraded row whose last-known status is
    /// working or idle groups `.unrecognised` and would then be counted as a waiting agent.
    func testUnconfirmedNeedsYouCountRequiresTheNeedsYouGroup() throws {
        // Unconfirmed, but its last-known status is not blocked, so it groups unrecognised.
        let notWaiting = try agent(pane: "p1", status: "unknown", lastKnownStatus: "working",
                                   machineID: "mcb-air", reachability: "degraded")
        let list = AgentList(agents: [notWaiting])
        XCTAssertEqual(list.rows.first?.group, .unrecognised, "premise: this row is not waiting")
        XCTAssertTrue(try XCTUnwrap(list.rows.first).showsUnconfirmedMarker,
                      "premise: it IS unconfirmed, so only the group test can exclude it")
        XCTAssertEqual(list.unconfirmedNeedsYouCount, 0,
                       "an unconfirmed row that is not waiting must not be counted as waiting")

        // And the row that IS waiting is counted.
        let waiting = try agent(pane: "p2", status: "unknown", lastKnownStatus: "blocked",
                                machineID: "mcb-air", reachability: "degraded")
        XCTAssertEqual(AgentList(agents: [waiting]).unconfirmedNeedsYouCount, 1)
    }

    /// The wording spec every surface shares. Three surfaces render this count and the
    /// first version qualified only the roster card, which is how the lock screen ended up
    /// asserting an unconfirmed state as fact.
    func testNeedsYouSummaryQualifiesUnconfirmedCounts() throws {
        XCTAssertNil(AgentList(agents: [try agent(pane: "p1", status: "idle")]).needsYouSummary,
                     "nothing waiting means no summary, so a caller can use its own wording")

        let live = try agent(pane: "p1", status: "blocked")
        XCTAssertEqual(AgentList(agents: [live]).needsYouSummary, "1 need you")

        let stale = try agent(pane: "p2", status: "unknown", lastKnownStatus: "blocked",
                              machineID: "mcb-air", reachability: "degraded")
        XCTAssertEqual(AgentList(agents: [stale]).needsYouSummary, "1 may need you",
                       "when every waiting agent is unconfirmed, the whole claim is a maybe")

        XCTAssertEqual(AgentList(agents: [live, stale]).needsYouSummary, "2 need you · 1 stale",
                       "mixed: lead with the fact, then name the doubt")
    }

    /// A FULLY OFFLINE peer's escalated rows must still count as unconfirmed. This was the
    /// fourth surviving mutant a review found, and it was a real defect rather than a
    /// coverage hole: the count reused `showsUnconfirmedMarker`, which excludes
    /// `isUnreachable` because the CARD draws those an offline badge instead. Counting with
    /// a rendering exclusion meant a dead machine's stale guess was reported as CONFIRMED
    /// on the Live Activity and the roster header, the two surfaces with no row to mark.
    func testUnreachablePeerStillCountsAsUnconfirmed() throws {
        let offline = try agent(pane: "p1", status: "unknown", lastKnownStatus: "blocked",
                               machineID: "mcb-air", reachability: "unreachable")
        let row = AgentRow(info: offline)
        // The premises that made the defect invisible: it IS escalated, and it is
        // deliberately NOT marked, because the offline badge replaces its status entirely.
        XCTAssertEqual(row.group, .needsYou)
        XCTAssertFalse(row.showsUnconfirmedMarker, "the card draws it offline, not stale")
        XCTAssertTrue(row.hasUnconfirmedState, "but the underlying state is still unconfirmed")

        let list = AgentList(agents: [offline])
        XCTAssertEqual(list.unconfirmedNeedsYouCount, 1,
                       "a dead machine's last-known blocked must never read as confirmed")
        XCTAssertEqual(list.needsYouSummary, "1 may need you")

        // Five agents on one dead machine previously rendered a flat "5 need you".
        let five = try (1...5).map {
            try agent(pane: "p\($0)", status: "unknown", lastKnownStatus: "blocked",
                      machineID: "mcb-air", reachability: "unreachable")
        }
        XCTAssertEqual(AgentList(agents: five).needsYouSummary, "5 may need you")

        // Mixed with a genuinely live blocked agent, the doubt is named rather than hidden.
        let live = try agent(pane: "live", status: "blocked")
        XCTAssertEqual(AgentList(agents: [live, offline]).needsYouSummary,
                       "2 need you · 1 stale")

        // And a stopped row on a dead peer is not unconfirmed, it is simply gone.
        XCTAssertFalse(AgentRow(info: offline, isLive: false).hasUnconfirmedState)
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
            try archivedAgent(terminalID: "term-old", name: "old", at: "2026-08-26T10:00:00Z"),
            try archivedAgent(terminalID: "term-new", name: "new", at: "2026-08-26T20:00:00Z"),
        ])
        // Live sections/rows exclude the two archived agents.
        XCTAssertEqual(list.rows.map(\.info.paneID), ["p1"])
        XCTAssertFalse(list.rows.contains { $0.info.isArchived })
        XCTAssertEqual(list.needsYouCount, 1)
        // Archived collected separately, most-recently-archived first.
        XCTAssertEqual(list.archived.map(\.title), ["new", "old"])
    }

    /// EVERY archived row must carry a DISTINCT, non-empty list identity.
    ///
    /// The server empties `pane_id` on archive (the pane is released), so keying rows on
    /// it collapsed every archived row onto `""`. SwiftUI then rendered them all as
    /// whichever sorted first — and because the section sorts most-recently-archived
    /// first, every row wore the LAST-archived name, then walked to the next name as
    /// each was unarchived. Three archived agents with three names is the minimum that
    /// can tell "distinct" from "all the same".
    func testArchivedRowsKeepDistinctIdentitiesDespiteEmptyPaneIDs() throws {
        let list = AgentList(agents: [
            try archivedAgent(terminalID: "term-a", name: "among-friends", at: "2026-08-27T08:40:38Z"),
            try archivedAgent(terminalID: "term-b", name: "trend-scout",   at: "2026-08-27T08:40:34Z"),
            try archivedAgent(terminalID: "term-c", name: "aste-screener", at: "2026-08-27T08:40:30Z"),
        ])
        XCTAssertEqual(list.archived.count, 3)
        // The premise: the server really did give us no pane ids.
        XCTAssertTrue(list.archived.allSatisfy { $0.info.paneID.isEmpty },
                      "fixture must model the server: an archived agent has NO pane id")
        // The guard: ids are unique and none is empty.
        let ids = list.archived.map(\.id)
        XCTAssertFalse(ids.contains(""), "an archived row must not fall back to an empty id")
        XCTAssertEqual(Set(ids).count, 3, "archived rows collapsed onto \(Set(ids).count) identities: \(ids)")
        // The symptom: each row renders its OWN name, not the first row's.
        XCTAssertEqual(list.archived.map(\.title), ["among-friends", "trend-scout", "aste-screener"])
    }

    /// A LIVE row's identity is unchanged — still its pane id. The archived fix must not
    /// re-key live rows, or every live row's SwiftUI identity churns on upgrade.
    func testLiveRowIdentityIsStillThePaneID() throws {
        let live = try agent(pane: "w1:p7", status: "working", name: "vetrina", terminalID: "term-live")
        XCTAssertEqual(AgentRow(info: live).id, "w1:p7")
    }

    /// An archived agent with NO name still gets a distinct identity from its terminal
    /// id — name cannot lead the fallback, because it is optional.
    func testUnnamedArchivedRowsStillGetDistinctIdentities() throws {
        let list = AgentList(agents: [
            try archivedAgent(terminalID: "term-a", name: nil, at: "2026-08-27T08:00:00Z"),
            try archivedAgent(terminalID: "term-b", name: nil, at: "2026-08-27T07:00:00Z"),
        ])
        XCTAssertEqual(Set(list.archived.map(\.id)).count, 2)
    }

    // MARK: - time-in-state badge (issue #173)

    func testCompactTimeInStateFormatsMinutesHoursDaysNeverSeconds() {
        let now: UInt64 = 1_000_000_000_000
        // No stamp / future stamp (clock skew) → no badge, never a wrong one.
        XCTAssertNil(compactTimeInState(sinceUnixMs: nil, nowUnixMs: now))
        XCTAssertNil(compactTimeInState(sinceUnixMs: now + 5_000, nowUnixMs: now))
        // Minutes under an hour (seconds floor into minutes, never shown).
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now, nowUnixMs: now), "0m")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 45_000, nowUnixMs: now), "0m")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 60_000, nowUnixMs: now), "1m")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 59 * 60_000, nowUnixMs: now), "59m")
        // Hours under a day.
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 3_600_000, nowUnixMs: now), "1h")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 23 * 3_600_000, nowUnixMs: now), "23h")
        // Days.
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 86_400_000, nowUnixMs: now), "1d")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: now - 3 * 86_400_000, nowUnixMs: now), "3d")
    }

    func testStatusSinceUnixMsDecodesFromWire() throws {
        let absent = try agent(pane: "p1", status: "working")
        XCTAssertNil(absent.statusSinceUnixMs)
        let data = try JSONSerialization.data(withJSONObject: [
            "pane_id": "p2", "agent_status": "working", "status_since_unix_ms": 123_456_789,
        ])
        let present = try JSONDecoder().decode(AgentInfo.self, from: data)
        XCTAssertEqual(present.statusSinceUnixMs, 123_456_789)
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

    // MARK: - account routing

    /// The agent reports which account it runs under, and an account that no longer
    /// resolves reads as an error state.
    ///
    /// This is the fact whose ABSENCE cost the fleet ~2 hours of apparent history: the
    /// pane count was right and the API said ok while eleven agents wrote to the wrong
    /// account's transcript, and the only evidence lived in each child's /proc. Building
    /// the JSON here keeps the keys honest — a wrong CodingKey fails this test.
    func testAccountRoutingDecodesAndFlagsAnUnresolvedAccount() throws {
        let routed = try JSONDecoder().decode(
            AgentInfo.self,
            from: JSONSerialization.data(withJSONObject: [
                "pane_id": "w1:p1",
                "agent_status": "working",
                "account": "claudecrazy",
                "account_config_dir": "/root/.claude-9",
            ]))
        XCTAssertEqual(routed.account, "claudecrazy")
        XCTAssertEqual(routed.accountConfigDir, "/root/.claude-9")
        XCTAssertFalse(routed.hasUnresolvedAccount)

        // The account was removed from the registry: the agent will REFUSE to resume
        // rather than come back on the default account, so this must surface.
        let orphaned = try JSONDecoder().decode(
            AgentInfo.self,
            from: JSONSerialization.data(withJSONObject: [
                "pane_id": "w1:p2",
                "agent_status": "idle",
                "account": "retired",
                "account_unresolved": true,
            ]))
        XCTAssertEqual(orphaned.account, "retired")
        XCTAssertNil(orphaned.accountConfigDir, "a missing account resolves to no config-home")
        XCTAssertTrue(orphaned.hasUnresolvedAccount)
    }

    /// An older daemon reports no routing at all. That must read as "nothing is wrong",
    /// not as an unresolved account — otherwise upgrading the app before the daemon
    /// would paint every agent with an error badge.
    func testAgentFromAnOlderDaemonReportsNoRoutingAndNoError() throws {
        let old = try agent(pane: "p1", status: "working")
        XCTAssertNil(old.account)
        XCTAssertNil(old.accountConfigDir)
        XCTAssertFalse(
            old.hasUnresolvedAccount,
            "absent routing means the server does not report it, never that it is broken")
    }

    /// The label shown on a row: the account's human name when the roster knows the id,
    /// the raw id when it does not — never nothing, because showing nothing restores the
    /// exact silence this feature exists to remove.
    func testAccountDisplayLabelPrefersTheRosterLabelAndFallsBackToTheID() {
        let roster = [
            try? JSONDecoder().decode(
                CredentialAccount.self,
                from: JSONSerialization.data(withJSONObject: [
                    "id": "claudecrazy", "kind": "claude", "label": "ClaudeCrazy", "active": true,
                ])),
        ].compactMap { $0 }
        XCTAssertEqual(roster.count, 1, "precondition: the roster decoded")

        XCTAssertEqual(
            accountDisplayLabel(accountID: "claudecrazy", accounts: roster), "ClaudeCrazy")
        XCTAssertEqual(
            accountDisplayLabel(accountID: "not-in-roster", accounts: roster), "not-in-roster",
            "an unknown id still shows, because hiding it hides the routing")
        XCTAssertNil(accountDisplayLabel(accountID: nil, accounts: roster))
        XCTAssertNil(accountDisplayLabel(accountID: "", accounts: roster))
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

    // MARK: - one timing anchor for the list badge and the terminal header

    /// A WORKING agent's timer must measure from when it STARTED WORKING, not from when
    /// its previous turn finished. Those differ by the idle gap between turns, which is
    /// exactly the amount the terminal header used to over-count while the list card was
    /// right.
    ///
    /// The two stamps are deliberately far apart (a 10-minute idle gap): if the anchor
    /// ever reverts to the completed-turn stamp, this reads 10 minutes too old and fails
    /// loudly rather than drifting by a plausible-looking second.
    func testWorkingAgentMeasuresFromStatusSinceNotTheLastCompletedTurn() {
        let lastTurnEnded: Int64 = 1_000_000_000_000          // previous turn finished
        let startedWorking: UInt64 = 1_000_000_600_000        // 10 minutes later
        let anchor = statusAnchorUnixMs(statusSinceUnixMs: startedWorking,
                                        lastCompletedUnixMs: lastTurnEnded)
        XCTAssertEqual(anchor, Int64(startedWorking))
        XCTAssertNotEqual(anchor, lastTurnEnded,
                          "the header measured from the PREVIOUS turn's end — the 10m idle gap is counted as work")
    }

    /// The list badge and the terminal header must derive from the SAME instant. This is
    /// the property the bug violated; asserting each screen separately would not catch
    /// two screens that are individually defensible and mutually inconsistent.
    func testListBadgeAndTerminalHeaderShareOneAnchor() {
        let info = (statusSince: UInt64(1_000_000_600_000), lastCompleted: Int64(1_000_000_000_000))
        let headerAnchor = statusAnchorUnixMs(statusSinceUnixMs: info.statusSince,
                                              lastCompletedUnixMs: info.lastCompleted)
        // The badge reads status_since directly; the header must land on the same value.
        XCTAssertEqual(headerAnchor.map(UInt64.init), info.statusSince)
        // And therefore both render the same elapsed label at the same "now".
        let now: UInt64 = 1_000_000_900_000        // 5 minutes after work started
        XCTAssertEqual(compactTimeInState(sinceUnixMs: info.statusSince, nowUnixMs: now), "5m")
        XCTAssertEqual(compactTimeInState(sinceUnixMs: headerAnchor.map(UInt64.init), nowUnixMs: now), "5m")
    }

    /// An IDLE agent is the case that always matched — both stamps are the same instant.
    /// Keeping it asserted proves the fix did not achieve agreement by breaking the case
    /// that already worked.
    func testIdleAgentAnchorIsUnchanged() {
        let wentIdle: Int64 = 1_000_000_000_000
        XCTAssertEqual(statusAnchorUnixMs(statusSinceUnixMs: UInt64(wentIdle),
                                          lastCompletedUnixMs: wentIdle),
                       wentIdle)
    }

    /// An older daemon reports no `status_since`; the completed-turn stamp remains the
    /// fallback so the timer degrades instead of vanishing.
    func testFallsBackToLastCompletedTurnOnAnOlderDaemon() {
        XCTAssertEqual(statusAnchorUnixMs(statusSinceUnixMs: nil, lastCompletedUnixMs: 42), 42)
        XCTAssertNil(statusAnchorUnixMs(statusSinceUnixMs: nil, lastCompletedUnixMs: nil))
    }

    // MARK: - usage reset token (epoch AND iso; near vs far)

    /// The server sends epoch seconds AS A STRING. The app parsed ISO-8601 only, so every
    /// real account's reset failed to parse and the meter silently showed no token — the
    /// feature looked unbuilt rather than broken. These are the exact values a live daemon
    /// returned, so the test fails if the epoch path is ever dropped again.
    func testResetInstantParsesEpochSecondsAsWellAsISO() {
        // Real values read off the running daemon.
        XCTAssertEqual(parseResetInstant("1787831400"),
                       Date(timeIntervalSince1970: 1_787_831_400))
        XCTAssertEqual(parseResetInstant("1788217200"),
                       Date(timeIntervalSince1970: 1_788_217_200))
        // The documented alternative shape still works.
        XCTAssertNotNil(parseResetInstant("2026-08-20T18:00:00Z"))
        // Absent or junk yields nil, so the meter shows nothing rather than a wrong time.
        XCTAssertNil(parseResetInstant(nil))
        XCTAssertNil(parseResetInstant(""))
        XCTAssertNil(parseResetInstant("   "))
        XCTAssertNil(parseResetInstant("not-a-date"))
    }

    /// A near reset reads as remaining time, a far one as a date. Driven by the HORIZON,
    /// not the window's label, so a daemon that invents a new label still formats.
    func testUsageResetLabelUsesTimeLeftWhenNearAndADateWhenFar() {
        let now = Date(timeIntervalSince1970: 1_787_824_200)   // 2h before the 5h reset
        // 5h window, 2h out.
        XCTAssertEqual(usageResetLabel(resetsAt: "1787831400", now: now), "2h left")
        // Weekly window, days out — a date, not "109h left".
        let weekly = usageResetLabel(resetsAt: "1788217200", now: now)
        XCTAssertNotNil(weekly)
        XCTAssertFalse(weekly?.contains("left") ?? true,
                       "a reset days away must read as a date, not remaining hours: \(weekly ?? "nil")")
    }

    /// Under an hour must report MINUTES. Reporting hours would render "0h left" for a
    /// window resetting in 45 minutes — the one moment the number matters most.
    func testUsageResetLabelReportsMinutesUnderAnHour() {
        let reset: TimeInterval = 1_787_831_400
        let now = Date(timeIntervalSince1970: reset - 45 * 60)
        XCTAssertEqual(usageResetLabel(resetsAt: String(Int(reset)), now: now), "45m left")
    }

    /// A window whose reset has already passed promises nothing, rather than counting
    /// down into negative time or claiming "0m left" forever.
    func testUsageResetLabelIsNilOncePassed() {
        let reset: TimeInterval = 1_787_831_400
        XCTAssertNil(usageResetLabel(resetsAt: String(Int(reset)),
                                     now: Date(timeIntervalSince1970: reset + 60)))
    }

    // MARK: - permanent stream refusal (never spin on an answer that cannot change)

    /// A refusal the server will repeat must END the stream, and a transient failure must
    /// NOT — otherwise the terminal either spins forever on a dead pane or gives up on one
    /// that would have recovered. Both directions are asserted: a rule that only ever said
    /// "permanent" would pass a one-sided test while stranding every recoverable terminal.
    func testPermanentRefusalsStopTheRetryLoopAndTransientOnesDoNot() {
        // Permanent: the pane is gone, and pane ids are not reused.
        XCTAssertNotNil(permanentStreamRefusal(code: "pane_not_found"))
        // Permanent: this daemon does not speak the method.
        XCTAssertNotNil(permanentStreamRefusal(code: "invalid_request"))
        // Transient — every one of these can succeed on a retry, so none may be
        // classified permanent.
        for code in ["internal_error", "busy", "timeout", "unavailable", "agent_working", ""] {
            XCTAssertNil(permanentStreamRefusal(code: code),
                         "'\(code)' was treated as permanent; a recoverable stream would be stranded")
        }
    }

    /// The notice is what the user reads instead of an endless "reconnecting…", so it must
    /// actually say the retrying stopped.
    func testPermanentRefusalNoticeSaysItIsNotReconnecting() {
        let notice = permanentStreamRefusal(code: "pane_not_found")
        XCTAssertEqual(notice?.contains("not reconnecting"), true)
    }

    // MARK: - the activity headline (a DIFFERENT question from the list order)

    /// THE EXACT CONTRADICTION A REVIEWER MEASURED: one freshly stopped pane used to
    /// outrank every working agent, because the lock screen re-derived its headline from the
    /// roster's SECTION ORDER. The surface then showed a red "Stopped" dot above a summary
    /// line reading "2 working" — self-contradicting, from a single list.
    ///
    /// `.stopped` comes from LIVENESS, not from a status word (a "done" agent folds into
    /// idle), so the census must omit the pane. THE PREMISE IS ASSERTED FIRST: the first
    /// version of this test used `status: "done"` and passed while producing an IDLE row,
    /// which working outranks anyway — green, and testing nothing.
    func testAStoppedPaneIsNotTheHeadlineWhileOthersWork() throws {
        let list = AgentList(agents: [
            try agent(pane: "p1", status: "blocked", name: "gone-one"),
            try agent(pane: "p2", status: "working"),
            try agent(pane: "p3", status: "working"),
        ], livePaneIDs: ["p2", "p3"])   // p1 is absent from the census
        XCTAssertEqual(list.rows.first { $0.info.paneID == "p1" }?.group, .stopped,
                       "premise: p1 must actually be stopped, and a blocked-but-gone pane is the strongest case")
        XCTAssertEqual(list.activityLead?.group, .working,
                       "a gone pane is not what the session is DOING; the list order says otherwise on purpose")
        XCTAssertEqual(list.rows.filter { $0.group == .working }.count, 2,
                       "and the summary count the headline used to contradict is 2")
    }

    /// Stopped IS the honest headline when it is the whole truth, so the demotion above is
    /// a re-ranking and not a suppression.
    func testAStoppedPaneIsTheHeadlineWhenNothingElseExists() throws {
        let list = AgentList(agents: [try agent(pane: "p1", status: "working")],
                             livePaneIDs: [])
        XCTAssertEqual(list.activityLead?.group, .stopped)
    }

    /// Within needsYou, a CONFIRMED row names the headline before a last-known guess on a
    /// peer that went quiet. The doubt is still reported by the count; it just no longer
    /// picks the name.
    func testAConfirmedNeedsYouOutranksAnUnconfirmedOne() throws {
        let stale = try agent(pane: "p1", status: "unknown", name: "stale-one",
                              lastKnownStatus: "blocked", machineID: "mcb", reachability: "degraded")
        let live = try agent(pane: "p2", status: "blocked", name: "live-one")
        // Server order puts the unconfirmed row FIRST, so a rule that merely kept list
        // order would pick it.
        let list = AgentList(agents: [stale, live])
        XCTAssertEqual(list.activityLead?.info.name, "live-one",
                       "a confirmed blocked agent should name the headline over a stale guess")
        XCTAssertEqual(list.unconfirmedNeedsYouCount, 1,
                       "the doubt is still reported, just not as the headline")
    }

    /// needsYou still outranks everything, and unrecognised still keeps its fail-closed
    /// place above working and idle — so the demotion of `stopped` did not disturb the rest.
    func testHeadlineOrderIsOtherwiseUnchanged() throws {
        let needs = try agent(pane: "p1", status: "blocked")
        let unrec = try agent(pane: "p2", status: "wat")
        let work  = try agent(pane: "p3", status: "working")
        let idle  = try agent(pane: "p4", status: "idle")
        XCTAssertEqual(AgentList(agents: [idle, work, unrec, needs]).activityLead?.group, .needsYou)
        XCTAssertEqual(AgentList(agents: [idle, work, unrec]).activityLead?.group, .unrecognised)
        XCTAssertEqual(AgentList(agents: [idle, work]).activityLead?.group, .working)
        XCTAssertEqual(AgentList(agents: [idle]).activityLead?.group, .idle)
    }

    /// An empty list has no headline at all, which the caller renders as "No agents".
    func testAnEmptyListHasNoHeadline() {
        XCTAssertNil(AgentList(agents: []).activityLead)
    }
}
