import Foundation

// Wire types for the herdr JSON API.
//
// Field sets were taken from a live server (build d293951f) rather than from the
// Rust source, so optionality reflects what the server actually omits.

public struct RequestEnvelope<P: Encodable>: Encodable {
    public let id: String
    public let method: String
    public let params: P
}

public struct EmptyParams: Encodable {
    public init() {}
}

public struct APIError: Error, Decodable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

struct ErrorEnvelope: Decodable {
    let error: APIError
}

struct ResultEnvelope<R: Decodable>: Decodable {
    let id: String?
    let result: R
}

// MARK: - Agents

public struct ComposerEvidence: Decodable, Equatable, Sendable {
    public let provenance: String?
    public let region: String?
    public let cursor: String?
    public let style: String?
    public let frameStable: Bool?

    enum CodingKeys: String, CodingKey {
        case provenance, region, cursor, style
        case frameStable = "frame_stable"
    }
}

public struct ComposerState: Decodable, Equatable, Sendable {
    /// e.g. "draft_present", "unknown". A draft sitting unsent in the composer is
    /// the symptom herdr#18/#22 exist to make visible, so the client surfaces it.
    public let state: String?
    public let attemptID: String?
    public let evidence: ComposerEvidence?

    enum CodingKeys: String, CodingKey {
        case state
        case attemptID = "attempt_id"
        case evidence
    }

    public var hasUnsentDraft: Bool { state == "draft_present" }
}

public struct CompletedTurn: Decodable, Equatable, Sendable {
    public let turn: Int?
    public let turnEpoch: UInt64?
    public let completedUnixMs: Int64?

    enum CodingKeys: String, CodingKey {
        case turn
        case turnEpoch = "turn_epoch"
        case completedUnixMs = "completed_unix_ms"
    }
}

/// The `archived { at, by, reason }` provenance the daemon surfaces on an archived
/// agent in `agent.list` (issue #173). Its PRESENCE on an `AgentInfo` is the
/// load-bearing "this agent is archived" signal; absent means active. Decoded
/// leniently (at/by optional) so a partial record never fails the whole list.
public struct AgentArchivedInfo: Decodable, Equatable, Sendable {
    public let at: String?
    public let by: String?
    public let reason: String?
}

public struct AgentInfo: Decodable, Equatable, Sendable, Identifiable {
    public let agent: String?
    public let agentStatus: String?
    /// Set when the agent is showing an interactive prompt/menu that needs an
    /// on-screen choice (a plan-approval or an AskUserQuestion) rather than a chat
    /// prompt. `agent.prompt` is REJECTED while this is true (or `agentStatus ==
    /// "blocked"`), so the app must drive the pane with raw keys / `pane.send_text`
    /// instead. `inputPromptKind` is the menu kind ("select" / "confirm"). Decoded
    /// leniently — absent on an older server.
    public let inputPending: Bool?
    public let inputPromptKind: String?
    public let name: String?
    public let paneID: String
    public let tabID: String?
    public let workspaceID: String?
    public let terminalID: String?
    public let terminalTitleStripped: String?
    public let cwd: String?
    public let focused: Bool?
    public let interactiveReady: Bool?
    public let composer: ComposerState?
    /// Monotonic per-agent change counters. These are what make revision-gated
    /// refresh possible: poll the cheap list, fetch a screen only when one moves.
    public let revision: Int?
    public let stateChangeSeq: UInt64?
    public let turn: Int?
    public let turnEpoch: UInt64?
    public let lastCompletedTurn: CompletedTurn?
    /// Federation (daemon W3+): for a remote agent, the owning peer's alias
    /// (`machineID`, also carried as the `<alias>/…` prefix on `name`/`paneID`),
    /// the peer's reachability as of the home's last poll, and the agent's
    /// last-known status while its machine is unreachable. All absent on a local
    /// agent or a non-federated server — decoded leniently, so an older or
    /// non-federated server is unaffected.
    public let machineID: String?
    public let reachability: String?
    public let lastKnownStatus: String?
    /// Present only for an archived agent (issue #173). Its presence is the
    /// load-bearing "is archived" signal; absent means active. Decoded leniently,
    /// so an older/non-archiving server is unaffected.
    public let archived: AgentArchivedInfo?

    public var id: String { paneID }

