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
    /// Defaults to `.recentUnwrapped`: `read` is the REFLOWED-SNAPSHOT surface —
    /// a 100-column pane at readable size does not fit a phone, so a transcript
    /// reflowed to the phone's width is the right default for skimming. Styling
    /// survives it. This is now the COMPLEMENT to the live path, not the only
    /// option: `streamTerminal(pane:)` renders a real grid-faithful VT from the
    /// raw byte stream, and `setPTYSize(...)` drives the actual PTY geometry that
    /// `PaneInfo` never exposed. `read` stays the cheap, reflowed snapshot.
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

    /// True when `pane` reports an agent WITH a composer — the same gate
    /// `InputRouter` uses to enter intent mode, and the observable proxy for "a
    /// prompt will be accepted". A freshly-started agent is not promptable for a
    /// variable window, and there is no reliable readiness flag (interactive_ready
    /// is nil on this path), so the UI polls THIS to learn when a just-spawned
    /// agent can receive its pre-filled task — then delivers it as a prompt, never
    /// as rawKeys send_text into a not-ready agent. Absent pane, or an agent with
    /// no composer, is NOT promptable (false).
    public func isPromptable(pane: String) async throws -> Bool {
        guard let info = try await agentList().first(where: { $0.paneID == pane }) else { return false }
        return InputRouter().mode(for: info) == .intent
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

    // MARK: - Live terminal stream

    /// Opens `pane.stream` — herdr's persistent server->client raw PTY byte firehose
    /// — and yields the opening `stream_started` ack (geometry + epoch) followed by
    /// the ordered `\n`-delimited frames. Cloned from `subscribe()`: same Transport
    /// line framing, no busy-poll (the server pushes as bytes arrive off the PTY). A
    /// line that fails to decode as a valid frame THROWS and finishes the stream — a
    /// stateful byte stream can't skip a corrupt line without desyncing the emulator,
    /// so the view surfaces the failure and re-opening the pane reseeds a fresh reset.
    /// The connection also ends when the peer closes or the task is cancelled (closing
    /// the SSH channel = unsubscribe).
    public nonisolated func streamTerminal(
        pane: String,
        includeHistory: Bool = true,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil
    ) -> AsyncThrowingStream<TerminalStreamEvent, Error> {
        let encoder = JSONEncoder()
        let env = RequestEnvelope(
            id: "herdrkit:pane.stream:\(pane)",
            method: "pane.stream",
            params: PaneStreamParams(
                paneID: pane, includeHistory: includeHistory,
                resumeFrom: nil, epoch: nil,
                maxFrameBytes: maxFrameBytes, scrollbackLines: scrollbackLines)
        )
        guard let data = try? encoder.encode(env) else {
            return AsyncThrowingStream { $0.finish(throwing: TransportError.closedBeforeResponse) }
        }
        let requestLine = String(decoding: data, as: UTF8.self)
        let raw = transport.stream(requestLine)

        return AsyncThrowingStream { continuation in
            let task = Task {
                let decoder = JSONDecoder()
                var sawAck = false
                do {
                    for try await line in raw {
                        if !sawAck {
                            sawAck = true
                            switch Self.decodeStreamAck(line, decoder) {
                            case .started(let started):
                                continuation.yield(.started(started))
                                continue
                            case .error(let apiError):
                                // pane_not_found, or an older server rejecting the
                                // unknown method — surface it and stop cleanly.
                                continuation.finish(throwing: apiError)
                                return
                            case .undecodable:
                                // Not the ack we expected: fall through and try this
                                // line as a frame. If it is a valid frame it is
                                // yielded; if not, the strict decode below THROWS and
                                // ends the stream (a stray non-frame leading line is
                                // not silently swallowed).
                                break
                            }
                        }
                        // STRICT: every line after the ack must be a valid pane.bytes
                        // frame. A stateful byte stream cannot skip a corrupt line
                        // without desyncing the emulator (feeding the next frame mid
                        // escape-sequence), so a decode failure THROWS — the stream
                        // ends with an error, the view surfaces it, and re-opening the
                        // pane reseeds a fresh full-screen reset. The ack fall-through
                        // above lands here too, so a non-ack/non-frame leading line
                        // also fails loudly rather than being silently swallowed.
                        let frame = try decoder.decode(StreamFrame.self, from: Data(line.utf8))
                        continuation.yield(.frame(frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum StreamAck {
        case started(StreamStarted)
        case error(APIError)
        case undecodable
    }

    /// Classifies the first `pane.stream` line: the `stream_started` ack, a server
    /// error envelope, or something else (which the caller then re-tries as a frame).
    private nonisolated static func decodeStreamAck(_ line: String, _ decoder: JSONDecoder) -> StreamAck {
        let data = Data(line.utf8)
        if let err = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return .error(err.error)
        }
        if let ok = try? decoder.decode(ResultEnvelope<StreamStarted>.self, from: data) {
            return .started(ok.result)
        }
        return .undecodable
    }

    /// Sets the pane's real PTY winsize and takes/releases geometry ownership.
    /// One-shot request/response on the single-shot control socket, dispatched via
    /// the same `call(...)` path as `read`/`sendText`. NOTE `lock:false` (the
    /// default) is NOT side-effect-free: the server applies the winsize resize FIRST
    /// and only then releases ownership, so this DOES resize the shared PTY (a
    /// co-viewing desktop reflows until its next render reclaims the size). `false`
    /// only means "don't PIN the geometry"; it does not mean "don't resize". cols/
    /// rows are clamped to the server's floor (cols>=4, rows>=2) before the round-trip.
    public func setPTYSize(
        pane: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false
    ) async throws -> PanePtySize {
        let clampedCols = min(max(cols, 4), Int(UInt16.max))
        let clampedRows = min(max(rows, 2), Int(UInt16.max))
        let params = PaneSetPtySizeParams(
            paneID: pane, cols: clampedCols, rows: clampedRows,
            cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx, lock: lock)
        return try await call("pane.set_pty_size", params, as: PanePtySize.self)
    }
}

/// Decodes any JSON value, for calls whose result body the client ignores.
struct JSONNull: Decodable {
    init(from decoder: Decoder) throws { _ = decoder }
}
