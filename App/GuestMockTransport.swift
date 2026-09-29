#if DEBUG
import Foundation
import HerdrKit

/// A stand-in for the guest-gated daemon behind the relay, for the guest screenshots and
/// UI tests. It answers only the guest allowlist; every other method is recorded in
/// `forbiddenCalls` and refused with `guest_forbidden`, exactly as the host would.
struct GuestMockTransport: HerdrTransport {
    enum Scenario: String { case running, paused, blocked }

    let scenario: Scenario

    init(scenario: Scenario) {
        self.scenario = scenario
    }

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
        "gram.upload_chunk", "gram.post",
    ]

    private static let recorder = CallRecorder()

    func roundTrip(_ requestLine: String) async throws -> String {
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard Self.allowlist.contains(method) else {
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
        default:
            return #"{"id":"\#(id)","result":{}}"#
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        let method = Self.method(of: requestLine)
        let id = Self.requestID(of: requestLine)
        guard Self.allowlist.contains(method) else {
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
        let ack = #"{"id":"\#(id)","result":{"type":"stream_started","pane_id":"w1-3","epoch":3,"cols":\#(Self.cols),"rows":\#(Self.rows),"base_seq":0,"resync":true}}"#
        let reset = #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":3,"cols":\#(Self.cols),"rows":\#(Self.rows),"data_b64":"\#(Data(transcript.utf8).base64EncodedString())"}"#
        // A live stream never ends on its own (an end is a drop the view reconnects from),
        // so hold it open and ping like the daemon does.
        return AsyncThrowingStream { continuation in
            continuation.yield(ack)
            continuation.yield(reset)
            let pings = Task {
                var seq: UInt64 = 1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { break }
                    continuation.yield(#"{"stream":"pane.bytes","frame":"ping","seq":\#(seq),"epoch":3}"#)
                    seq += 1
                }
            }
            continuation.onTermination = { _ in pings.cancel() }
        }
    }

    // MARK: - Fixtures

    /// The stream's grid: narrower than the phone, so the view-only fit to width shows.
    static let cols = 48
    static let rows = 30

    /// A guest sees a FIXED projection of an agent: exactly these keys, and name, agent and
    /// display_agent may be null. No cwd, titles, workspace, tab or session.
    private var sharedAgentJSON: String {
        let status = switch scenario {
        case .running: "working"
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
}
#endif