    /// This agent has been archived (its pane released, session preserved).
    public var isArchived: Bool { archived != nil }

    /// Human label for a pane, preferring the agent's assigned name.
    public var displayName: String {
        name ?? terminalTitleStripped ?? paneID
    }

    public var isWorking: Bool { agentStatus == "working" }

    /// The agent is showing an interactive menu / permission prompt (plan-approval or
    /// AskUserQuestion) that must be answered on-screen. `agent.prompt` is refused in
    /// this state, so the app routes input as raw keys / `pane.send_text` instead.
    public var isAwaitingMenuInput: Bool { agentStatus == "blocked" || inputPending == true }

    /// A remote (federated) agent whose owning machine is currently unreachable.
    /// Its `agentStatus` is a stale last-known value, so the UI must render it as
    /// offline rather than as a live status. Unknown reachability strings (a newer
    /// server) read as reachable — the safe default is "not offline".
    public var isUnreachable: Bool { reachability == "unreachable" }

    enum CodingKeys: String, CodingKey {
        case agent, name, composer, revision, turn, cwd, focused, reachability, archived
        case agentStatus = "agent_status"
        case inputPending = "input_pending"
        case inputPromptKind = "input_prompt_kind"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case terminalTitleStripped = "terminal_title_stripped"
        case interactiveReady = "interactive_ready"
        case stateChangeSeq = "state_change_seq"
        case turnEpoch = "turn_epoch"
        case lastCompletedTurn = "last_completed_turn"
        case machineID = "machine_id"
        case lastKnownStatus = "last_known_status"
    }
}

struct AgentListResult: Decodable {
    let agents: [AgentInfo]
}

// MARK: - Accounts (credential subscriptions)

/// One credential account (subscription) the daemon knows about — the app half of
/// "multiple subscriptions per harness + swap". Mirrors the server's `AccountInfo`
/// (`accounts.list` → `{ accounts: [AccountInfo] }`) BYTE-FOR-BYTE.
///
/// `kind` carries the SAME strings as `AgentInfo.agent` (claude/codex/kimi), so an
/// agent may swap only among accounts whose `kind == agent.agent`. `usage` is
/// omitted by the server when it has no usage data, so it decodes to nil.
public struct CredentialAccount: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let label: String
    public let active: Bool
    /// The account's login email, when the daemon can derive it. Optional → an
    /// older daemon that omits it decodes to nil. Identity only, never a secret.
    public let email: String?
    public let usage: AccountUsage?
}

/// One rate-limit window for an account (a 5-hour or weekly bucket, etc.).
public struct UsageWindow: Decodable, Equatable, Sendable, Identifiable {
    public let label: String
    public let usedPercent: Double?
    public let resetsAt: String?
    public let status: String?
    public var id: String { label }
    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case status
    }
}

/// A credential account's usage snapshot. EVERY field is optional — the server
/// omits any it cannot report, so a bare `{}` (or a missing `usage`) is valid and
/// must decode without failing.
///
/// `windows` is the current shape (any number of rate-limit buckets). `source`
/// is "live" (fetched from the provider) or "local" (read on-disk). The flat
/// `primaryUsedPercent`/`secondaryUsedPercent`/`resetsAt` are back-compat mirrors
/// of the first two windows (older daemons send only those); prefer `windows`.
public struct AccountUsage: Decodable, Equatable, Sendable {
    public let windows: [UsageWindow]
    public let source: String?
    public let primaryUsedPercent: Double?
    public let secondaryUsedPercent: Double?
    public let resetsAt: String?
    public let plan: String?
    public let tier: String?
    enum CodingKeys: String, CodingKey {
        case windows, source, plan, tier
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case resetsAt = "resets_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `windows` may be absent on older daemons — default to empty.
        windows = try c.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        primaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .primaryUsedPercent)
        secondaryUsedPercent = try c.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
    }

    /// The windows to render: the real `windows` list when present, else a
    /// synthesized pair from the back-compat flat fields (older daemon).
    public var effectiveWindows: [UsageWindow] {
        if !windows.isEmpty { return windows }
        var out: [UsageWindow] = []
        if let p = primaryUsedPercent {
            out.append(UsageWindow(label: "5h", usedPercent: p, resetsAt: resetsAt, status: nil))
        }
        if let s = secondaryUsedPercent {
            out.append(UsageWindow(label: "weekly", usedPercent: s, resetsAt: nil, status: nil))
        }
        return out
    }
}

