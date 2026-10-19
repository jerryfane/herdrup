import XCTest
import Foundation
@testable import HerdrKit

/// Validates the JSON the app's DEBUG screenshot-mock transport returns actually
/// decodes through the real `HerdrClient` path — so the iOS mock (which cannot be
/// compiled/run on Linux) serves wire JSON proven correct here, not guessed. The
/// fixtures are `MockWireFixtures` (MockWireFixtures.swift), compiled into the app too.
final class MockWireFixtureTests: XCTestCase {

    /// A canned-response transport standing in for MockTransport.
    private struct FixtureTransport: HerdrTransport {
        func roundTrip(_ requestLine: String) async throws -> String {
            if requestLine.contains("accounts.list") { return MockWireFixtures.accountsList }
            if requestLine.contains("agent.list") { return MockWireFixtures.agentList }
            if requestLine.contains("agent.read") { return MockWireFixtures.agentRead }
            if requestLine.contains("gram.list") { return MockWireFixtures.gramList }
            if requestLine.contains("gram.post") { return MockWireFixtures.gramPosted }
            if requestLine.contains("gram.get_file") { return MockWireFixtures.gramFileContent }
            if requestLine.contains("gram.upload_chunk") { return MockWireFixtures.gramOk }
            if requestLine.contains("gram.delete") { return MockWireFixtures.gramOk }
            if requestLine.contains("pane.set_pty_size") { return MockWireFixtures.panePtySize }
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            // Mirror MockTransport: `pane.stream` replies with the stream_started
            // ack, then a full-screen reset seed, then finishes.
            if requestLine.contains("pane.stream") {
                return AsyncThrowingStream { continuation in
                    continuation.yield(MockWireFixtures.paneStreamAck)
                    continuation.yield(MockWireFixtures.paneStreamReset)
                    continuation.finish()
                }
            }
            return AsyncThrowingStream { $0.finish() }
        }
    }

    /// MockTransport's `gram.list` under `HERDR_MOCK_GRAM_PAGED=1` (gramPagedList): the same
    /// `before_id` matches and answers. The head answer here is the first page; the app's
    /// head poll widens to the pages it has served, which a client-only test does not need.
    private struct PagedGramFixtureTransport: HerdrTransport {
        func roundTrip(_ requestLine: String) async throws -> String {
            guard requestLine.contains("gram.list") else { return #"{"id":"x","result":{}}"# }
            if requestLine.contains(#""before_id":"g9""#) {
                return MockWireFixtures.gramListAnswer(rows: [MockWireFixtures.gramOlderRows], hasMore: true)
            }
            if requestLine.contains(#""before_id":"go24""#) {
                return MockWireFixtures.gramListAnswer(rows: [MockWireFixtures.gramOldestRows], hasMore: false)
            }
            return MockWireFixtures.gramListAnswer(rows: [MockWireFixtures.gramListRows], hasMore: true)
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testMockAgentListDecodesRealisticStatuses() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        XCTAssertEqual(agents.count, 10,
                       "mock agent.list did not decode to 10 agents (9 live + 1 archived)")
        XCTAssertEqual(agents.filter { $0.isArchived }.count, 1, "one fixture agent carries an archived block")
        XCTAssertEqual(agents.first?.paneID, "w1:p1")
        XCTAssertEqual(agents.first?.displayName, "jarvis",
                       "the card headlines the assigned name; fixtures must carry distinct names")
        XCTAssertEqual(agents.first?.agent, "claude", "the identity icon is keyed on the kind, not the name")
        XCTAssertEqual(agents.first?.cwd, "/root/herdr-ios",
                       "cwd must decode — the card subtitle composes folder from it")
        XCTAssertEqual(agents.first?.agentStatus, "blocked",
                       "first mock agent should be blocked (drives NEEDS YOU)")

        // Every status here must be a real herdr wire value, or it would decode
        // as .unrecognised and the mock would render a section the mockup lacks.
        let known: Set = ["idle", "working", "blocked", "done", "unknown"]
        for agent in agents {
            let status = agent.agentStatus ?? "idle"
            XCTAssertTrue(known.contains(status),
                          "fixture uses a non-herdr status \(status); it would land in UNRECOGNISED")
        }
    }

    /// The whole point of the fixture: rendered through the REAL grouping model
    /// with the mock census, it must produce the mockup's composition —
    /// NEEDS YOU 2, STOPPED 1 (from liveness, not a status string), WORKING 1,
    /// IDLE 4 (done folded in). A regression in fixture OR model trips here.
    func testMockRendersMockupComposition() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        let list = AgentList(agents: agents, livePaneIDs: MockWireFixtures.demoLivePaneIDs)

        XCTAssertEqual(list.sections.map(\.group),
                       [.needsYou, .stopped, .working, .idle],
                       "sections did not render in the mockup's order/composition")
        let counts = Dictionary(uniqueKeysWithValues: list.sections.map { ($0.group, $0.rows.count) })
        XCTAssertEqual(counts[.needsYou], 3,
                       "two locally blocked, plus the degraded federated row escalated on its last-known blocked")
        XCTAssertEqual(counts[.stopped], 1)
        XCTAssertEqual(counts[.working], 1)
        XCTAssertEqual(counts[.idle], 4, "the done agent should fold into idle, making IDLE · 4")
        XCTAssertEqual(list.needsYouCount, 3, "header would show the wrong 'N need you'")
        // And one of those three is a MAYBE, which every surface must be able to qualify.
        XCTAssertEqual(list.unconfirmedNeedsYouCount, 1)
        let federated = try XCTUnwrap(list.rows.first { $0.info.machineID != nil })
        XCTAssertEqual(federated.group, .needsYou)
        XCTAssertEqual(federated.status, .indefinite, "its live status is genuinely unknown")
        XCTAssertTrue(federated.showsUnconfirmedMarker, "the card and the widget both key on this")
        XCTAssertFalse(federated.info.isUnreachable, "degraded is not offline; it must not take the offline badge")
        // The locally blocked rows are NOT marked, so the marker is about reachability and
        // not about being in the needs-you group.
        for row in list.rows where row.group == .needsYou && row.info.machineID == nil {
            XCTAssertFalse(row.showsUnconfirmedMarker, "\(row.info.paneID) is a live blocked agent")
        }
        // The archived fixture agent is partitioned OUT of the live sections (which still
        // sum to 8) and into its own collapsed section.
        XCTAssertEqual(list.rows.count, 9, "archived agents must not inflate the live rows")
        XCTAssertEqual(list.archived.count, 1, "the archived fixture agent lands in the Archived section")
        XCTAssertEqual(list.archived.first?.info.name, "huurjacht")

        // STOPPED must come from liveness: w2:p1 is the excluded pane, and its
        // status string is a quiet 'idle' — so if it shows as stopped, that is
        // the census talking, which is the behaviour under test.
        let stopped = try XCTUnwrap(list.sections.first { $0.group == .stopped }).rows
        XCTAssertEqual(stopped.map(\.info.paneID), ["w2:p1"])
        XCTAssertEqual(stopped.first?.status, .idle,
                       "premise: the stopped row's own status is idle; only the census makes it stopped")
    }

