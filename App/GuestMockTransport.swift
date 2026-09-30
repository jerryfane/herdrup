#if DEBUG
import Foundation
import HerdrKit

/// A stand-in for the guest-gated daemon behind the relay, for the guest screenshots and
/// UI tests. It answers only the guest allowlist; every other method is recorded in
/// `forbiddenCalls` and refused with `guest_forbidden`, exactly as the host would.
struct GuestMockTransport: HerdrTransport {
    /// `oldHost` is a host older than guest resizing: it refuses `pane.set_pty_size`.
    enum Scenario: String { case running, paused, blocked, oldHost }

    let scenario: Scenario

    init(scenario: Scenario) {
        self.scenario = scenario
        _ = Self.freshGuestSettings
    }

    /// Each launch starts from the guest's default text size, so one test's A+ can't leak
    /// into the next. Once per process: the view that builds this transport re-renders.
    private static let freshGuestSettings: Void =
        UserDefaults.standard.removeObject(forKey: GuestTerminalSize.storageKey)

    static let access = GuestAccess(
        guestID: "g-7f2c",
        guestName: "plotarmordev",
        machineLabel: "Jerry's Mac Studio",
        ownerName: "Jerry",
        agentName: "llm-opt",
        agentTarget: "w1-3",
        endpoint: RelayEndpoint(
            relay: URL(string: "https://relay.herdrup.dev")!,
            hostID: "AAECAwQFBgcICQoLDA0ODw",
            hostPublicKey: Data(repeating: 7, count: 32)),
        acceptedAt: Date(timeIntervalSince1970: 1_790_000_000))

    static let invite = GuestInvite(
        relay: access.endpoint.relay,
        hostID: access.endpoint.hostID,
        hostPublicKey: access.endpoint.hostPublicKey,
        inviteID: "EBESExQVFhcYGRobHB0eHw",
        secret: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8",
        machineLabel: access.machineLabel,
        ownerName: access.ownerName,
        agentName: access.agentName,
        guestName: access.guestName,
        expires: Date(timeIntervalSince1970: 4_102_444_800))

    /// Methods called that a guest may not call (anything but the allowlist), in order.
    /// Read by UI tests via GuestPaneView's DEBUG probe.
    static var forbiddenCalls: [String] { recorder.calls }

    static let allowlist: Set<String> = [
        "ping", "agent.list", "agent.get", "agent.read", "pane.stream", "agent.prompt",
        "gram.upload_chunk", "gram.post", "pane.set_pty_size",
    ]

    private static let recorder = CallRecorder()
    /// The shared agent's PTY: one per process, like the host's, whichever transport value
    /// a re-rendered view built.
    private static let pty = MockPTY()