struct AccountsListResult: Decodable {
    let accounts: [CredentialAccount]
}

// MARK: - Reads

public enum ReadSource: String, Codable, Sendable {
    case visible, recent
    case recentUnwrapped = "recent_unwrapped"
    /// Detection source ignores an `ansi` format request and returns plain text.
    /// Verified on a live server; it is the only source/format pair that does.
    case detection
}

public enum ReadFormat: String, Codable, Sendable {
    case text, ansi
}

public struct PaneRead: Decodable, Equatable, Sendable {
    public let paneID: String
    public let text: String
    public let truncated: Bool?
    public let source: String?
    public let format: String?

    enum CodingKeys: String, CodingKey {
        case text, truncated, source, format
        case paneID = "pane_id"
    }
}

struct PaneReadResult: Decodable {
    let read: PaneRead
}

// MARK: - Prompt delivery

/// herdr's `AgentPromptDelivery`: whether the prompt bytes only reached the pane's
/// composer (`writtenToPty`) or a turn actually STARTED (`submitted`). Mirrors the
/// server enum's snake_case wire values (src/api/schema/agents.rs). These are
/// different facts — the whole point of herdr#18/#26 lives in the gap between them
/// — so the app decodes which one the server confirmed rather than collapsing both
/// into "sent".
public enum PromptDelivery: String, Decodable, Sendable, Equatable {
    case writtenToPty = "written_to_pty"
    case submitted
}

/// The `agent.prompt` result (`type: "agent_prompted"`). Only `delivery` is
/// decoded — the echoed `agent` is deliberately not modelled so a schema change on
/// it cannot break this decode. `delivery` is optional: the server omits it on
/// paths that do not determine one.
public struct PromptResult: Decodable, Sendable, Equatable {
    public let delivery: PromptDelivery?
}

// MARK: - Events

/// Subscription types the server actually accepts.
///
/// Deliberately does NOT include `pane.output_changed`: that kind exists inside
/// the server (`EventKind::PaneOutputChanged`) but is absent from the
/// `Subscription` enum, so subscribing to it is rejected. Verified by reading
/// the server's own rejection message. The consequence is that events give only
/// coarse invalidation — there is no per-output tick HERE to drive terminal refresh.
///
/// The per-output push this comment used to lament is now delivered out-of-band by
/// the `pane.stream` method (`HerdrClient.streamTerminal`), which streams the raw
/// PTY bytes themselves rather than an invalidation tick — see the "Live terminal
/// stream" section below. `events.subscribe` stays the coarse status channel.
public enum SubscriptionType: String, Codable, Sendable {
    case paneUpdated = "pane.updated"
    case paneFocused = "pane.focused"
    case paneClosed = "pane.closed"
    case paneExited = "pane.exited"
    case paneAgentDetected = "pane.agent_detected"
    case paneAgentStatusChanged = "pane.agent_status_changed"
    case paneTurnCompleted = "pane.turn_completed"
    case paneScrollChanged = "pane.scroll_changed"
    case paneOutputMatched = "pane.output_matched"
    case layoutUpdated = "layout.updated"
}

/// A single subscription entry. Pane-scoped kinds require `paneID`; the server
/// rejects them with "missing field pane_id" otherwise, and offers no wildcard,
/// so watching N panes means N entries plus a re-subscribe when panes appear.
public struct Subscription: Encodable, Sendable {
    public let type: SubscriptionType
    public let paneID: String?

    public init(_ type: SubscriptionType, paneID: String? = nil) {
        self.type = type
        self.paneID = paneID
    }

    enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }
}

struct SubscribeParams: Encodable {
    let subscriptions: [Subscription]
}

/// A line arriving on the event stream: either the opening acknowledgement or an event.
public enum StreamLine: Sendable, Equatable {
    case subscriptionStarted
    case event(kind: String, paneID: String?, raw: String)
    case other(raw: String)
}

