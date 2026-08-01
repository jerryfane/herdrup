import XCTest
@testable import HerdrKit

/// Offline tests — no server required.
final class WireTests: XCTestCase {
    func testDecodesRealAgentPayload() throws {
        // Captured verbatim from a live server (build d293951f).
        let json = """
        {"id":"x","result":{"agents":[{"agent":"claude","agent_status":"working",
        "composer":{"state":"draft_present","attempt_id":"cmp-18c7920a7e91efaf-00000169",
        "evidence":{"provenance":"agent_prompt","region":"text","cursor":"draft",
        "style":"unavailable","frame_stable":true}},
        "cwd":"/root/gitmoot","focused":true,"interactive_ready":true,"name":"jarvis",
        "pane_id":"w6536a4e5b44342:p3W","revision":5,"state_change_seq":987,
        "tab_id":"w6536a4e5b44342:tF","terminal_id":"term_657e7a8f599461",
        "terminal_title_stripped":"Initialize Jarvis fleet coordinator session",
        "turn":176,"turn_epoch":1785502344001894787,
        "workspace_id":"w6536a4e5b44342"}]}}
        """
        let env = try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8))
        let agent = try XCTUnwrap(env.result.agents.first)

        XCTAssertEqual(agent.paneID, "w6536a4e5b44342:p3W")
        XCTAssertEqual(agent.displayName, "jarvis")
        XCTAssertEqual(agent.revision, 5)
        XCTAssertEqual(agent.stateChangeSeq, 987)
        XCTAssertTrue(agent.isWorking)
        // The composer surface that makes a stranded draft visible.
        XCTAssertTrue(try XCTUnwrap(agent.composer).hasUnsentDraft)
        XCTAssertEqual(agent.composer?.evidence?.frameStable, true)
    }

    func testDisplayNameFallsBackWhenUnnamed() throws {
        let json = """
        {"id":"x","result":{"agents":[{"pane_id":"w1:p1",
        "terminal_title_stripped":"some shell"}]}}
        """
        let env = try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8))
        XCTAssertEqual(env.result.agents.first?.displayName, "some shell")
    }

    func testClassifySubscriptionAck() {
        let line = #"{"id":"sub","result":{"type":"subscription_started"}}"#
        XCTAssertEqual(HerdrClient.classify(line), .subscriptionStarted)
    }

    func testClassifyEventCarriesPaneID() {
        let line = #"{"event":{"type":"pane.turn_completed","pane_id":"w1:p2"}}"#
        guard case .event(let kind, let pane, _) = HerdrClient.classify(line) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(kind, "pane.turn_completed")
        XCTAssertEqual(pane, "w1:p2")
    }

    /// `pane.output_changed` must stay absent: the server rejects it, and shipping
    /// it would let the UI subscribe to an output tick that never arrives.
    func testOutputChangedIsNotSubscribable() {
        XCTAssertNil(SubscriptionType(rawValue: "pane.output_changed"))
        XCTAssertNotNil(SubscriptionType(rawValue: "pane.output_matched"))
        XCTAssertNotNil(SubscriptionType(rawValue: "pane.agent_status_changed"))
    }

    /// Pane-scoped subscriptions must serialise `pane_id`; omitting it is a
    /// server-side rejection, so the encoding is load-bearing.
    func testSubscriptionEncodesPaneID() throws {
        let data = try JSONEncoder().encode(Subscription(.paneTurnCompleted, paneID: "w1:p2"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "pane.turn_completed")
        XCTAssertEqual(obj["pane_id"] as? String, "w1:p2")
    }
}

/// Live tests — exercised against a real herdr server when one is present.
/// Skipped (not failed) when there is no socket, so CI without a server is honest
/// about what it did not cover.
final class LiveServerTests: XCTestCase {
    private var socketPath: String?

    override func setUp() {
        super.setUp()
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        socketPath = FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func client() throws -> HerdrClient {
        let path = try XCTUnwrap(socketPath, "no herdr socket present")
        return HerdrClient(transport: UnixSocketTransport(path: path))
    }

    func testAgentListReturnsChangeCounters() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let agents = try await client().agentList()
        XCTAssertFalse(agents.isEmpty, "a live server should report at least one agent")
        let agent = try XCTUnwrap(agents.first)
        XCTAssertFalse(agent.paneID.isEmpty)
        // Revision-gated refresh depends on these being present.
        XCTAssertNotNil(agent.stateChangeSeq)
    }

