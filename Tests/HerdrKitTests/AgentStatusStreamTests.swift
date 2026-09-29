import XCTest
import Foundation
@testable import HerdrKit

/// The all-panes status stream (herdr events v2) and the pieces the home list builds
/// on it: line decoding, capability detection, the request shape, stream lifetime,
/// and the row patching that must survive an overlapping `agent.list` reload.
final class AgentStatusStreamTests: XCTestCase {

    // MARK: Decoding

    func testStatusEventKeepsTheCoordinatorQualifiedRemotePaneID() throws {
        let line = #"{"seq":43,"event":"pane.agent_status_changed","data":{"pane_id":"build/w2:p1","workspace_id":"build/w2","agent_status":"blocked","input_pending":true,"input_prompt_kind":"confirm","agent":"claude","turn":4,"turn_epoch":9}}"#
        XCTAssertEqual(try AgentStatusStreamLine.decode(line), .statusChanged(AgentStatusChange(
            seq: 43, paneID: "build/w2:p1", workspaceID: "build/w2", agentStatus: "blocked",
            inputPending: true, inputPromptKind: "confirm", agent: "claude", turn: 4, turnEpoch: 9)))
    }

    func testStatusEventWithoutOptionalFieldsDecodes() throws {
        let line = #"{"seq":7,"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}}"#
        XCTAssertEqual(try AgentStatusStreamLine.decode(line), .statusChanged(AgentStatusChange(
            seq: 7, paneID: "w1:p1", workspaceID: "w1", agentStatus: "working")))
    }

    func testTurnCompletedTakesStatusFromThePaneSnapshot() throws {
        let line = #"{"seq":44,"event":"pane.turn_completed","data":{"pane":{"pane_id":"build/w1:p2","workspace_id":"build/w1","agent_status":"done","focused":false},"turn":3,"turn_epoch":9,"outcome":"completed","completed_unix_ms":1790000000000}}"#
        XCTAssertEqual(try AgentStatusStreamLine.decode(line), .turnCompleted(AgentTurnCompletion(
            seq: 44, paneID: "build/w1:p2", agentStatus: "done", turn: 3, turnEpoch: 9,
            outcome: "completed", completedUnixMs: 1_790_000_000_000)))
    }