// MARK: - Live terminal stream (pane.stream / pane.set_pty_size)
//
// Wire types for herdr's `pane.stream` raw PTY byte firehose and its companion
// `pane.set_pty_size`. Field names mirror the herdr Rust schema EXACTLY so the
// app decodes the server byte-for-byte:
//   - request params:  src/api/schema/panes.rs::PaneStreamParams / PaneSetPtySizeParams
//   - open ack:        src/api/schema/response.rs::ResponseResult::StreamStarted
//   - frame lines:     src/api/server/pane_output_stream.rs::StreamFrameLine
//   - resize result:   src/api/schema/response.rs::ResponseResult::PanePtySize
// Frames ride the SAME `\n`-delimited framing `events.subscribe` uses, but the raw
// PTY bytes are carried base64'd in `data_b64` because raw terminal output holds
// 0x0A, control bytes, and partial UTF-8 that a JSON string / line-framing cannot.

/// The first line of a `pane.stream` response: the `stream_started` ack, carrying
/// the pane geometry (cols/rows) and the runtime generation the app previously
/// lacked. `type` is `stream_started`; extra keys are ignored on decode.
public struct StreamStarted: Decodable, Sendable, Equatable {
    public let paneID: String
    public let epoch: UInt64
    public let cols: Int
    public let rows: Int
    /// Absolute byte offset of the seed's first byte since pane birth. Carried for
    /// a later gap-free resume; v1 always re-seeds a fresh reset.
    public let baseSeq: UInt64
    public let resync: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case epoch, cols, rows, resync
        case baseSeq = "base_seq"
    }
}

/// One decoded `pane.stream` frame line. The discriminator is the `frame` field
/// (herdr's `StreamFrameLine.frame`), tagged `"stream":"pane.bytes"`. `data_b64`
/// is decoded to raw `Data` here so callers feed bytes straight to a VT emulator.
public enum StreamFrame: Sendable, Equatable {
    /// Full-screen (re)seed. `lagged` = the client fell behind and the server
    /// dropped the backlog and re-seeded, so the caller should clear before feeding.
    case reset(seq: UInt64, epoch: UInt64, cols: Int, rows: Int, data: Data, lagged: Bool)
    /// Raw PTY delta bytes, to be fed to the emulator in `seq` order.
    case data(seq: UInt64, epoch: UInt64, data: Data)
    /// In-band SIGWINCH: the PTY winsize changed at this offset.
    case resize(seq: UInt64, epoch: UInt64, cols: Int, rows: Int)
    /// ~20s idle heartbeat; carries no payload and can be ignored.
    case ping(seq: UInt64, epoch: UInt64)
    /// The process is gone; the server closes the socket after this frame.
    case exited(seq: UInt64, epoch: UInt64)
}

extension StreamFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case stream, frame, seq, epoch, cols, rows
        case dataB64 = "data_b64"
        case lagged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A pane.stream frame line MUST carry the `pane.bytes` stream tag. Anything
        // else on this channel is a foreign or corrupt line — reject it so the caller
        // FAILS the stream (and reconnects to a fresh reset) rather than feeding a
        // stateful VT emulator bytes from an unknown source.
        let stream = try c.decode(String.self, forKey: .stream)
        guard stream == "pane.bytes" else {
            throw DecodingError.dataCorruptedError(
                forKey: .stream, in: c,
                debugDescription: "unexpected stream '\(stream)' (want pane.bytes)")
        }
        let frame = try c.decode(String.self, forKey: .frame)
        // Decoding is STRICT. A raw byte stream is stateful: silently dropping a
        // frame (or its bytes) would resume the emulator mid-CSI/OSC/UTF-8 and
        // corrupt the screen permanently. So seq/epoch are required, and a
        // malformed line throws here — the caller then tears the stream down and
        // reconnects for a clean full-screen reset instead of feeding garbage.
        let seq = try c.decode(UInt64.self, forKey: .seq)
        let epoch = try c.decode(UInt64.self, forKey: .epoch)
        // `data_b64` is base64 of raw PTY bytes; on the frames that carry it it is
        // required AND must be valid base64, so a truncated payload fails loudly.
        func payload() throws -> Data {
            let b64 = try c.decode(String.self, forKey: .dataB64)
            guard let bytes = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .dataB64, in: c,
                    debugDescription: "data_b64 is not valid base64")
            }
            return bytes
        }
        switch frame {
        case "reset":
            let cols = try c.decode(Int.self, forKey: .cols)
            let rows = try c.decode(Int.self, forKey: .rows)
            // Server omits `lagged` when false (skip_serializing_if is_false).
            let lagged = (try? c.decode(Bool.self, forKey: .lagged)) ?? false
            self = .reset(seq: seq, epoch: epoch, cols: cols, rows: rows, data: try payload(), lagged: lagged)
        case "data":
            self = .data(seq: seq, epoch: epoch, data: try payload())
        case "resize":
            let cols = try c.decode(Int.self, forKey: .cols)
            let rows = try c.decode(Int.self, forKey: .rows)
            self = .resize(seq: seq, epoch: epoch, cols: cols, rows: rows)
        case "ping":
            self = .ping(seq: seq, epoch: epoch)
        case "exited":
            self = .exited(seq: seq, epoch: epoch)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .frame, in: c,
                debugDescription: "unknown pane.stream frame '\(frame)'")
        }
    }
}