    private func allows(_ method: String) -> Bool {
        Self.allowlist.contains(method) && !(scenario == .oldHost && method == "pane.set_pty_size")
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard allows(method) else {
            Self.recorder.append(method)
            return Self.errorLine(id: id, code: "guest_forbidden", message: "guests can't call \(method)")
        }
        switch method {
        case "ping":
            return #"{"id":"\#(id)","result":{"type":"pong"}}"#
        case "agent.list":
            return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[\#(sharedAgentJSON),\#(Self.otherAgentJSON)]}}"#
        case "agent.get":
            return #"{"id":"\#(id)","result":{"type":"agent_info","agent":\#(sharedAgentJSON)}}"#
        case "agent.read":
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            return Self.readLine(id: id, text: Self.history + transcript)
        case "agent.prompt", "gram.upload_chunk", "gram.post":
            // Everything that reaches the agent is refused while it isn't running.
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            switch method {
            case "agent.prompt":
                return #"{"id":"\#(id)","result":{"type":"agent_prompted","delivery":"submitted"}}"#
            case "gram.upload_chunk":
                return #"{"id":"\#(id)","result":{"type":"ok"}}"#
            default:
                return #"{"id":"\#(id)","result":{"type":"gram_sent","message":{"id":"gg1","direction":"owner_to_agent","from":"plotarmordev","text":"(sent)","created_unix_ms":1790000100000,"read_by_owner":true}}}"#
            }
        case "pane.set_pty_size":
            if scenario == .paused {
                return Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            }
            // The host's guest bounds; a lock applies the size (a release changes nothing here)
            // and needs the guest's stream open on the pane first.
            let params = Self.object(requestLine)?["params"] as? [String: Any]
            let lock = params?["lock"] as? Bool ?? false
            if lock, !Self.pty.hasStream {
                return Self.errorLine(id: id, code: "guest_no_stream",
                                      message: "open the agent's stream before resizing it")
            }
            if lock, let cols = params?["cols"] as? Int, let rows = params?["rows"] as? Int {
                Self.pty.resize(cols: min(max(cols, 20), 500), rows: min(max(rows, 5), 300),
                                redraw: transcript)
            }
            let applied = Self.pty.geometry
            return #"{"id":"\#(id)","result":{"type":"pane_pty_size","pane_id":"\#(Self.access.agentTarget)","cols":\#(applied.cols),"rows":\#(applied.rows),"locked":\#(lock)}}"#
        default:
            return #"{"id":"\#(id)","result":{}}"#
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard allows(method) else {
            Self.recorder.append(method)
            let refusal = Self.errorLine(id: id, code: "guest_forbidden", message: "guests can't call \(method)")
            return AsyncThrowingStream { continuation in
                continuation.yield(refusal)
                continuation.finish()
            }
        }
        guard method == "pane.stream" else { return AsyncThrowingStream { $0.finish() } }
        if scenario == .paused {
            // The host refuses a stream while the shared agent is not in the foreground.
            let refusal = Self.errorLine(id: id, code: "guest_paused", message: "llm-opt isn't running")
            return AsyncThrowingStream { continuation in
                continuation.yield(refusal)
                continuation.finish()
            }
        }
        // A live stream never ends on its own (an end is a drop the view reconnects from),
        // so hold it open and ping like the daemon does.
        let transcript = transcript
        return AsyncThrowingStream { continuation in
            let token = UUID()
            let grid = Self.pty.attach(continuation, token: token)
            continuation.yield(#"{"id":"\#(id)","result":{"type":"stream_started","pane_id":"w1-3","epoch":3,"cols":\#(grid.cols),"rows":\#(grid.rows),"base_seq":0,"resync":true}}"#)
            continuation.yield(#"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":3,"cols":\#(grid.cols),"rows":\#(grid.rows),"data_b64":"\#(Data(transcript.utf8).base64EncodedString())"}"#)
            let pings = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { break }
                    continuation.yield(#"{"stream":"pane.bytes","frame":"ping","seq":\#(Self.pty.nextSeq()),"epoch":3}"#)
                }
            }
            continuation.onTermination = { _ in
                pings.cancel()
                Self.pty.detach(token: token)
            }
        }
    }

    // MARK: - Fixtures

    /// The pane's grid until a guest sizes it: a desktop-wide terminal, far wider than a phone
    /// (the guest's report: fitted to the width, it was unreadable).
    static let cols = 120
    static let rows = 30

    /// A guest sees a FIXED projection of an agent: exactly these keys, and name, agent and
    /// display_agent may be null. No cwd, titles, workspace, tab or session.
    private var sharedAgentJSON: String {
        let status = switch scenario {
        case .running, .oldHost: "working"
        case .paused: "idle"
        case .blocked: "blocked"
        }
        let running = scenario != .paused
        return #"{"terminal_id":"w1-3","pane_id":"w1-3","name":"llm-opt","agent":"omp","display_agent":"omp","agent_status":"\#(status)","guest_running":\#(running)}"#
    }

    /// Not shared with this guest; the UI must never show it.
    private static let otherAgentJSON =
        #"{"terminal_id":"term_jarvis","pane_id":"w1-1","name":"jarvis","agent":"claude","display_agent":null,"agent_status":"idle","guest_running":false}"#

    private static let esc = "\u{1b}["
    private static let body = esc + "38;2;201;205;224m"
    private static let faint = esc + "38;2;110;117;150m"
    private static let white = esc + "38;2;255;255;255m"
    private static let blue = esc + "38;2;91;155;232m"
    private static let green = esc + "38;2;95;179;127m"
    private static let amber = esc + "38;2;233;166;60m"
    private static let you = esc + "38;2;231;215;255m"
    private static let tag = esc + "1;38;2;183;168;255m"
    /// The guest's own prompt row: a brand tint over the machine ground, to the right edge.
    private static let highlight = esc + "48;2;24;25;53m"
    private static let reset = esc + "0m"
    private static let eol = esc + "K" + reset + "\r\n"
    /// The agent's TUI hides the cursor while it works, as in the mock.
    private static let hideCursor = esc + "?25l"

    private static var runningTranscript: String {
        faint + "~/repos/llm-opt" + reset + "\r\n"
            + "\r\n"
            + highlight + you + "❯ " + tag + "plotarmordev (via HerdrUp):" + reset + highlight + you
            + " can you rerun the" + eol
            + highlight + you + "TensorFold bench against our Q5 build and send" + eol
            + highlight + you + "me the table?" + eol
            + "\r\n"
            + blue + "●" + body + " Reading bench/tensorfold.sh" + reset + "\r\n"
            + blue + "●" + body + " Running bench/tensorfold.sh --q5 …" + reset + "\r\n"
            + body + "   decode   " + white + "41.2 tok/s" + body + "  " + green + "(+36%)" + reset + "\r\n"
            + body + "   prefill  " + white + "1,180 tok/s" + reset + "\r\n"
            + blue + "●" + body + " Writing results/tensorfold-q5.md" + reset + hideCursor
    }

    private static var blockedTranscript: String {
        faint + "~/repos/llm-opt" + reset + "\r\n"
            + "\r\n"
            + blue + "●" + body + " Writing results/tensorfold-q5.md" + reset + "\r\n"
            + amber + "?" + reset + " " + white + "Delete old results/tensorfold-*.md (3 files)?" + reset + "\r\n"
            + "  " + white + "❯ Yes" + reset + "\r\n"
            + body + "    No" + reset + hideCursor
    }

    private var transcript: String {
        scenario == .blocked ? Self.blockedTranscript : Self.runningTranscript
    }

    /// Rows in `history`, the scrollback from before the guest connected.
    static let historyRows = 200

    /// What `agent.read` (source recent) returns above the current screen: numbered rows,
    /// so a test can tell backfilled scrollback from anything the stream painted.
    private static var history: String {
        (1...historyRows).map { row in
            faint + "earlier " + String(format: "%03d", row) + body + "  warm-up bench pass" + reset + "\r\n"
        }.joined()
    }

    // MARK: - Wire helpers

    /// The host's guest projection of an `agent.read` reply: the rendered text and the
    /// fields HerdrKit decodes, nothing about the owner's workspace.
    private static func readLine(id: String, text: String) -> String {
        let reply: [String: Any] = ["id": id, "result": [
            "type": "pane_read",
            "read": ["pane_id": access.agentTarget, "source": "recent", "format": "ansi",
                     "text": text, "truncated": false],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
            return errorLine(id: id, code: "internal_error", message: "mock read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorLine(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private static func object(_ requestLine: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
    }

    private static func method(of requestLine: String) -> String {
        object(requestLine)?["method"] as? String ?? ""
    }

    private static func requestID(of requestLine: String) -> String {
        object(requestLine)?["id"] as? String ?? "mock"
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ method: String) {
            lock.lock()
            stored.append(method)
            lock.unlock()
        }
    }

    /// The shared agent's PTY and its one live stream. A locked resize changes the winsize
    /// and, like the agent's TUI on SIGWINCH, redraws at it: the in-band `resize` frame, then
    /// the repaint. An unchanged winsize sends nothing, as the host skips a no-op resize.
    private final class MockPTY: @unchecked Sendable {
        typealias Continuation = AsyncThrowingStream<String, Error>.Continuation
        private let lock = NSLock()
        private var cols = GuestMockTransport.cols
        private var rows = GuestMockTransport.rows
        private var seq: UInt64 = 1
        private var live: (token: UUID, continuation: Continuation)?

        var hasStream: Bool {
            lock.lock()
            defer { lock.unlock() }
            return live != nil
        }

        var geometry: (cols: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (cols, rows)
        }

        func attach(_ continuation: Continuation, token: UUID) -> (cols: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            live = (token, continuation)
            return (cols, rows)
        }

        func detach(token: UUID) {
            lock.lock()
            if live?.token == token { live = nil }
            lock.unlock()
        }

        func nextSeq() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            seq += 1
            return seq
        }

        func resize(cols newCols: Int, rows newRows: Int, redraw: String) {
            lock.lock()
            guard newCols != cols || newRows != rows else {
                lock.unlock()
                return
            }
            cols = newCols
            rows = newRows
            let resizeSeq = seq + 1
            seq += 2
            let continuation = live?.continuation
            lock.unlock()
            // Yielded outside the lock: a terminating stream detaches under it.
            let repaint = Data(("\u{1b}[H\u{1b}[2J" + redraw).utf8).base64EncodedString()
            continuation?.yield(#"{"stream":"pane.bytes","frame":"resize","seq":\#(resizeSeq),"epoch":3,"cols":\#(newCols),"rows":\#(newRows)}"#)
            continuation?.yield(#"{"stream":"pane.bytes","frame":"data","seq":\#(resizeSeq + 1),"epoch":3,"data_b64":"\#(repaint)"}"#)
        }
    }
}
#endif