    func testMockReadDecodesPaneText() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let read = try await client.read(pane: "w1:p1", source: .recentUnwrapped, format: .text, lines: 200)
        XCTAssertEqual(read.paneID, "w1:p1")
        XCTAssertTrue(read.text.contains("demo data"), "mock pane text missing its marker: \(read.text.prefix(80))")
    }

    // MARK: - Live terminal stream (pane.stream / pane.set_pty_size)

    /// The mock `pane.stream` reply must decode through `streamTerminal`: the
    /// stream_started ack first (carrying the geometry the app lacked), then a
    /// reset seed whose base64 payload decodes to the demo screen. The App's
    /// MockTransport serves the same two fixtures.
    func testMockPaneStreamDecodesAckThenResetSeed() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        var events: [TerminalStreamEvent] = []
        for try await ev in client.streamTerminal(pane: "w1:p1") { events.append(ev) }

        XCTAssertEqual(events.count, 2, "expected the ack + one reset seed")
        guard case .started(let started)? = events.first else {
            return XCTFail("first stream event was not the stream_started ack")
        }
        XCTAssertEqual(started.paneID, "w1:p1")
        XCTAssertEqual(started.cols, 80)
        XCTAssertEqual(started.rows, 24)
        XCTAssertEqual(started.epoch, 7)
        XCTAssertTrue(started.resync)