/// What `streamTerminal` yields, mirroring how `subscribe` unifies its ack + event
/// lines into one `StreamLine`: the opening `stream_started` ack, then frames.
public enum TerminalStreamEvent: Sendable, Equatable {
    case started(StreamStarted)
    case frame(StreamFrame)
}

/// `pane.stream` subscription params. Only `pane_id` is required; the rest carry
/// server defaults / resume hints (v1 ignores resume and always re-seeds). Nil
/// optionals are omitted by the synthesized encoder, matching serde's
/// `skip_serializing_if = "Option::is_none"`.
/// Open params for the persistent `pane.input.stream` write channel (issue #62).
public struct PaneInputStreamParams: Encodable, Sendable {
    public let paneID: String
    public init(paneID: String) { self.paneID = paneID }
    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
}

public struct PaneStreamParams: Encodable, Sendable {
    public let paneID: String
    public let includeHistory: Bool
    public let resumeFrom: UInt64?
    public let epoch: UInt64?
    public let maxFrameBytes: Int?
    public let scrollbackLines: Int?
    /// Opaque per-view identity for the daemon's PTY width-lease bookkeeping (#137).
    /// The daemon ties a viewer's width-lease liveness to its `pane.stream`: it drops
    /// that viewer's lease when this stream closes. MUST be the SAME value the view
    /// sends on its `pane.set_pty_size` (`PaneSetPtySizeParams.viewerID`) so the lease
    /// taken there is the one released when this stream ends. Optional/omitted-when-nil:
    /// an older daemon ignores it and a caller that doesn't lease leaves it nil.
    public let viewerID: String?

    public init(
        paneID: String,
        includeHistory: Bool = true,
        resumeFrom: UInt64? = nil,
        epoch: UInt64? = nil,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil,
        viewerID: String? = nil
    ) {
        self.paneID = paneID
        self.includeHistory = includeHistory
        self.resumeFrom = resumeFrom
        self.epoch = epoch
        self.maxFrameBytes = maxFrameBytes
        self.scrollbackLines = scrollbackLines
        self.viewerID = viewerID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case includeHistory = "include_history"
        case resumeFrom = "resume_from"
        case epoch
        case maxFrameBytes = "max_frame_bytes"
        case scrollbackLines = "scrollback_lines"
        case viewerID = "viewer_id"
    }
}

/// `pane.set_pty_size` params — sets the REAL PTY winsize (distinct from
/// `pane.resize`, which is a layout split ratio). `lock:true` takes geometry
/// ownership so the desktop TUI stops re-asserting layout size. `lock:false` still
/// resizes the shared PTY (the server resizes, then releases ownership), so a
/// co-viewing desktop reflows transiently — it just is not pinned to the new size.
public struct PaneSetPtySizeParams: Encodable, Sendable {
    public let paneID: String
    public let cols: Int
    public let rows: Int
    public let cellWidthPx: UInt32?
    public let cellHeightPx: UInt32?
    public let lock: Bool
    /// Opaque per-view identity for the daemon's PTY width-lease (#137). The daemon
    /// keys a viewer's width-lease on this: the WIDEST active viewer's geometry wins,
    /// so a narrow viewer no longer shrinks a wider co-viewer. MUST equal the value
    /// this view sends on its `pane.stream` open (`PaneStreamParams.viewerID`) — the
    /// daemon drops this lease when that stream closes. Optional/omitted-when-nil so an
    /// older daemon (and a non-leasing caller) is unaffected.
    public let viewerID: String?
    /// Lease time-to-live in milliseconds (#137). The daemon clamps to [1, 86_400_000]
    /// and applies a 5-minute default (`DEFAULT_PTY_LEASE_TTL`) when omitted. A
    /// foreground view re-sends within the TTL to keep its lease alive. Optional/
    /// omitted-when-nil.
    public let ttl: UInt64?

