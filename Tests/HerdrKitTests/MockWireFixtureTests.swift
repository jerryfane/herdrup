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

    func testMockAgentListDecodesRealisticStatuses() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        XCTAssertEqual(agents.count, 9, "mock agent.list did not decode to 9 agents (8 live + 1 archived)")
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
        XCTAssertEqual(counts[.needsYou], 2)
        XCTAssertEqual(counts[.stopped], 1)
        XCTAssertEqual(counts[.working], 1)
        XCTAssertEqual(counts[.idle], 4, "the done agent should fold into idle, making IDLE · 4")
        XCTAssertEqual(list.needsYouCount, 2, "header would show the wrong 'N need you'")
        // The archived fixture agent is partitioned OUT of the live sections (which still
        // sum to 8) and into its own collapsed section.
        XCTAssertEqual(list.rows.count, 8, "archived agents must not inflate the live rows")
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
    /// GramMessage flags the Gram page renders on (unread, open-queue, grabbed,
    /// direct) must resolve correctly. Optional fields (`to`, `grabbed_by`) are
    /// omitted in JSON when absent — decoding must yield nil, not fail.
    func testMockGramListDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let messages = try await client.gramList()
        XCTAssertEqual(messages.count, 5, "gram.list fixture did not decode to 5 messages")

        // Newest first: the unread agent->owner digest leads.
        let first = try XCTUnwrap(messages.first)
        XCTAssertEqual(first.id, "g1")
        XCTAssertEqual(first.direction, .agentToOwner)
        XCTAssertEqual(first.from, "trend-scout")
        XCTAssertTrue(first.isFromAgent)
        XCTAssertTrue(first.isUnread, "an agent->owner message with read_by_owner:false is unread")
        XCTAssertNil(first.to)
        XCTAssertNil(first.grabbedBy)

        // An unclaimed shared queue post (no `to`, no `grabbed_by`).
        let queue = try XCTUnwrap(messages.first { $0.id == "g2" })
        XCTAssertEqual(queue.direction, .ownerToAgent)
        XCTAssertNil(queue.to)
        XCTAssertNil(queue.grabbedBy)
        XCTAssertTrue(queue.isOpenQueueItem)

        // A grabbed queue item is no longer open.
        let grabbed = try XCTUnwrap(messages.first { $0.id == "g3" })
        XCTAssertEqual(grabbed.grabbedBy, "herdr-app")
        XCTAssertFalse(grabbed.isOpenQueueItem)

        // A direct message carries `to`.
        let direct = try XCTUnwrap(messages.first { $0.id == "g4" })
        XCTAssertEqual(direct.to, "clientloop")
        XCTAssertNil(direct.grabbedBy)

        // Exactly one unread → the header badge shows 1.
        XCTAssertEqual(messages.filter { $0.isUnread }.count, 1)
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
    /// not a failure — so the row shows a chip only when there is one.
    func testMockGramListDecodesFileAttachment() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let messages = try await client.gramList()

        let withFile = try XCTUnwrap(messages.first { $0.id == "g5" })
        let file = try XCTUnwrap(withFile.file, "g5 should carry a file")
        XCTAssertEqual(file.name, "vetrina-live.png")
        XCTAssertEqual(file.mime, "image/png")
        XCTAssertEqual(file.size, 48213)

        let noFile = try XCTUnwrap(messages.first { $0.id == "g1" })
        XCTAssertNil(noFile.file, "a message without a file must decode to nil")
    }

    /// `gram.get_file` returns the bytes inline (base64); the client decodes them.
    func testMockGramGetFileDecodes() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let (name, mime, data) = try await client.gramGetFile(id: "g5")
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
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs"},
      {"pane_id":"w3:p1","name":"clientloop","agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold"},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","name":"discovery","agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"},
      {"pane_id":"w5:p1","name":"huurjacht","agent":"claude","agent_status":"idle","cwd":"/root/huurjacht","terminal_title_stripped":"pararius scrape","archived":{"at":"2026-08-26T18:00:00Z","by":"jerry","reason":"parked for the weekend"}}
    ]}}
    """#

    /// The census the App's mock render passes (MockTransport.demoLivePaneIDs).
    /// Excludes w2:p1 so it groups STOPPED via liveness. Keep in sync with the App.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2",
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

    /// A `gram.list` owner view: unread + read agent->owner messages, an unclaimed
    /// shared queue post, a grabbed one, and a direct message — newest first. Keep in
    /// sync with the App's MockTransport.gramList.
    static let gramList = #"""
    {"id":"mock","result":{"type":"gram_list","messages":[
      {"id":"g1","direction":"agent_to_owner","from":"trend-scout","text":"Digest ready: 7 trends, 2 need your call.","created_unix_ms":1723000005000,"read_by_owner":false},
      {"id":"g2","direction":"owner_to_agent","from":"owner","text":"Anyone free to triage the failing CI?","created_unix_ms":1723000004000,"read_by_owner":true},
      {"id":"g3","direction":"owner_to_agent","from":"owner","text":"Rebase the vetrina branch onto main.","grabbed_by":"herdr-app","grabbed_unix_ms":1723000004500,"created_unix_ms":1723000003000,"read_by_owner":true},
      {"id":"g4","direction":"owner_to_agent","from":"owner","to":"clientloop","text":"Ship the Amigo POC scaffold today.","created_unix_ms":1723000002000,"read_by_owner":true},
      {"id":"g5","direction":"agent_to_owner","from":"vetrina","text":"Deployed vetrina.dev — it is live.","created_unix_ms":1723000001000,"read_by_owner":true,"file":{"name":"vetrina-live.png","size":48213,"mime":"image/png","sha256":"9f2c0a1b7d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"}}
    ]}}
    """#

    /// A canned `gram.post` echo (`type: gram_sent`). Keep in sync with the App's
    /// MockTransport.gramPosted.
    static let gramPosted =
        #"{"id":"mock","result":{"type":"gram_sent","message":{"id":"gp1","direction":"owner_to_agent","from":"owner","text":"(sent)","created_unix_ms":1723000006000,"read_by_owner":true}}}"#

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