    func testLifecycleLinesDecodeAndAskForAReload() throws {
        let created = try AgentStatusStreamLine.decode(
            #"{"seq":42,"event":"pane_created","data":{"type":"pane_created","pane":{"pane_id":"build/w3:p1","workspace_id":"build/w3"}}}"#)
        let closed = try AgentStatusStreamLine.decode(
            #"{"seq":45,"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w1:p1","workspace_id":"w1"}}"#)
        let exited = try AgentStatusStreamLine.decode(
            #"{"seq":46,"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w1:p1","workspace_id":"w1"}}"#)
        let detected = try AgentStatusStreamLine.decode(
            #"{"seq":47,"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"w1:p3","workspace_id":"w1","agent":"codex"}}"#)
        XCTAssertEqual(created, .paneCreated(paneID: "build/w3:p1", seq: 42))
        XCTAssertEqual(closed, .paneClosed(paneID: "w1:p1", seq: 45))
        XCTAssertEqual(exited, .paneExited(paneID: "w1:p1", seq: 46))
        XCTAssertEqual(detected, .agentDetected(paneID: "w1:p3", seq: 47))
        for line in [created, closed, exited, detected] {
            XCTAssertTrue(line.requiresRosterReload, "\(line) changes the listed panes")
        }
    }

    func testControlLines() throws {
        let lagged = try AgentStatusStreamLine.decode(
            #"{"control":"lagged","seq":904,"first_missed_seq":1,"last_missed_seq":904}"#)
        XCTAssertEqual(lagged, .lagged(seq: 904, firstMissedSeq: 1, lastMissedSeq: 904))
        XCTAssertTrue(lagged.requiresRosterReload, "missed events can only be recovered by a reload")

        let heartbeat = try AgentStatusStreamLine.decode(#"{"control":"heartbeat","seq":1207}"#)
        XCTAssertEqual(heartbeat, .heartbeat(seq: 1207))
        XCTAssertFalse(heartbeat.requiresRosterReload)
        XCTAssertNil(heartbeat.liveUpdate)
    }

    func testAckListsRejectedEntries() throws {
        XCTAssertEqual(
            try AgentStatusStreamLine.decode(#"{"id":"sub","result":{"type":"subscription_started"}}"#),
            .started(rejectedIndices: []))
        XCTAssertEqual(
            try AgentStatusStreamLine.decode(
                #"{"id":"sub","result":{"type":"subscription_started","rejected":[{"index":3,"error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}]}}"#),
            .started(rejectedIndices: [3]))
    }

    func testUnknownLinesAreToleratedNotFatal() throws {
        let lines = [
            "",
            "not json",
            "[1,2]",
            #"{"control":"resumed","seq":5}"#,
            #"{"seq":8,"event":"workspace_created","data":{"type":"workspace_created","workspace":{}}}"#,
            #"{"seq":9,"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1"}}"#,
            #"{"seq":10,"event":"pane_closed","data":{"type":"pane_closed"}}"#,
            #"{"event":{"type":"pane.turn_completed","pane_id":"w1:p2"}}"#,
        ]
        for line in lines {
            XCTAssertEqual(try AgentStatusStreamLine.decode(line), .unknown(raw: line), line)
        }
    }

    func testErrorLineThrowsTheDaemonsError() {
        let line = #"{"id":"herdrkit:events.subscribe:agent-status","error":{"code":"invalid_request","message":"missing field `pane_id`"}}"#
        XCTAssertThrowsError(try AgentStatusStreamLine.decode(line)) { error in
            XCTAssertEqual(error as? APIError,
                           APIError(code: "invalid_request", message: "missing field `pane_id`"))
        }
    }

    // MARK: Capability detection

    func testPingAdvertisesEventsV2() async throws {
        let v2 = HerdrClient(transport: CannedTransport(ping:
            #"{"id":"p","result":{"type":"pong","version":"0.9.0","protocol":16,"capabilities":{"live_handoff":true,"events_v2":true}}}"#))
        let caps = try await v2.serverCapabilities()
        XCTAssertEqual(caps?.eventsV2, true)

        let old = HerdrClient(transport: CannedTransport(ping:
            #"{"id":"p","result":{"type":"pong","version":"0.8.0","protocol":15,"capabilities":{"live_handoff":true}}}"#))
        let oldCaps = try await old.serverCapabilities()
        XCTAssertEqual(oldCaps?.eventsV2, false, "a daemon that omits the flag is an old daemon")
    }

    func testAgentListCarriesOriginCapabilities() async throws {
        let v2 = HerdrClient(transport: CannedTransport(agentList:
            #"{"id":"a","result":{"type":"agent_list","agents":[{"pane_id":"w1:p1","agent_status":"idle"}],"origin_machine_id":"m","origin_capabilities":{"events_v2":true}}}"#))
        let listing = try await v2.agentListing()
        XCTAssertEqual(listing.agents.map(\.paneID), ["w1:p1"])
        XCTAssertEqual(listing.originCapabilities?.eventsV2, true)

        let old = HerdrClient(transport: CannedTransport(agentList:
            #"{"id":"a","result":{"type":"agent_list","agents":[]}}"#))
        let oldListing = try await old.agentListing()
        XCTAssertNil(oldListing.originCapabilities, "an old daemon omits origin_capabilities")
    }

    // MARK: Request and stream lifetime

    func testSubscriptionRequestsAllPanesWithEventsV2() async throws {
        let transport = ScriptedStreamTransport(lines: [
            #"{"id":"s","result":{"type":"subscription_started"}}"#,
            #"{"seq":1,"event":"pane.agent_status_changed","data":{"pane_id":"build/w1:p2","workspace_id":"build/w1","agent_status":"working"}}"#,
            #"{"control":"heartbeat","seq":1}"#,
        ])
        let client = HerdrClient(transport: transport)
        var received: [AgentStatusStreamLine] = []
        for try await line in client.subscribeAgentStatus() { received.append(line) }

        XCTAssertEqual(received, [
            .started(rejectedIndices: []),
            .statusChanged(AgentStatusChange(seq: 1, paneID: "build/w1:p2", workspaceID: "build/w1",
                                             agentStatus: "working")),
            .heartbeat(seq: 1),
        ])

        let request = try XCTUnwrap(transport.requests.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "events.subscribe")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["events_v2"] as? Bool, true, "control lines are opt-in")
        let entries = try XCTUnwrap(params["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["type"] as? String }, [
            "pane.agent_status_changed", "pane.turn_completed", "pane.created",
            "pane.closed", "pane.exited", "pane.agent_detected",
        ])
        XCTAssertTrue(entries.allSatisfy { $0["pane_id"] == nil }, "every entry watches all panes")
    }

    func testOlderDaemonsRejectionEndsTheStreamWithItsError() async {
        let transport = ScriptedStreamTransport(lines: [
            #"{"id":"s","error":{"code":"invalid_request","message":"missing field `pane_id`"}}"#,
        ])
        do {
            for try await _ in HerdrClient(transport: transport).subscribeAgentStatus() {}
            XCTFail("a rejected subscription must not look like a clean end")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "invalid_request")
        }
    }

    func testSilentStreamFailsAndClosesTheTransportStream() async throws {
        let transport = HangingStreamTransport()
        let stream = HerdrClient(transport: transport)
            .subscribeAgentStatus(silenceTimeout: .milliseconds(200))
        var lines: [AgentStatusStreamLine] = []
        do {
            for try await line in stream { lines.append(line) }
            XCTFail("a silent stream must fail, not finish cleanly")
        } catch {
            XCTAssertEqual(error as? AgentStatusStreamError, .silent(.milliseconds(200)))
        }
        XCTAssertEqual(lines, [.started(rejectedIndices: [])])
        let closed = await transport.waitForTermination()
        XCTAssertTrue(closed, "the underlying connection must be released")
    }

    func testCancellingTheConsumerClosesTheTransportStream() async throws {
        let transport = HangingStreamTransport()
        let client = HerdrClient(transport: transport)
        let started = expectation(description: "acknowledged")
        let consumer = Task {
            for try await line in client.subscribeAgentStatus() {
                if case .started = line { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        consumer.cancel()
        let closed = await transport.waitForTermination()
        XCTAssertTrue(closed, "leaving the home list must close the SSH channel")
    }

    // MARK: Patching rows

    func testStatusUpdatePatchesOnlyTheMatchingRow() throws {
        let agents = try decodeAgents(
            #"[{"pane_id":"w1:p1","agent_status":"idle","status_since_unix_ms":1000},{"pane_id":"build/w1:p2","agent_status":"working","status_since_unix_ms":2000,"turn":1,"turn_epoch":3}]"#)
        let at = Date(timeIntervalSince1970: 50)
        let change = AgentStatusChange(seq: 9, paneID: "build/w1:p2", workspaceID: "build/w1",
                                       agentStatus: "blocked", inputPending: true,
                                       inputPromptKind: "select", turn: 2, turnEpoch: 3)
        let patched = try XCTUnwrap(agents.applying(.status(change), receivedAt: at))
        XCTAssertEqual(patched[0], agents[0])
        XCTAssertEqual(patched[1].agentStatus, "blocked")
        XCTAssertEqual(patched[1].inputPending, true)
        XCTAssertEqual(patched[1].inputPromptKind, "select")
        XCTAssertEqual(patched[1].turn, 2)
        XCTAssertEqual(patched[1].statusSinceUnixMs, 50_000, "a new status restarts the age badge")

        let same = AgentStatusChange(seq: 10, paneID: "w1:p1", workspaceID: "w1", agentStatus: "idle")
        XCTAssertEqual(agents.applying(.status(same), receivedAt: at)?[0].statusSinceUnixMs, 1000,
                       "an unchanged status keeps the daemon's timestamp")

        let unknown = AgentStatusChange(seq: 11, paneID: "build/w9:p9", workspaceID: nil, agentStatus: "working")
        XCTAssertNil(agents.applying(.status(unknown), receivedAt: at), "an unlisted pane needs a reload")
    }

    func testTurnCompletionRecordsTheFinishedTurn() throws {
        let agents = try decodeAgents(#"[{"pane_id":"w1:p1","agent_status":"working","turn":2,"turn_epoch":1}]"#)
        let completion = AgentTurnCompletion(seq: 3, paneID: "w1:p1", agentStatus: "done", turn: 3,
                                             turnEpoch: 1, outcome: "completed", completedUnixMs: 777)
        let row = try XCTUnwrap(agents.applying(.turn(completion), receivedAt: Date())?.first)
        XCTAssertEqual(row.agentStatus, "done")
        XCTAssertEqual(row.turn, 3)
        XCTAssertEqual(row.lastCompletedTurn?.turn, 3)
        XCTAssertEqual(row.lastCompletedTurn?.completedUnixMs, 777)
    }

    /// The race the ledger exists for: a status event arrives while a reload is in
    /// flight, and the reload's snapshot was taken before it.
    func testLedgerKeepsUpdatesAnOverlappingReloadPredates() throws {
        var ledger = AgentLiveUpdateLedger()
        let before = AgentStatusChange(seq: 1, paneID: "w1:p1", workspaceID: "w1", agentStatus: "working")
        ledger.record(.status(before), receivedAt: Date())
        let mark = ledger.mark            // the reload starts here
        let during = AgentStatusChange(seq: 2, paneID: "w1:p1", workspaceID: "w1", agentStatus: "blocked")
        ledger.record(.status(during), receivedAt: Date())

        let staleSnapshot = try decodeAgents(#"[{"pane_id":"w1:p1","agent_status":"working"}]"#)
        XCTAssertEqual(ledger.replay(onto: staleSnapshot, after: mark).first?.agentStatus, "blocked",
                       "the reload must not undo an event it did not see")

        ledger.settle(through: mark)
        XCTAssertEqual(ledger.replay(onto: staleSnapshot, after: 0).first?.agentStatus, "blocked",
                       "settling keeps updates newer than the published snapshot")
        ledger.settle(through: ledger.mark)
        XCTAssertEqual(ledger.replay(onto: staleSnapshot, after: 0).first?.agentStatus, "working",
                       "settled updates are forgotten")
    }

    func testLedgerIsBounded() throws {
        var ledger = AgentLiveUpdateLedger()
        for i in 0..<(AgentLiveUpdateLedger.capacity + 10) {
            ledger.record(.status(AgentStatusChange(seq: UInt64(i), paneID: "w1:p1", workspaceID: nil,
                                                    agentStatus: i.isMultiple(of: 2) ? "idle" : "working")),
                          receivedAt: Date())
        }
        let agents = try decodeAgents(#"[{"pane_id":"w1:p1","agent_status":"blocked"}]"#)
        // The newest entry (odd index) survives the bound.
        XCTAssertEqual(ledger.replay(onto: agents, after: 0).first?.agentStatus, "working")
    }

    // MARK: Backoff

    func testBackoffDoublesToItsCapAndResets() {
        var backoff = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30))
        let delays = (0..<7).map { _ in backoff.next() }
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                                .seconds(16), .seconds(30), .seconds(30)])
        backoff.reset()
        XCTAssertEqual(backoff.next(), .seconds(1))
    }

    // MARK: Helpers

    private func decodeAgents(_ json: String) throws -> [AgentInfo] {
        try JSONDecoder().decode([AgentInfo].self, from: Data(json.utf8))
    }
}

/// Answers `ping` and `agent.list` with canned lines.
private struct CannedTransport: HerdrTransport {
    var ping = #"{"id":"p","result":{"type":"pong","version":"0.8.0","protocol":15}}"#
    var agentList = #"{"id":"a","result":{"type":"agent_list","agents":[]}}"#

    func roundTrip(_ requestLine: String) async throws -> String {
        requestLine.contains("\"ping\"") ? ping : agentList
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Streams fixed lines, then closes, recording each request.
private final class ScriptedStreamTransport: HerdrTransport, @unchecked Sendable {
    private let lines: [String]
    private let lock = NSLock()
    private var recorded: [String] = []

    init(lines: [String]) { self.lines = lines }

    var requests: [String] { lock.withLock { recorded } }

    func roundTrip(_ requestLine: String) async throws -> String { "" }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { recorded.append(requestLine) }
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Acknowledges, then holds the stream open without writing anything, the way a
/// half-open SSH connection looks. Records when the stream is terminated.
private final class HangingStreamTransport: HerdrTransport, @unchecked Sendable {
    private let terminated = TerminationFlag()

    func roundTrip(_ requestLine: String) async throws -> String { "" }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(#"{"id":"s","result":{"type":"subscription_started"}}"#)
            continuation.onTermination = { [terminated] _ in Task { await terminated.set() } }
        }
    }

    func waitForTermination() async -> Bool {
        for _ in 0..<100 {
            if await terminated.value { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private actor TerminationFlag {
    private(set) var value = false
    func set() { value = true }
}