    public init(
        paneID: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false,
        viewerID: String? = nil,
        ttl: UInt64? = nil
    ) {
        self.paneID = paneID
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.lock = lock
        self.viewerID = viewerID
        self.ttl = ttl
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cols, rows, lock
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case viewerID = "viewer_id"
        case ttl = "ttl_ms"
    }
}

/// Result of `pane.set_pty_size` (`type: "pane_pty_size"`): the size actually
/// applied and whether geometry ownership is now locked. Mirrors the server's
/// `ResponseResult::PanePtySize` EXACTLY — `pane_id/cols/rows/locked`, no `epoch`
/// (the resize result carries none; the stream ack is where an epoch would live).
public struct PanePtySize: Decodable, Sendable, Equatable {
    public let paneID: String
    public let cols: Int
    public let rows: Int
    public let locked: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cols, rows, locked
    }
}

// MARK: - Server / staged self-update (server.staged_update / server.apply_staged_update)

/// Result of `server.staged_update` (`type: "staged_update"`): the running daemon's version and
/// protocol, plus the staged build when a build step has pre-staged a newer binary — `staged` is
/// nil when nothing is staged. Mirrors `ResponseResult::StagedUpdate`
/// (`src/api/schema/response.rs`); the internally-tagged `type` key is ignored on decode.
///
/// The version string is static across commits (`0.8.0`), so `runningSha` — the running binary's
/// short git commit — is what actually identifies the build. An update is available when a build is
/// staged whose `sha` differs from `runningSha` (see `updateAvailable`). `runningSha` is nil on an
/// older daemon that predates the sha-reporting change.
public struct StagedUpdate: Decodable, Sendable, Equatable {
    public let runningVersion: String
    public let runningProtocol: Int
    public let runningSha: String?
    public let staged: Staged?

    /// The pre-staged build the daemon would activate on apply. `path` is intentionally not on the
    /// wire (the daemon never exposes it), so it is absent here too.
    public struct Staged: Decodable, Sendable, Equatable {
        public let version: String
        public let sha: String
        public let builtAt: String
        enum CodingKeys: String, CodingKey {
            case version, sha
            case builtAt = "built_at"
        }
    }

    /// True when a staged build exists that differs from what's running. When the daemon reports its
    /// commit (`runningSha`), require the shas to differ so a stale/equal manifest never shows a
    /// phantom update; on an older daemon (no `runningSha`) fall back to "a build is staged".
    public var updateAvailable: Bool {
        guard let staged else { return false }
        guard let runningSha else { return true }
        return staged.sha != runningSha
    }

    enum CodingKeys: String, CodingKey {
        case staged
        case runningVersion = "running_version"
        case runningProtocol = "running_protocol"
        case runningSha = "running_sha"
    }
}

/// Ack of a `server.apply_staged_update` that returned cleanly (`type: "ok"`). Decoded as an empty
/// object (the `type` tag is ignored). The apply re-execs the daemon via live-handoff, so the
/// one-shot command socket may instead DROP mid-apply — callers treat both a returned ack and a
/// transport drop as "restart initiated" and then re-poll `stagedUpdate()`.
struct OkAck: Decodable, Sendable {}

// MARK: - Folder browsing + agent kinds (fs.list_dir / agent.kinds)

/// Result of `fs.list_dir` (`type: "dir_list"`): the resolved absolute `path` and its entries. The
/// daemon returns directories first then case-insensitive by name; the app uses `path` to compute a
/// parent for "up". Mirrors `ResponseResult::DirList`.
public struct DirListing: Decodable, Sendable, Equatable {
    public let path: String
    public let entries: [Entry]

    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let isDir: Bool
        public var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name
            case isDir = "is_dir"
        }
    }
}

/// One known agent kind and whether its harness binary is installed on the connected machine
/// (`agent.kinds`). The new-agent picker offers only `installed` kinds.
public struct AgentKind: Decodable, Sendable, Equatable, Identifiable {
    public let kind: String
    public let installed: Bool
    public var id: String { kind }
}
