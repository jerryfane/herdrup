import XCTest
import Foundation
@testable import HerdrKit

/// Validates the JSON the app's DEBUG screenshot-mock transport returns actually
/// decodes through the real `HerdrClient` path — so the iOS mock (which cannot be
/// compiled/run on Linux) embeds wire JSON proven correct here, not guessed.
/// Keep these fixtures byte-identical to App/HerdrApp.swift's MockTransport.
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
            if requestLine.contains("gram.upload_chunk") { return MockWireFixtures.okResult }
            if requestLine.contains("gram.delete") { return MockWireFixtures.okResult }
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
    /// MockTransport embeds the same two fixtures verbatim.
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
              case .reset(_, let epoch, let cols, let rows, let data, let lagged) = frame else {
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

        guard case .reset(_, _, _, _, _, let lagged) =
            try frame(#"{"stream":"pane.bytes","frame":"reset","seq":1,"epoch":7,"cols":80,"rows":24,"data_b64":"","lagged":true}"#) else {
            return XCTFail("lagged reset frame did not decode")
        }
        XCTAssertTrue(lagged)

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
        final class Capture: HerdrTransport, @unchecked Sendable {
            var lastLine = ""
            func roundTrip(_ requestLine: String) async throws -> String {
                lastLine = requestLine
                return #"{"id":"x","result":{"type":"agent_restarted","agent":{"pane_id":"w1:p1"}}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let capture = Capture()
        let client = HerdrClient(transport: capture)

        _ = try await client.restartAgent(target: "w1:p1")
        XCTAssertTrue(capture.lastLine.contains("\"target\":\"w1:p1\""), "target must be sent")
        XCTAssertFalse(capture.lastLine.contains("account"),
                       "a no-account restart must not send an account key: \(capture.lastLine)")

        _ = try await client.restartAgent(target: "w1:p1", account: "acc-claude-2")
        XCTAssertTrue(capture.lastLine.contains("\"account\":\"acc-claude-2\""),
                      "swapping must send the account id: \(capture.lastLine)")
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
        XCTAssertEqual(messages.count, 9, "gram.list fixture did not decode to 9 messages")
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

        // A grabbed shared-queue post (no `to`) is no longer open.
        let grabbed = try XCTUnwrap(messages.first { $0.id == "g5" })
        XCTAssertEqual(grabbed.direction, .ownerToAgent)
        XCTAssertNil(grabbed.to)
        XCTAssertEqual(grabbed.grabbedBy, "ci-watch")
        XCTAssertFalse(grabbed.isOpenQueueItem)

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
        XCTAssertEqual(inbox.messages.count, 9)
        XCTAssertEqual(inbox.nextCursor, "g9", "the head page says there is more")

        var generation = inbox.generation
        let second = try await client.gramList(limit: 40, beforeID: "g9")
        XCTAssertTrue(inbox.appendPage(second, generation: generation))
        XCTAssertEqual(inbox.messages.count, 33, "the second page holds 24 rows")
        XCTAssertEqual(Array(inbox.messages.map(\.id)[9...]), (1...24).map { "go\($0)" })
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

    /// The upload + delete round-trips decode their `type: ok` replies without
    /// throwing, and the upload mints a safe `app-` id.
    func testMockGramUploadAndDeleteSucceed() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let uploadID = try await client.gramUploadFile(Data("hello".utf8))
        XCTAssertTrue(uploadID.hasPrefix("app-"), "upload id should be a safe app- token")
        try await client.gramDelete(id: "g5")
    }

    /// A worst-case slash-heavy chunk (all 0xFF → base64 is entirely "/") must not
    /// inflate the request line: the request encoder must emit unescaped "/", or a
    /// binary chunk would blow the SSH command-size cap. Guards the chunk-size math.
    func testGramUploadChunkRequestStaysCompactForSlashHeavyData() async throws {
        final class Capture: HerdrTransport, @unchecked Sendable {
            var maxLen = 0
            func roundTrip(_ requestLine: String) async throws -> String {
                maxLen = max(maxLen, requestLine.utf8.count)
                return #"{"id":"x","result":{"type":"ok"}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let capture = Capture()
        let client = HerdrClient(transport: capture)
        let data = Data(repeating: 0xFF, count: HerdrClient.gramUploadChunkBytes)
        _ = try await client.gramUploadFile(data)
        // ~49 KiB raw → ~65.5 KB unescaped base64 + envelope. Escaping every "/"
        // would nearly double it; assert it stays well under the point where the
        // outer argv base64 (~1.33x) would breach the 120 KB command cap.
        XCTAssertLessThan(
            capture.maxLen, 80_000,
            "slash escaping inflated the upload request line to \(capture.maxLen) bytes")
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

    /// The SAME slash-escaping property for the FROM-DISK path. `Capture` is not a
    /// `CitadelTransport`, so `gramOpenUploadChannel` returns nil and this exercises
    /// the per-chunk fallback — the CI-visible proof that reading from a file did not
    /// regress the request-line size the in-memory path guards above.
    func testGramUploadFromDiskRequestStaysCompactForSlashHeavyData() async throws {
        final class Capture: HerdrTransport, @unchecked Sendable {
            var maxLen = 0
            func roundTrip(_ requestLine: String) async throws -> String {
                maxLen = max(maxLen, requestLine.utf8.count)
                return #"{"id":"x","result":{"type":"ok"}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-slashes-\(UUID().uuidString).bin")
        try Data(repeating: 0xFF, count: HerdrClient.gramStreamChunkBytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = Capture()
        let client = HerdrClient(transport: capture)
        _ = try await client.gramUploadFile(fileURL: url)
        XCTAssertLessThan(
            capture.maxLen, 80_000,
            "slash escaping inflated the from-disk request line to \(capture.maxLen) bytes")
    }

    /// The from-disk fallback path must walk the file in CONTIGUOUS chunks: staging
    /// is append-only, so the daemon rejects any offset that is not the running
    /// staged size. A gap (or a repeat) is the bug this pins.
    func testGramUploadFromDiskSendsContiguousOffsets() async throws {
        final class Capture: HerdrTransport, @unchecked Sendable {
            struct Chunk: Decodable {
                struct Params: Decodable {
                    let offset: UInt64
                    let dataBase64: String
                    enum CodingKeys: String, CodingKey {
                        case offset
                        case dataBase64 = "data_base64"
                    }
                }
                let method: String
                let params: Params
            }
            var offsets: [UInt64] = []
            var bytes = Data()
            func roundTrip(_ requestLine: String) async throws -> String {
                if let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(requestLine.utf8)),
                    chunk.method == "gram.upload_chunk"
                {
                    offsets.append(chunk.params.offset)
                    bytes.append(Data(base64Encoded: chunk.params.dataBase64) ?? Data())
                }
                return #"{"id":"x","result":{"type":"ok"}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let chunkBytes = HerdrClient.gramUploadChunkBytes
        let payload = Data((0..<(chunkBytes * 2 + 7)).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-offsets-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = Capture()
        let client = HerdrClient(transport: capture)
        _ = try await client.gramUploadFile(fileURL: url)

        XCTAssertEqual(
            capture.offsets, [0, UInt64(chunkBytes), UInt64(chunkBytes * 2)],
            "offsets must be contiguous multiples of the chunk size")
        XCTAssertEqual(capture.bytes, payload, "the streamed bytes must reassemble the file")
    }

    /// Progress is reported from the file's own size, once at 0 and once at the end,
    /// so a determinate progress bar cannot be driven past 100% or left short.
    func testGramUploadFromDiskReportsProgressToTotal() async throws {
        final class Sink: HerdrTransport, @unchecked Sendable {
            func roundTrip(_ requestLine: String) async throws -> String {
                #"{"id":"x","result":{"type":"ok"}}"#
            }
            func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let payload = Data(repeating: 7, count: HerdrClient.gramUploadChunkBytes + 128)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-upload-progress-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reports = Reports()
        _ = try await HerdrClient(transport: Sink()).gramUploadFile(fileURL: url) { sent, total in
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

/// THE FIXTURES. Duplicated verbatim in App/HerdrApp.swift's MockTransport (the
/// app target can't be compiled on Linux, so this is the only place the JSON is
/// machine-checked). If you change one, change both.
enum MockWireFixtures {
    static let agentList = #"""
    {"id":"mock","result":{"type":"agent_list","agents":[
      {"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"},
      {"pane_id":"w1:p2","name":"vetrina","agent":"codex","agent_status":"blocked","cwd":"/root/vetrina","terminal_title_stripped":"overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"trend-scout","agent":"codex","agent_status":"idle","cwd":"/root/trend-scout","terminal_title_stripped":"exited, code 1"},
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs","account":"claudecrazy","account_config_dir":"/root/.claude-9"},
      {"pane_id":"w3:p1","name":"clientloop","agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold","account":"retired-account","account_unresolved":true},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","name":"discovery","agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"},
      {"pane_id":"mcb-air/w1:p9","name":"mcb-air/mcb-air","agent":"omp","agent_status":"unknown","last_known_status":"blocked","machine_id":"mcb-air","reachability":"degraded","cwd":"/Users/jerry/omp-workspace","terminal_title_stripped":"clone repo and help deimos"},
      {"pane_id":"w5:p1","name":"huurjacht","agent":"claude","agent_status":"idle","cwd":"/root/huurjacht","terminal_title_stripped":"pararius scrape","archived":{"at":"2026-08-26T18:00:00Z","by":"jerry","reason":"parked for the weekend"}}
    ]}}
    """#

    /// The census the App's mock render passes (MockTransport.demoLivePaneIDs).
    /// Excludes w2:p1 so it groups STOPPED via liveness. Keep in sync with the App.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2", "mcb-air/w1:p9",
    ]

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach jarvis\n\n> Ran 146 tests, 0 failures\n> Edited SessionRecoveryTests.swift  +18 -4\n\nRun `swift test` with -Xswiftc -warnings-as-errors?\n  1. yes\n  2. no, skip it\n>\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#

    /// An `accounts.list` owner view: two claude accounts (one active-with-usage, one
    /// exhausted), a codex account with tier-only usage (no percent), and a kimi
    /// account with no usage at all. Exercises every optionality of AccountUsage. Keep
    /// in sync with the App's MockTransport.accountsList.
    static let accountsList = #"""
    {"id":"mock","result":{"type":"accounts_list","accounts":[
      {"id":"acc-claude-1","kind":"claude","label":"Claude Max (work)","active":true,"email":"work@example.com","usage":{"source":"live","windows":[{"label":"5h","used_percent":42,"resets_at":"2000000000","status":"ok"},{"label":"weekly","used_percent":68,"resets_at":"2030-01-15T18:00:00Z","status":"ok"}],"primary_used_percent":42,"secondary_used_percent":68,"resets_at":"2026-08-20T18:00:00Z","plan":"Max"}},
      {"id":"acc-claude-2","kind":"claude","label":"Claude Pro (personal)","active":false,"email":"personal@example.com","usage":{"primary_used_percent":100,"secondary_used_percent":100,"plan":"Pro"}},
      {"id":"acc-codex-1","kind":"codex","label":"Codex (team)","active":true,"email":"team@example.com","usage":{"tier":"Plus"}},
      {"id":"acc-kimi-1","kind":"kimi","label":"Kimi","active":true}
    ]}}
    """#

    /// A `gram.list` owner view, newest first: direct owner posts, a grabbed shared-queue
    /// post, read and unread agent->owner messages, federated senders with a machine label,
    /// a code fence with a zip attachment, an image-only message and a long report. Keep in
    /// sync with the App's MockTransport.gramList.
    static let gramList = #"""
    {"id":"mock","result":{"type":"gram_list","messages":[
      {"id":"g1","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Great, ship it.","created_unix_ms":1723041360000,"read_by_owner":true},
      {"id":"g2","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/clientloop","machine_label":"hetzner-1","text":"Scaffold is up. Run it with:\n```\ncd ~/src/amigo-poc && pnpm dev\n```","created_unix_ms":1723041240000,"read_by_owner":false,"file":{"name":"amigo-poc-scaffold.zip","size":1363149,"mime":"application/zip","sha256":"3d5e7f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c"}},
      {"id":"g3","direction":"agent_to_owner","from":"vetrina","text":"","created_unix_ms":1723041160000,"read_by_owner":false,"file":{"name":"vetrina-live.png","size":421888,"mime":"image/png","sha256":"9f2c0a1b7d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"}},
      {"id":"g4","direction":"agent_to_owner","from":"vetrina","text":"Deployed. vetrina.dev is live.\n• Build 412 passed in 3m 08s\n• 2 migrations ran clean\n• Lighthouse 98 on mobile\n• CDN cache purged, EU and US\n• Sitemap resubmitted\n• Stripe webhooks verified\n• Sentry: no new issues\n• Uptime check green for 10 min\nRollback is one command away:\nherdr rollback vetrina 411","created_unix_ms":1723041130000,"read_by_owner":false},
      {"id":"g5","direction":"owner_to_agent","from":"owner","text":"Who can triage the failing CI?","grabbed_by":"ci-watch","grabbed_unix_ms":1722970020000,"created_unix_ms":1722969900000,"read_by_owner":true},
      {"id":"g6","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/trend-scout","machine_label":"hetzner-1","text":"Digest ready: 7 trends, 2 need your call.","created_unix_ms":1722969600000,"read_by_owner":true},
      {"id":"g7","direction":"agent_to_owner","from":"vetrina","text":"On it. Waiting on CI.","created_unix_ms":1722968460000,"read_by_owner":true},
      {"id":"g8","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Good. Deploy when CI is green.","created_unix_ms":1722968400000,"read_by_owner":true},
      {"id":"g9","direction":"agent_to_owner","from":"vetrina","text":"Picked up the deploy ticket.\nRebasing onto main first.","created_unix_ms":1722967500000,"read_by_owner":true}
    ]}}
    """#

    /// The paged mock's pages. Keep byte-identical to MockTransport.gramOlderRows,
    /// gramOldestRows and gramListAnswer(rows:hasMore:) in App/HerdrApp.swift.
    static let gramOlderRows = #"""
      {"id":"go1","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Thanks. Take the deploy ticket next.","created_unix_ms":1722884400000,"read_by_owner":true},
      {"id":"go2","direction":"agent_to_owner","from":"vetrina","text":"Smoke tests pass on staging.\nAll 38 checks green.","created_unix_ms":1722884100000,"read_by_owner":true},
      {"id":"go3","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Run the smoke tests too.","created_unix_ms":1722883800000,"read_by_owner":true},
      {"id":"go4","direction":"agent_to_owner","from":"vetrina","text":"Added the rollback step.\nStaging is green.","created_unix_ms":1722883500000,"read_by_owner":true},
      {"id":"go5","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Add a rollback step before the migration.","created_unix_ms":1722883200000,"read_by_owner":true},
      {"id":"go6","direction":"agent_to_owner","from":"vetrina","text":"Checklist is in docs/release.md.\nEight steps, two need a sign-off.","created_unix_ms":1722882900000,"read_by_owner":true},
      {"id":"go7","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Draft the release checklist first.","created_unix_ms":1722882600000,"read_by_owner":true},
      {"id":"go8","direction":"agent_to_owner","from":"vetrina","text":"Bundle size is down 14 percent.\nThe image pipeline was the culprit.","created_unix_ms":1722882300000,"read_by_owner":true},
      {"id":"go9","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Nice. Keep an eye on the cold start.","created_unix_ms":1722882000000,"read_by_owner":true},
      {"id":"go10","direction":"agent_to_owner","from":"vetrina","text":"Cold start is 1.2 s on a mid-range phone.\nWithin budget.","created_unix_ms":1722881700000,"read_by_owner":true},
      {"id":"go11","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"What changed in the cache layer?","created_unix_ms":1722881400000,"read_by_owner":true},
      {"id":"go12","direction":"agent_to_owner","from":"vetrina","text":"Swapped the LRU for a size-bounded one.\nEvictions dropped by half.","created_unix_ms":1722881100000,"read_by_owner":true},
      {"id":"go13","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Good. Write that up for the changelog.","created_unix_ms":1722880800000,"read_by_owner":true},
      {"id":"go14","direction":"agent_to_owner","from":"vetrina","text":"Changelog entry drafted.\nIt is in the release branch.","created_unix_ms":1722880500000,"read_by_owner":true},
      {"id":"go15","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Did the flaky login test settle?","created_unix_ms":1722880200000,"read_by_owner":true},
      {"id":"go16","direction":"agent_to_owner","from":"vetrina","text":"It was a timezone bug in the fixture.\nFixed and green 20 runs in a row.","created_unix_ms":1722879900000,"read_by_owner":true},
      {"id":"go17","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Great catch. Merge it.","created_unix_ms":1722879600000,"read_by_owner":true},
      {"id":"go18","direction":"agent_to_owner","from":"vetrina","text":"Merged. CI is rebuilding main.","created_unix_ms":1722879300000,"read_by_owner":true},
      {"id":"go19","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Ping me when main is green.","created_unix_ms":1722879000000,"read_by_owner":true},
      {"id":"go20","direction":"agent_to_owner","from":"vetrina","text":"Main is green.\nTagging a release candidate.","created_unix_ms":1722878700000,"read_by_owner":true},
      {"id":"go21","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Hold the tag until the docs land.","created_unix_ms":1722878400000,"read_by_owner":true},
      {"id":"go22","direction":"agent_to_owner","from":"vetrina","text":"Docs PR is open.\nTwo screenshots still to refresh.","created_unix_ms":1722878100000,"read_by_owner":true},
      {"id":"go23","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Start with the release planning.","created_unix_ms":1722877800000,"read_by_owner":true},
      {"id":"go24","direction":"agent_to_owner","from":"vetrina","text":"Older page: release planning starts here.","created_unix_ms":1722877500000,"read_by_owner":true}
    """#

    static let gramOldestRows = #"""
      {"id":"gx1","direction":"agent_to_owner","from":"vetrina","text":"Oldest page: kickoff notes are in the repo.","created_unix_ms":1722796200000,"read_by_owner":true}
    """#

    static func gramListAnswer(rows: [String], hasMore: Bool) -> String {
        #"{"id":"mock","result":{"type":"gram_list","messages":["#
            + rows.joined(separator: ",") + #"],"has_more":"# + (hasMore ? "true" : "false") + "}}"
    }

    static var gramListRows: String {
        let open = gramList.range(of: #""messages":["#)!.upperBound
        let close = gramList.range(of: "]}}", options: .backwards)!.lowerBound
        return String(gramList[open..<close])
    }

    /// A canned `gram.post` echo (`type: gram_sent`). Keep in sync with the App's
    /// MockTransport.gramPosted.
    static let gramPosted =
        #"{"id":"mock","result":{"type":"gram_sent","message":{"id":"gp1","direction":"owner_to_agent","from":"owner","text":"(sent)","created_unix_ms":1723041420000,"read_by_owner":true}}}"#

    /// A canned `gram.get_file` reply (`type: gram_file_content`); the bytes decode
    /// to "hello world". Keep in sync with the App's MockTransport.gramFileContent.
    static let gramFileContent =
        #"{"id":"mock","result":{"type":"gram_file_content","name":"vetrina-live.png","mime":"image/png","size":11,"data_base64":"aGVsbG8gd29ybGQ="}}"#

    /// A canned `type: ok` reply, for `gram.upload_chunk` and `gram.delete`.
    static let okResult = #"{"id":"mock","result":{"type":"ok"}}"#

    // MARK: pane.stream / pane.set_pty_size fixtures (mirrored in App MockTransport)

    /// The `pane.stream` open ack: the geometry-carrying `stream_started` line.
    static let paneStreamAck =
        #"{"id":"mock","result":{"type":"stream_started","pane_id":"w1:p1","epoch":7,"cols":80,"rows":24,"base_seq":0,"resync":true}}"#

    /// The reset seed frame. `data_b64` is a full-screen ANSI snapshot (clear +
    /// home + a demo screen); it decodes to text containing "mock render".
    static let paneStreamReset =
        #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":7,"cols":80,"rows":24,"data_b64":"G1syShtbSBtbMTszODs1OzM5bWhlcmRyG1swbSBsaXZlIHRlcm1pbmFsIOKAlCBtb2NrIHJlbmRlcg0KDQokIGhlcmRyIGFnZW50IGF0dGFjaCBqYXJ2aXMNCj4gUmFuIDE0NiB0ZXN0cywgMCBmYWlsdXJlcw0KDQpbZGVtbyBkYXRhIOKAlCBubyBsaXZlIGNvbm5lY3Rpb25dDQo="}"#

    /// The `pane.set_pty_size` reply. The current server's `PanePtySize` variant is
    /// exactly {pane_id, cols, rows, locked} — no epoch.
    static let panePtySize =
        #"{"id":"mock","result":{"type":"pane_pty_size","pane_id":"w1:p1","cols":80,"rows":24,"locked":false}}"#
}