        guard events.count >= 2, case .frame(let frame) = events[1],
              case .reset(_, let epoch, let cols, let rows, let data, _, let lagged) = frame else {
            return XCTFail("second stream event was not a reset frame")
        }
        XCTAssertEqual(epoch, 7)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(rows, 24)
        XCTAssertFalse(lagged, "the initial seed is not a lagged resync")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("mock render"),
                      "reset seed base64 did not decode to the demo screen")
    }

    /// `setPTYSize` round-trips the applied geometry. The result mirrors the server's
    /// `PanePtySize` EXACTLY — pane_id/cols/rows/locked, no `epoch`.
    func testSetPTYSizeDecodesAppliedSize() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let size = try await client.setPTYSize(pane: "w1:p1", cols: 80, rows: 24)
        XCTAssertEqual(size.paneID, "w1:p1")
        XCTAssertEqual(size.cols, 80)
        XCTAssertEqual(size.rows, 24)
        XCTAssertFalse(size.locked)
    }

    /// Decodes every `StreamFrame` variant off its `frame` discriminator, mirroring
    /// the herdr Rust frame-shape tests (pane_output_stream.rs): a `data` frame's
    /// payload is base64 ("aGk=" -> "hi"), `resize` carries cols/rows, a `reset`
    /// with `lagged:true` flags the resync, and an unknown frame is rejected.
    func testStreamFrameDecodesEachVariant() throws {
        let decoder = JSONDecoder()
        func frame(_ json: String) throws -> StreamFrame {
            try decoder.decode(StreamFrame.self, from: Data(json.utf8))
        }

        guard case .data(let seq, let epoch, let bytes) =
            try frame(#"{"stream":"pane.bytes","frame":"data","seq":42,"epoch":7,"data_b64":"aGk="}"#) else {
            return XCTFail("data frame did not decode")
        }
        XCTAssertEqual(seq, 42)
        XCTAssertEqual(epoch, 7)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hi")

        guard case .resize(_, _, let cols, let rows) =
            try frame(#"{"stream":"pane.bytes","frame":"resize","seq":5,"epoch":7,"cols":100,"rows":30}"#) else {
            return XCTFail("resize frame did not decode")
        }
        XCTAssertEqual(cols, 100)
        XCTAssertEqual(rows, 30)

        guard case .reset(_, _, _, _, _, let history, let lagged) =
            try frame(#"{"stream":"pane.bytes","frame":"reset","seq":1,"epoch":7,"cols":80,"rows":24,"data_b64":"","lagged":true}"#) else {
            return XCTFail("lagged reset frame did not decode")
        }
        XCTAssertTrue(lagged)
        XCTAssertNil(history, "a server that sends no history_b64 must read as 'no history offered'")

        // A keyframe that carries history decodes it; an empty one means "asked, none".
        guard case .reset(_, _, _, _, let screen, let carried, _) =
            try frame(#"{"stream":"pane.bytes","frame":"reset","seq":1,"epoch":7,"cols":80,"rows":24,"data_b64":"aGk=","history_b64":"b2xk"}"#) else {
            return XCTFail("reset with history did not decode")
        }
        XCTAssertEqual(String(decoding: screen, as: UTF8.self), "hi")
        XCTAssertEqual(carried.map { String(decoding: $0, as: UTF8.self) }, "old")
        guard case .reset(_, _, _, _, _, let none, _) =
            try frame(#"{"stream":"pane.bytes","frame":"reset","seq":1,"epoch":7,"cols":80,"rows":24,"data_b64":"","history_b64":""}"#) else {
            return XCTFail("reset with empty history did not decode")
        }
        XCTAssertEqual(none, Data())
        XCTAssertThrowsError(
            try frame(#"{"stream":"pane.bytes","frame":"reset","seq":1,"epoch":7,"cols":80,"rows":24,"data_b64":"","history_b64":"%%"}"#),
            "corrupt history must fail the stream like corrupt screen bytes")

        if case .ping = try frame(#"{"stream":"pane.bytes","frame":"ping","seq":9,"epoch":7}"#) {} else {
            XCTFail("ping frame did not decode")
        }
        if case .exited = try frame(#"{"stream":"pane.bytes","frame":"exited","seq":9,"epoch":7}"#) {} else {
            XCTFail("exited frame did not decode")
        }
        XCTAssertThrowsError(try frame(#"{"stream":"pane.bytes","frame":"wat","seq":1,"epoch":7}"#),
                             "an unknown frame discriminator must be rejected")
    }

    /// STRICT decode is a stream-integrity guard (PR #47 review): a stateful byte
    /// stream cannot skip a corrupt line without desyncing the emulator, so a
    /// malformed frame must THROW — the client then tears the stream down and
    /// reconnects to a fresh reset instead of feeding a plausible-but-wrong frame.
    /// Covers a foreign stream tag, missing required fields, and bad base64.
    func testMalformedStreamFramesAreRejected() throws {
        let decoder = JSONDecoder()
        func frame(_ json: String) throws -> StreamFrame {
            try decoder.decode(StreamFrame.self, from: Data(json.utf8))
        }
        // Foreign stream tag — a line from another channel must not be fed as bytes.
        XCTAssertThrowsError(try frame(#"{"stream":"pane.graphics","frame":"data","seq":1,"epoch":7,"data_b64":"aGk="}"#),
                             "a non pane.bytes stream tag must be rejected")
        // seq/epoch are required — never silently defaulted to 0 (that would hide a gap).
        XCTAssertThrowsError(try frame(#"{"stream":"pane.bytes","frame":"data","epoch":7,"data_b64":"aGk="}"#),
                             "a frame missing seq must be rejected")
        XCTAssertThrowsError(try frame(#"{"stream":"pane.bytes","frame":"data","seq":1,"data_b64":"aGk="}"#),
                             "a frame missing epoch must be rejected")
        // A data/reset frame must carry a valid base64 payload — no empty-degrade.
        XCTAssertThrowsError(try frame(#"{"stream":"pane.bytes","frame":"data","seq":1,"epoch":7}"#),
                             "a data frame with no data_b64 must be rejected")
        XCTAssertThrowsError(try frame(#"{"stream":"pane.bytes","frame":"data","seq":1,"epoch":7,"data_b64":"@@not base64@@"}"#),
                             "an invalid base64 payload must be rejected")
    }

    /// The `accounts.list` fixture must decode through the real client path — the
    /// only Linux-runnable check on the new `CredentialAccount`/`AccountUsage` wire
    /// models (the SwiftUI Accounts section can't be compiled here). Covers a full
    /// usage block (both percents + plan + resets_at), an exhausted account
    /// (active:false, 100%), tier-only usage (no percent), and no usage at all —
    /// each optional field must decode to nil rather than fail.
    func testMockAccountsListDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let accounts = try await client.accountsList()
        XCTAssertEqual(accounts.count, 4, "accounts.list fixture did not decode to 4 accounts")

        // Full usage block on an active Claude Max account.
        let first = try XCTUnwrap(accounts.first)
        XCTAssertEqual(first.id, "acc-claude-1")
        XCTAssertEqual(first.kind, "claude", "kind is the AgentInfo.agent string the swap menu filters on")
        XCTAssertEqual(first.label, "Claude Max (work)")
        XCTAssertTrue(first.active)
        XCTAssertEqual(first.email, "work@example.com", "account email decodes")
        XCTAssertEqual(first.usage?.primaryUsedPercent, 42)
        XCTAssertEqual(first.usage?.secondaryUsedPercent, 68)
        XCTAssertEqual(first.usage?.resetsAt, "2026-08-20T18:00:00Z")
        XCTAssertEqual(first.usage?.plan, "Max")
        // New windows shape: two live buckets, and source marks live-fetched data.
        XCTAssertEqual(first.usage?.source, "live")
        XCTAssertEqual(first.usage?.windows.count, 2)
        XCTAssertEqual(first.usage?.windows.first?.label, "5h")
        XCTAssertEqual(first.usage?.windows.first?.usedPercent, 42)
        XCTAssertEqual(first.usage?.windows.first?.status, "ok")
        XCTAssertEqual(first.usage?.effectiveWindows.count, 2, "windows present → used directly")

        // Exhausted: active:false drives the red "exhausted" pill; percents at 100.
        // This one has NO windows (older-daemon flat shape) → effectiveWindows
        // must synthesize the pair from the back-compat flat fields.
        let exhausted = try XCTUnwrap(accounts.first { $0.id == "acc-claude-2" })
        XCTAssertFalse(exhausted.active)
        XCTAssertEqual(exhausted.usage?.primaryUsedPercent, 100)
        XCTAssertTrue(exhausted.usage?.windows.isEmpty ?? false, "flat-only fixture has no windows")
        XCTAssertEqual(exhausted.usage?.effectiveWindows.count, 2, "synthesized from flat fields")
        XCTAssertEqual(exhausted.usage?.effectiveWindows.first?.usedPercent, 100)

        // Tier-only usage: no percent → nil percents, tier text present.
        let codex = try XCTUnwrap(accounts.first { $0.id == "acc-codex-1" })
        XCTAssertNil(codex.usage?.primaryUsedPercent, "no primary_used_percent must decode to nil, not 0")
        XCTAssertEqual(codex.usage?.tier, "Plus")

        // No usage object at all → nil, not a decode failure. Also no email → nil.
        let kimi = try XCTUnwrap(accounts.first { $0.id == "acc-kimi-1" })
        XCTAssertNil(kimi.email, "an omitted email must decode to nil")
        XCTAssertNil(kimi.usage, "an omitted usage must decode to nil")

        // The swap menu filters same-kind: two claude accounts here.
        XCTAssertEqual(accounts.filter { $0.kind == "claude" }.count, 2,
                       "the per-agent swap submenu offers the same-kind accounts")
    }

    /// `agent.restart` gained an optional `account` (the swap id). The param must
    /// OMIT `account` when nil so a plain restart sends the old `{ target }` payload
    /// (an older daemon is unaffected), and INCLUDE it — snake-free key `account` —
    /// when swapping. Asserts the encoded request line directly.
    func testRestartAccountParamOmittedWhenNilPresentWhenSet() async throws {
        let capture = RecordingTransport(
            reply: #"{"id":"x","result":{"type":"agent_restarted","agent":{"pane_id":"w1:p1"}}}"#)
        let client = HerdrClient(transport: capture)

        _ = try await client.restartAgent(target: "w1:p1")
        XCTAssertTrue(capture.lastRequest.contains("\"target\":\"w1:p1\""), "target must be sent")
        XCTAssertFalse(capture.lastRequest.contains("account"),
                       "a no-account restart must not send an account key: \(capture.lastRequest)")

        _ = try await client.restartAgent(target: "w1:p1", account: "acc-claude-2")
        XCTAssertTrue(capture.lastRequest.contains("\"account\":\"acc-claude-2\""),
                      "swapping must send the account id: \(capture.lastRequest)")
    }

    /// The `gram.list` fixture must decode through the real client path, and the
    /// GramMessage flags the Gram page renders on (unread, grabbed, direct, federated
    /// sender) must resolve correctly. Optional fields (`to`, `grabbed_by`,
    /// `machine_label`) are omitted in JSON when absent — decoding must yield nil, not fail.
    func testMockGramListDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        // `messages` is optional now (an unchanged conditional answer omits it); a
        // fixture answer always carries the list, so nil here is a real failure.
        // Bound before unwrapping: XCTUnwrap's autoclosure cannot contain an `await`.
        let answer = try await client.gramList()
        let messages = try XCTUnwrap(answer.messages)
        XCTAssertEqual(messages.count, 12, "gram.list fixture did not decode to 12 messages")
        XCTAssertEqual(messages.map(\.createdUnixMs), messages.map(\.createdUnixMs).sorted(by: >),
                       "the daemon answers newest first")

        // Newest first: the owner's direct reply leads, and a direct message carries `to`.
        let first = try XCTUnwrap(messages.first)
        XCTAssertEqual(first.id, "g1")
        XCTAssertEqual(first.direction, .ownerToAgent)
        XCTAssertEqual(first.from, "owner")
        XCTAssertFalse(first.isFromAgent)
        XCTAssertEqual(first.to, "vetrina")
        XCTAssertNil(first.grabbedBy)
        XCTAssertFalse(first.isOpenQueueItem, "a direct message is not a queue item")

        // A federated sender: the bare name and the machine label read separately.
        let federated = try XCTUnwrap(messages.first { $0.id == "g2" })
        XCTAssertTrue(federated.isFromAgent)
        XCTAssertTrue(federated.isUnread, "an agent->owner message with read_by_owner:false is unread")
        XCTAssertEqual(federated.from, "4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/clientloop")
        XCTAssertEqual(federated.machineLabel, "hetzner-1")
        XCTAssertEqual(federated.senderAgentName, "clientloop")
        XCTAssertEqual(federated.senderMachine, "hetzner-1")
        XCTAssertNil(federated.to)
        XCTAssertNil(federated.grabbedBy)
        // Its text carries a one-line code fence, which the page draws as a code block.
        XCTAssertEqual(GramText.segments(federated.text), [
            .text("Scaffold is up. Run it with:"),
            .code("cd ~/src/amigo-poc && pnpm dev", language: nil),
        ])

        // A local sender has no machine of its own on the wire.
        let local = try XCTUnwrap(messages.first { $0.id == "g4" })
        XCTAssertEqual(local.senderAgentName, "vetrina")
        XCTAssertNil(local.machineLabel)
        XCTAssertNil(local.senderMachine)
        // The deploy report is 11 lines, past the 8-line clamp, so it folds behind Read more.
        XCTAssertEqual(local.text.split(separator: "\n", omittingEmptySubsequences: false).count, 11,
                       "the long report must be 11 lines")
        XCTAssertGreaterThan(local.text.split(separator: "\n").count, 8,
                             "the long report must be long enough to fold at 8 lines")

        // Two agents share the bare name clientloop: the relayed one above and a local one,
        // so the composer's @ list must tell them apart by their full sender ID.
        let localTwin = try XCTUnwrap(messages.first { $0.id == "g10" })
        XCTAssertEqual(localTwin.from, "clientloop")
        XCTAssertEqual(localTwin.senderAgentName, federated.senderAgentName)
        XCTAssertNotEqual(localTwin.from, federated.from)
        XCTAssertNil(localTwin.senderMachine)

        // A grabbed shared-queue post (no `to`) is no longer open.
        let grabbed = try XCTUnwrap(messages.first { $0.id == "g5" })
        XCTAssertEqual(grabbed.direction, .ownerToAgent)
        XCTAssertNil(grabbed.to)
        XCTAssertEqual(grabbed.grabbedBy, "ci-watch")
        XCTAssertFalse(grabbed.isOpenQueueItem)

        // Two files the store expired: kept as metadata only, never as an openable `file`.
        let expiredOnly = try XCTUnwrap(messages.first { $0.id == "g12" })
        XCTAssertEqual(expiredOnly.text, "", "a caption-less expired file has nothing else to show")
        XCTAssertNil(expiredOnly.file)
        XCTAssertEqual(expiredOnly.expiredFile?.name, "trend-chart.png")
        XCTAssertEqual(expiredOnly.attachmentPreview, "trend-chart.png (expired)")
        let expiredWithText = try XCTUnwrap(messages.first { $0.id == "g11" })
        XCTAssertNil(expiredWithText.file)
        XCTAssertEqual(expiredWithText.expiredFile?.name, "trend-export.csv")
        XCTAssertEqual(messages.filter { $0.expiredFile != nil }.map(\.id), ["g12", "g11"])
        XCTAssertEqual(messages.filter { $0.file != nil }.map(\.id), ["g2", "g3"],
                       "only the two live attachments are files to open")

        // Today's three agent messages are unread → the header badge shows 3.
        XCTAssertEqual(messages.filter { $0.isUnread }.map(\.id), ["g2", "g3", "g4"])
    }

    /// The paged mock (`HERDR_MOCK_GRAM_PAGED=1`, MockTransport.gramPagedList): the head page
    /// is `gramList` with `has_more`, `before_id` g9 answers 24 older rows with `has_more`,
    /// and `before_id` go24 answers the last row. Driven through the real client, so the
    /// request lines it matches on are the ones the app sends, and folded through `GramInbox`
    /// as the page does: each page lands below the last, older and contiguous.
    func testMockGramPagedListPagesContiguously() async throws {
        let client = HerdrClient(transport: PagedGramFixtureTransport())
        var inbox = GramInbox()
        inbox.apply(try await client.gramList(limit: 40))
        XCTAssertEqual(inbox.messages.map(\.id).last, "g9")
        XCTAssertEqual(inbox.messages.count, 12)
        XCTAssertEqual(inbox.nextCursor, "g9", "the head page says there is more")

        var generation = inbox.generation
        let second = try await client.gramList(limit: 40, beforeID: "g9")
        XCTAssertTrue(inbox.appendPage(second, generation: generation))
        XCTAssertEqual(inbox.messages.count, 36, "the second page holds 24 rows")
        XCTAssertEqual(Array(inbox.messages.map(\.id)[12...]), (1...24).map { "go\($0)" })
        XCTAssertEqual(inbox.messages.last?.text, "Older page: release planning starts here.")
        XCTAssertEqual(inbox.nextCursor, "go24", "the second page says there is more")

        generation = inbox.generation
        let third = try await client.gramList(limit: 40, beforeID: "go24")
        XCTAssertTrue(inbox.appendPage(third, generation: generation))
        XCTAssertEqual(inbox.messages.map(\.id).last, "gx1")
        XCTAssertNil(inbox.nextCursor, "the third page is the end")

        XCTAssertEqual(inbox.messages.map(\.createdUnixMs), inbox.messages.map(\.createdUnixMs).sorted(by: >),
                       "pages run newest first, each older than the last")
        XCTAssertEqual(Set(inbox.messages.map(\.id)).count, inbox.messages.count, "no id repeats across pages")
    }

    /// `gram.post` echoes the stored message (`type: gram_sent`) — the composer
    /// inserts it optimistically, so it must decode through the client path.
    func testMockGramPostDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let posted = try await client.gramPost(text: "hello", to: nil)
        XCTAssertEqual(posted.id, "gp1")
        XCTAssertEqual(posted.direction, .ownerToAgent)
        XCTAssertEqual(posted.from, "owner")
    }

    /// A message may carry a file (`file` object); one without it decodes to nil,
    /// not a failure — so the row shows a card only when there is one. A file may come
    /// with no caption at all (an image on its own).
    func testMockGramListDecodesFileAttachment() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let answer = try await client.gramList()
        let messages = try XCTUnwrap(answer.messages)

        let image = try XCTUnwrap(messages.first { $0.id == "g3" })
        let file = try XCTUnwrap(image.file, "g3 should carry a file")
        XCTAssertEqual(file.name, "vetrina-live.png")
        XCTAssertEqual(file.mime, "image/png")
        XCTAssertEqual(file.size, 421888)
        XCTAssertEqual(file.displaySize, "412 KB")
        XCTAssertEqual(image.text, "", "an image may arrive without a caption")

        let zip = try XCTUnwrap(messages.first { $0.id == "g2" }?.file, "g2 should carry a file")
        XCTAssertEqual(zip.name, "amigo-poc-scaffold.zip")
        XCTAssertEqual(zip.mime, "application/zip")
        XCTAssertEqual(zip.displaySize, "1.3 MB")

        let noFile = try XCTUnwrap(messages.first { $0.id == "g1" })
        XCTAssertNil(noFile.file, "a message without a file must decode to nil")
    }

    /// `gram.get_file` returns the bytes inline (base64); the client decodes them.
    func testMockGramGetFileDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let (name, mime, data) = try await client.gramGetFile(id: "g3")
        XCTAssertEqual(name, "vetrina-live.png")
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello world")
    }

    /// The HTML mock (`HERDR_MOCK_GRAM_HTML`): its row decodes with an HTML file whose
    /// listed size matches the bytes `gram.get_file` returns for it.
    func testMockGramHtmlFileDecodes() async throws {
        struct HtmlTransport: HerdrTransport {
            func roundTrip(_ requestLine: String) async throws -> String {
                if requestLine.contains("gram.list") {
                    return MockWireFixtures.gramListAnswer(
                        rows: [MockWireFixtures.gramHtmlRow, MockWireFixtures.gramListRows], hasMore: false)
                }
                if requestLine.contains("gram.get_file") { return MockWireFixtures.gramHtmlContent }
                return #"{"id":"x","result":{}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let client = HerdrClient(transport: HtmlTransport())
        let answer = try await client.gramList()
        let messages = try XCTUnwrap(answer.messages)
        XCTAssertEqual(messages.first?.id, "gh1", "the report sits above the newest message")
        let file = try XCTUnwrap(messages.first?.file, "gh1 should carry a file")
        XCTAssertEqual(file.name, "run-report.html")
        XCTAssertEqual(file.mime, "text/html")

        let (name, mime, data) = try await client.gramGetFile(id: "gh1")
        XCTAssertEqual(name, "run-report.html")
        XCTAssertEqual(mime, "text/html")
        XCTAssertEqual(UInt64(data.count), file.size)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<!doctype html>"))
    }

    /// The upload + delete round-trips decode their `type: ok` replies without
    /// throwing, and the upload mints a safe `app-` id.
    func testMockGramUploadAndDeleteSucceed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-hello-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HerdrClient(transport: FixtureTransport())
        let uploadID = try await client.gramUploadFile(fileURL: url)
        XCTAssertTrue(uploadID.hasPrefix("app-"), "upload id should be a safe app- token")
        try await client.gramDelete(id: "g5")
    }

    /// A worst-case slash-heavy chunk (all 0xFF → base64 is entirely "/") must not
    /// inflate the request line: the request encoder must emit unescaped "/", or a
    /// binary chunk would blow the SSH command-size cap. Guards the chunk-size math.
    func testGramUploadChunkRequestStaysCompactForSlashHeavyData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-chunk-slashes-\(UUID().uuidString).bin")
        try Data(repeating: 0xFF, count: HerdrClient.gramUploadChunkBytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = RecordingTransport(reply: RecordingTransport.okResult)
        let client = HerdrClient(transport: capture)
        _ = try await client.gramUploadFile(fileURL: url)
        // ~49 KiB raw → ~65.5 KB unescaped base64 + envelope. Escaping every "/"
        // would nearly double it; assert it stays well under the point where the
        // outer argv base64 (~1.33x) would breach the 120 KB command cap.
        let maxLen = capture.requestLines.map(\.utf8.count).max() ?? 0
        XCTAssertLessThan(
            maxLen, 80_000,
            "slash escaping inflated the upload request line to \(maxLen) bytes")
    }

    /// Collects `onProgress` callbacks, which arrive on the main actor from a
    /// `@Sendable` closure and so cannot capture a local `var`.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(sent: Int, total: Int)] = []
        func append(sent: Int, total: Int) {
            lock.lock()
            values.append((sent: sent, total: total))
            lock.unlock()
        }
        func snapshot() -> [(sent: Int, total: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// The SAME slash-escaping property at the stream frame size. `RecordingTransport` is not a
    /// `CitadelTransport`, so `gramOpenUploadChannel` returns nil and this exercises
    /// the per-chunk fallback — the CI-visible proof that reading a stream-sized file
    /// from disk does not inflate the request line either.
    func testGramUploadFromDiskRequestStaysCompactForSlashHeavyData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-slashes-\(UUID().uuidString).bin")
        try Data(repeating: 0xFF, count: HerdrClient.gramStreamChunkBytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = RecordingTransport(reply: RecordingTransport.okResult)
        let client = HerdrClient(transport: capture)
        _ = try await client.gramUploadFile(fileURL: url)
        let maxLen = capture.requestLines.map(\.utf8.count).max() ?? 0
        XCTAssertLessThan(
            maxLen, 80_000,
            "slash escaping inflated the from-disk request line to \(maxLen) bytes")
    }

    /// The from-disk fallback path must walk the file in CONTIGUOUS chunks: staging
    /// is append-only, so the daemon rejects any offset that is not the running
    /// staged size. A gap (or a repeat) is the bug this pins.
    func testGramUploadFromDiskSendsContiguousOffsets() async throws {
        let chunkBytes = HerdrClient.gramUploadChunkBytes
        let payload = Data((0..<(chunkBytes * 2 + 7)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-offsets-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = RecordingTransport(reply: RecordingTransport.okResult)
        let client = HerdrClient(transport: capture)
        _ = try await client.gramUploadFile(fileURL: url)

        let chunks = capture.requests.compactMap { request -> (offset: UInt64, data: Data)? in
            guard request.method == "gram.upload_chunk",
                  let offset = request.params["offset"] as? Int,
                  let base64 = request.params["data_base64"] as? String
            else { return nil }
            return (UInt64(offset), Data(base64Encoded: base64) ?? Data())
        }
        let offsets = chunks.map(\.offset)
        let bytes = chunks.reduce(into: Data()) { $0.append($1.data) }
        XCTAssertEqual(
            offsets, [0, UInt64(chunkBytes), UInt64(chunkBytes * 2)],
            "offsets must be contiguous multiples of the chunk size")
        XCTAssertEqual(bytes, payload, "the streamed bytes must reassemble the file")
    }

    /// Progress is reported from the file's own size, once at 0 and once at the end,
    /// so a determinate progress bar cannot be driven past 100% or left short.
    func testGramUploadFromDiskReportsProgressToTotal() async throws {
        let payload = Data(repeating: 7, count: HerdrClient.gramUploadChunkBytes + 128)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-progress-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reports = Reports()
        let sink = RecordingTransport(reply: RecordingTransport.okResult)
        _ = try await HerdrClient(transport: sink).gramUploadFile(fileURL: url) { sent, total in
            reports.append(sent: sent, total: total)
        }
        let observed = reports.snapshot()
        XCTAssertEqual(observed.first?.sent, 0)
        XCTAssertEqual(observed.last?.sent, payload.count)
        XCTAssertTrue(
            observed.allSatisfy { $0.total == payload.count },
            "every report must carry the file's real size")
    }

    /// A 512 KiB all-0xFF chunk — base64 is ENTIRELY "/" — must encode into a frame
    /// that stays inside the daemon's 1 MiB frame cap, which is the property that
    /// makes 512 KiB frames legal at all. Otherwise unreachable in CI: a real
    /// `GramUploadChannel` needs an SSH connection.
    func testGramUploadFrameStaysWithinDaemonFrameCap() throws {
        let chunk = Data(repeating: 0xFF, count: HerdrClient.gramStreamChunkBytes)
        let line = try GramUploadChannel.encodeFrame(
            seq: 1, offset: 0, dataBase64: chunk.base64EncodedString())

        XCTAssertFalse(line.contains("\\/"), "the frame encoder must not escape slashes")
        XCTAssertLessThan(
            line.utf8.count, 1024 * 1024,
            "frame is \(line.utf8.count) bytes, past the daemon's MAX_UPLOAD_FRAME_BYTES")

        struct Frame: Decodable {
            let seq: UInt64
            let offset: UInt64
            let dataBase64: String
            enum CodingKeys: String, CodingKey {
                case seq, offset
                case dataBase64 = "data_base64"
            }
        }
        let decoded = try JSONDecoder().decode(Frame.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.seq, 1)
        XCTAssertEqual(decoded.offset, 0)
        XCTAssertEqual(Data(base64Encoded: decoded.dataBase64), chunk)
    }

    /// An old daemon answers an unknown method with `invalid_request`, which MUST
    /// fall back per-chunk; a real rejection MUST NOT, because the staged file may be
    /// partly written and a fallback retry from offset 0 would be a second writer.
    func testFatalStreamOpenErrorFallsBackOnlyForUnknownMethod() {
        let unknown = GramUploadChannel.ChannelError.remoteError(
            APIError(code: "invalid_request", message: "unknown variant"))
        XCTAssertNil(HerdrClient.fatalStreamOpenError(unknown))

        XCTAssertNil(HerdrClient.fatalStreamOpenError(GramUploadChannel.ChannelError.unsupported))
        XCTAssertNil(
            HerdrClient.fatalStreamOpenError(GramUploadChannel.ChannelError.closedBeforeAck))

        for code in ["invalid_params", "gram_unavailable", "upload_in_progress", "gram_file_error"] {
            let fatal = HerdrClient.fatalStreamOpenError(
                GramUploadChannel.ChannelError.remoteError(APIError(code: code, message: "no")))
            XCTAssertEqual((fatal as? APIError)?.code, code, "\(code) must not fall back")
        }

        // `server_unavailable` is the open handshake timing out on the daemon's
        // single-threaded app loop, or a shutdown. The daemon read no frame, so the
        // fallback must complete the send rather than aborting the whole batch.
        XCTAssertNil(
            HerdrClient.fatalStreamOpenError(
                GramUploadChannel.ChannelError.remoteError(
                    APIError(
                        code: "server_unavailable",
                        message: "timed out waiting for app response after 5000 ms"))),
            "an app-dispatch timeout must fall back, not fail the send")
    }

    /// A file that SHRANK between the stat and the read must still finish at 100%.
    /// The stat is the only size the uploader has up front, so a bar driven by it
    /// would stop short — and if the last chunk lands exactly on `reportStep`, the
    /// throttle's own bookkeeping would emit no terminal report at all.
    func testGramUploadFromDiskProgressEndsAtTheBytesActuallyRead() async throws {
        final class Shrinker: HerdrTransport, @unchecked Sendable {
            let url: URL
            let keep: Int
            private var truncated = false
            init(url: URL, keep: Int) {
                self.url = url
                self.keep = keep
            }
            func roundTrip(_ requestLine: String) async throws -> String {
                if !truncated {
                    truncated = true
                    // Shrink the file after its first chunk has been read, which is
                    // exactly the window the stat cannot see.
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: UInt64(keep))
                    try handle.close()
                }
                return #"{"id":"x","result":{"type":"ok"}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let chunkBytes = HerdrClient.gramUploadChunkBytes
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-shrink-\(UUID().uuidString).bin")
        try Data(repeating: 4, count: chunkBytes * 4).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reports = Reports()
        _ = try await HerdrClient(transport: Shrinker(url: url, keep: chunkBytes * 2))
            .gramUploadFile(fileURL: url) { sent, total in
                reports.append(sent: sent, total: total)
            }

        let observed = reports.snapshot()
        let last = try XCTUnwrap(observed.last)
        XCTAssertEqual(
            last.sent, last.total,
            "the final report must land on 100%, got \(last.sent)/\(last.total)")
        XCTAssertLessThan(last.sent, chunkBytes * 4, "the file shrank, so fewer bytes were read")
        XCTAssertEqual(observed.map(\.sent), observed.map(\.sent).sorted(), "progress must be monotonic")
    }
}
