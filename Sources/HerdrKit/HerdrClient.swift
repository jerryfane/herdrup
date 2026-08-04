import Foundation

/// Typed client for the herdr JSON API.
///
/// Every command opens its own connection, because the control socket is
/// single-shot (see `HerdrTransport`). Only `subscribe` holds a connection open.
public actor HerdrClient {
    private let transport: HerdrTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var sequence: UInt64 = 0

    public init(transport: HerdrTransport) {
        self.transport = transport
    }

    private func nextID(_ method: String) -> String {
        sequence &+= 1
        return "herdrkit:\(method):\(sequence)"
    }

    private func encodeRequest<P: Encodable>(_ method: String, _ params: P) throws -> String {
        let env = RequestEnvelope(id: nextID(method), method: method, params: params)
        let data = try encoder.encode(env)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a response line, surfacing a server `error` object as a thrown `APIError`.
    private func decodeResult<R: Decodable>(_ line: String, as: R.Type) throws -> R {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            throw err.error
        }
        return try decoder.decode(ResultEnvelope<R>.self, from: data).result
    }

    private func call<P: Encodable, R: Decodable>(
        _ method: String, _ params: P, as type: R.Type
    ) async throws -> R {
        let line = try encodeRequest(method, params)
        let response = try await transport.roundTrip(line)
        return try decodeResult(response, as: type)
    }

    // MARK: - Commands

    /// Every agent the server knows about, with the `revision` /
    /// `stateChangeSeq` counters that drive refresh decisions.
    public func agentList() async throws -> [AgentInfo] {
        try await call("agent.list", EmptyParams(), as: AgentListResult.self).agents
    }

    /// The complete pane set, as a value that carries its own provenance.
    ///
    /// `SessionRecovery.observe` takes this rather than `[AgentInfo]` because an
    /// array can be filtered and a `PaneSnapshot` cannot be constructed outside
    /// the module. A partial listing silently unsubscribes every omitted pane,
    /// and their silence afterwards is indistinguishable from having no output —
    /// so "this is the whole set" is enforced by where the value came from.
    public func paneSnapshot() async throws -> PaneSnapshot {
        PaneSnapshot(agents: try await agentList())
    }

    struct ReadParams: Encodable {
        let target: String
        let source: ReadSource
        let format: ReadFormat
        let lines: UInt32?
    }

    /// Reads a pane. `lines` is clamped by the server to 1000 and defaults to 80.
    ///
    /// Requesting `.ansi` with `.detection` silently yields plain text, so this
    /// refuses that combination rather than returning unstyled output that the
    /// caller believes is styled.
    /// Defaults to `.recentUnwrapped` on the panel's ruling: the API exposes no
    /// pane geometry and no PTY resize (`PaneInfo` carries no cols/rows), so the
    /// phone renders whatever width the desktop chose and cannot change it. A
    /// 100-column pane at readable size does not fit a phone, which makes
    /// grid-faithful and readable mutually exclusive. Reflowed transcript is
    /// therefore the default reading surface, not a toggle. Styling survives it.
    public func read(
        pane: String,
        source: ReadSource = .recentUnwrapped,
        format: ReadFormat = .ansi,
        lines: UInt32? = nil
    ) async throws -> PaneRead {
        if format == .ansi && source == .detection {
            throw APIError(
                code: "herdrkit_invalid_read",
                message: "source=detection ignores format=ansi and returns plain text; "
                    + "use .visible or .recent for styled output"
            )
        }
        let params = ReadParams(target: pane, source: source, format: format, lines: lines)
        return try await call("agent.read", params, as: PaneReadResult.self).read
    }

    struct PromptParams: Encodable {
        let target: String
        let text: String
    }

    /// Submits prompt text as intent rather than as raw keystrokes.
    public func prompt(pane: String, text: String) async throws {
        _ = try await call("agent.prompt", PromptParams(target: pane, text: text), as: JSONNull.self)
    }

    struct SendTextParams: Encodable {
        let paneID: String
        let text: String
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case text
        }
    }

    /// Types literal characters into a pane. Does not submit — Enter is a
    /// separate call, so nothing executes without a deliberate second action.
    public func sendText(pane: String, text: String) async throws {
        _ = try await call("pane.send_text", SendTextParams(paneID: pane, text: text), as: JSONNull.self)
    }

    struct SendKeysParams: Encodable {
        let target: String
        let keys: [String]
    }

    /// Sends named keys (e.g. "Enter", "Escape", "Up") for dialog navigation.
    public func sendKeys(pane: String, keys: [String]) async throws {
        _ = try await call("agent.send_keys", SendKeysParams(target: pane, keys: keys), as: JSONNull.self)
    }

    // MARK: - Spawning agents

    /// A new pane splits off horizontally (`right`) or vertically (`down`). herdr
    /// supports only these two — there is no left/up split.
    public enum SplitDirection: String, Sendable {
        case right, down
    }

    struct PaneSplitParams: Encodable {
        let direction: String
        let cwd: String?
        let focus: Bool
    }

    struct PaneInfoResult: Decodable {
        let pane: PaneRef
        /// Only the id is needed here; the rest of `pane` is deliberately not
        /// modelled so a schema addition on the server cannot break this decode.
        struct PaneRef: Decodable {
            let paneID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
    }

    /// Splits the currently focused pane and returns the NEW pane's id. `cwd` is
    /// the working directory the new pane (and the agent started in it) runs in —
    /// the "folder" of the new-agent form; nil follows the split pane's cwd.
    /// No target pane is sent, so the server splits whatever is focused.
    public func splitPane(cwd: String?, direction: SplitDirection = .down) async throws -> String {
        let params = PaneSplitParams(direction: direction.rawValue, cwd: cwd, focus: true)
        return try await call("pane.split", params, as: PaneInfoResult.self).pane.paneID
    }

    struct AgentStartParams: Encodable {
        let name: String
        let kind: String
        let paneID: String
        enum CodingKeys: String, CodingKey {
            case name, kind
            case paneID = "pane_id"
        }
    }

    struct AgentStartedResult: Decodable {
        let agent: AgentInfo
    }

    /// Starts an agent of `kind` (claude/codex/gemini/…) named `name` in an
    /// existing pane (the one from `splitPane`). Returns the started agent.
    ///
    /// NOTE: this only INITIATES launch. `agent.start` returns while the agent is
    /// still `launch_pending`, and `agent.prompt` refuses (agent_not_ready) for a
    /// variable, sometimes-long window until the agent registers as a promptable
    /// known agent with a composer. There is no reliable client-pollable readiness
    /// flag (`interactive_ready` is not populated on this path), so we do NOT
    /// auto-deliver a task after start. The caller opens the new pane instead and
    /// lets the terminal's own input router send the task as a prompt once the
    /// pane reports a composer (`InputMode.intent`). See `NewAgentView.start`.
    public func startAgent(name: String, kind: String, paneID: String) async throws -> AgentInfo {
        let params = AgentStartParams(name: name, kind: kind, paneID: paneID)
        return try await call("agent.start", params, as: AgentStartedResult.self).agent
    }

    struct PaneTarget: Encodable {
        let paneID: String
        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
    }

    /// Closes a pane — used to clean up the pane a failed spawn left behind, so a
    /// retry does not accumulate orphan panes.
    public func closePane(paneID: String) async throws {
        _ = try await call("pane.close", PaneTarget(paneID: paneID), as: JSONNull.self)
    }

    // MARK: - Events

    /// Opens the persistent event stream.
    ///
    /// The first line is `subscriptionStarted`; the connection then stays open.
    /// Pane-scoped subscriptions need a `paneID` — the server has no wildcard.
    public nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error> {
        let encoder = JSONEncoder()
        let env = RequestEnvelope(
            id: "herdrkit:events.subscribe",
            method: "events.subscribe",
            params: SubscribeParams(subscriptions: subscriptions)
        )
        guard let data = try? encoder.encode(env) else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        let requestLine = String(decoding: data, as: UTF8.self)
        let raw = transport.stream(requestLine)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in raw {
                        continuation.yield(Self.classify(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func classify(_ line: String) -> StreamLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .other(raw: line) }

        if let result = obj["result"] as? [String: Any],
           result["type"] as? String == "subscription_started" {
            return .subscriptionStarted
        }
        if let event = obj["event"] as? [String: Any] {
            let kind = (event["type"] as? String) ?? (event["kind"] as? String) ?? "unknown"
            return .event(kind: kind, paneID: event["pane_id"] as? String, raw: line)
        }
        if let kind = obj["type"] as? String {
            return .event(kind: kind, paneID: obj["pane_id"] as? String, raw: line)
        }
        return .other(raw: line)
    }
}

/// Decodes any JSON value, for calls whose result body the client ignores.
struct JSONNull: Decodable {
    init(from decoder: Decoder) throws { _ = decoder }
}