    func testAnsiReadCarriesEscapeSequences() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let c = try client()
        let agents = try await c.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let ansi = try await c.read(pane: pane, source: .visible, format: .ansi, lines: 40)
        let text = try await c.read(pane: pane, source: .visible, format: .text, lines: 40)
        XCTAssertTrue(ansi.text.contains("\u{1B}["), "ansi read should carry CSI sequences")
        XCTAssertFalse(text.text.contains("\u{1B}["), "text read should be unstyled")
    }

    /// The panel ruled reflowed transcript the default reading surface, because
    /// the API exposes no pane geometry and the phone cannot resize the PTY.
    func testDefaultReadSourceIsReflowedTranscript() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let c = try client()
        let agents = try await c.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let defaulted = try await c.read(pane: pane, lines: 40)
        XCTAssertFalse(defaulted.text.isEmpty)
        // Styling must survive the reflowed source, else the default costs colour.
        let styled = try await c.read(pane: pane, source: .recentUnwrapped, format: .ansi, lines: 40)
        XCTAssertTrue(styled.text.contains("\u{1B}["), "recent_unwrapped+ansi must preserve styling")
    }

    /// Guards the measured fact that detection ignores an ansi request.
    func testDetectionWithAnsiIsRefusedLocally() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let c = try client()
        let agents = try await c.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        do {
            _ = try await c.read(pane: pane, source: .detection, format: .ansi)
            XCTFail("expected the detection+ansi combination to be refused")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "herdrkit_invalid_read")
        }
    }

    /// The control socket is single-shot. This drives a raw socket rather than the
    /// transport, because the transport deliberately offers no way to reuse a
    /// connection — the property has to be asserted against the server directly.
    ///
    /// The first request answers; the second on the SAME connection gets nothing
    /// back, because the server closed after responding. If this test ever fails,
    /// herdr has gained a persistent command channel and the per-request
    /// connection (and per-request SSH channel) can be removed.
    func testCommandSocketIsSingleShotOnOneConnection() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let path = try XCTUnwrap(socketPath)

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0, "should connect to the herdr socket")

        func send(_ line: String) {
            var b = Array(line.utf8); b.append(UInt8(ascii: "\n"))
            _ = b.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        }
        func readSome() -> Int {
            var buf = [UInt8](repeating: 0, count: 4096)
            return buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
        }
        /// Drains one full newline-terminated response. A single read() is not
        /// enough: the stream can split the payload from its trailing newline,
        /// and a leftover byte would otherwise look like a second response.
        func drainOneResponse() -> Int {
            var total = 0
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                if n <= 0 { return total }
                total += n
                if buf[0..<n].contains(UInt8(ascii: "\n")) { return total }
            }
        }

        // Ignore SIGPIPE so the second write returns EPIPE instead of killing us.
        signal(SIGPIPE, SIG_IGN)

        send(#"{"id":"a","method":"ping","params":{}}"#)
        XCTAssertGreaterThan(drainOneResponse(), 0, "first request should be answered")

        send(#"{"id":"b","method":"ping","params":{}}"#)
        // A clean FIN reads 0; if our write raced the close, the peer resets and
        // read returns -1 (ECONNRESET). Both mean "no second response arrived",
        // which is the property under test. Asserting == 0 alone is a ~50% flake.
        XCTAssertLessThanOrEqual(
            readSome(), 0,
            "server must not answer a second request on the same connection"
        )
    }

    func testSubscribeAcknowledgesAndStaysOpen() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let c = try client()
        let agents = try await c.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let stream = c.subscribe([
            Subscription(.paneAgentStatusChanged, paneID: pane),
            Subscription(.paneTurnCompleted, paneID: pane),
        ])
        var sawAck = false
        for try await line in stream {
            if line == .subscriptionStarted { sawAck = true; break }
        }
        XCTAssertTrue(sawAck, "server should acknowledge the subscription")
    }
}
