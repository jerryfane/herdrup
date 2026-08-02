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

    /// herdr-ios#2. The previous version broke out of the loop at the
    /// acknowledgement, so a server that answered `subscription_started` and
    /// then closed immediately would have passed — the exact behaviour the name
    /// promises to rule out.
    ///
    /// That the event socket is PERSISTENT is load-bearing: it is why
    /// `HerdrTransport` has two methods, why the transport plans one long-lived
    /// event channel alongside N ephemeral request channels, and it is written
    /// in the README as measured fact. Nothing in the suite noticed if it
    /// stopped being true.
    func testSubscribeAcknowledgesAndStaysOpen() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let c = try client()
        let agents = try await c.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let stream = c.subscribe([
            Subscription(.paneAgentStatusChanged, paneID: pane),
            Subscription(.paneTurnCompleted, paneID: pane),
        ])

        let seen = await observeSubscription(stream, idleWindow: 1.5)
        XCTAssertTrue(seen.sawAck, "server should acknowledge the subscription")
        XCTAssertFalse(
            seen.endedEarly,
            "the event stream must still be open after an idle interval; it closed instead"
        )
    }

    /// Proves the assertion above can actually fail. A stub that acknowledges
    /// and then closes is exactly the server behaviour the old test could not
    /// distinguish from a healthy one.
    func testTheStayOpenCheckCatchesAServerThatClosesAfterTheAck() async throws {
        let stream = HerdrClient(transport: AckThenCloseTransport())
            .subscribe([Subscription(.paneTurnCompleted, paneID: "p1")])
        let seen = await observeSubscription(stream, idleWindow: 1.0)
        XCTAssertTrue(seen.sawAck, "the stub does acknowledge")
        XCTAssertTrue(
            seen.endedEarly,
            "a stream that closes after the ack must be detected as ended early"
        )
    }
}

/// herdr-ios#1 — cancelling a subscription must interrupt the blocking read.
///
/// `Task.cancel()` only sets a flag; it cannot unblock `read(2)`. An idle
/// `events.subscribe` stream is the worst case: nothing arrives, so a cancelled
/// reader would hold its descriptor and a cooperative-pool thread indefinitely.
final class StreamCancellationTests: XCTestCase {
    private var socketPath: String? {
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // NOTE: the obvious test here — cancel, then assert the consumer's
    // `for await` loop exits promptly — is VACUOUS and was removed after a
    // mutation showed it passing without the fix. AsyncThrowingStream ends the
    // loop on cancellation regardless of what the producer is doing, so it
    // observes the stream closing, not the blocking read unwinding. The
    // descriptor count below is the only assertion that distinguishes them.

    /// Repeated subscribe/cancel cycles must not accumulate descriptors — the
    /// leak the iOS foreground/background lifecycle would drive.
    func testRepeatedSubscribeCancelDoesNotLeakDescriptors() async throws {
        try XCTSkipIf(socketPath == nil, "no live herdr server")
        let path = try XCTUnwrap(socketPath)
        let client = HerdrClient(transport: UnixSocketTransport(path: path))
        let agents = try await client.agentList()
        let pane = try XCTUnwrap(agents.first).paneID

        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? -1
        }
        // Warm once so one-off allocations are not counted as growth.
        for _ in 0..<2 {
            let t = Task { for try await _ in client.subscribe([Subscription(.paneTurnCompleted, paneID: pane)]) {} }
            try await Task.sleep(nanoseconds: 200_000_000)
            t.cancel()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let before = openDescriptors()
        try XCTSkipIf(before < 0, "/proc/self/fd unavailable")

        for _ in 0..<8 {
            let t = Task { for try await _ in client.subscribe([Subscription(.paneTurnCompleted, paneID: pane)]) {} }
            try await Task.sleep(nanoseconds: 150_000_000)
            t.cancel()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let after = openDescriptors()
        XCTAssertLessThanOrEqual(
            after - before, 2,
            "8 subscribe/cancel cycles leaked \(after - before) descriptors"
        )
    }
}


/// What a subscription did during an observation window.
struct SubscriptionObservation {
    var sawAck = false
    /// The stream terminated before the idle window elapsed. For a persistent
    /// event channel that is a failure, not a completion.
    var endedEarly = false
}

/// Consumes a subscription until either the idle window elapses — meaning the
/// stream is still open — or the stream ends, meaning it is not.
///
/// Waiting for the window to pass is the whole point: any check that stops at
/// the acknowledgement cannot tell a persistent stream from one that closed
/// immediately afterwards.
func observeSubscription(
    _ stream: AsyncThrowingStream<StreamLine, Error>,
    idleWindow: TimeInterval
) async -> SubscriptionObservation {
    let box = ObservationBox()
    let consumer = Task {
        do {
            for try await line in stream where line == .subscriptionStarted {
                box.markAck()
            }
            box.markEnded()          // stream finished on its own
        } catch {
            box.markEnded()          // a throw is also an end
        }
    }
    try? await Task.sleep(nanoseconds: UInt64(idleWindow * 1_000_000_000))
    let result = box.snapshot()
    consumer.cancel()
    return result
}

final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation = SubscriptionObservation()

    func markAck() { lock.lock(); observation.sawAck = true; lock.unlock() }
    func markEnded() { lock.lock(); observation.endedEarly = true; lock.unlock() }
    func snapshot() -> SubscriptionObservation {
        lock.lock(); defer { lock.unlock() }
        return observation
    }
}

/// Acknowledges a subscription and then closes — the server behaviour the old
/// test could not distinguish from a healthy persistent stream.
struct AckThenCloseTransport: HerdrTransport {
    func roundTrip(_ requestLine: String) async throws -> String {
        #"{"id":"x","result":{}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(#"{"id":"sub","result":{"type":"subscription_started"}}"#)
            continuation.finish()
        }
    }
}
