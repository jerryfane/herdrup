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

public struct AgentInfo: Decodable, Equatable, Sendable, Identifiable {
    public let agent: String?
    public let agentStatus: String?
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

    public var id: String { paneID }

    /// Human label for a pane, preferring the agent's assigned name.
    public var displayName: String {
        name ?? terminalTitleStripped ?? paneID
    }

    public var isWorking: Bool { agentStatus == "working" }

    enum CodingKeys: String, CodingKey {
        case agent, name, composer, revision, turn, cwd, focused
        case agentStatus = "agent_status"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case terminalTitleStripped = "terminal_title_stripped"
        case interactiveReady = "interactive_ready"
        case stateChangeSeq = "state_change_seq"
        case turnEpoch = "turn_epoch"
        case lastCompletedTurn = "last_completed_turn"
    }
}

struct AgentListResult: Decodable {
    let agents: [AgentInfo]
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

// MARK: - Pane scroll geometry

/// How much scrollback the SERVER holds for a pane.
///
/// This is the one authoritative answer to "does earlier output exist at all", and it is
/// carried by `pane.get` / `pane.list` / `pane.current` — but **not** by `agent.list`,
/// which is otherwise all this client consumes. Verified against a live daemon: an
/// `agent.list` response has no `scroll` key on any agent, while `pane.get` returns it for
/// every pane.
///
/// It matters because the client cannot answer the question locally. A pane that redraws
/// in place (a background-spawned agent session) has no scrollback anywhere, while an
/// ordinary pane whose connect-time backfill has not landed yet ALSO has none *locally*
/// for up to six seconds. Those two states demand opposite handling and only the server
/// can tell them apart.
///
/// Every field is optional so an older server, or a pane the daemon reports without scroll
/// geometry, decodes to `nil` rather than failing the whole response.
public struct PaneScrollInfo: Decodable, Equatable, Sendable {
    /// Rows of retained scrollback above the viewport — how far up the reader could go.
    /// `0` means there is genuinely nothing earlier to show.
    public let maxOffsetFromBottom: Int?
    /// How far the pane is currently scrolled up from the live edge.
    public let offsetFromBottom: Int?
    /// Rows visible in the pane right now.
    public let viewportRows: Int?

    enum CodingKeys: String, CodingKey {
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case offsetFromBottom = "offset_from_bottom"
        case viewportRows = "viewport_rows"
    }

    public init(maxOffsetFromBottom: Int?, offsetFromBottom: Int? = nil, viewportRows: Int? = nil) {
        self.maxOffsetFromBottom = maxOffsetFromBottom
        self.offsetFromBottom = offsetFromBottom
        self.viewportRows = viewportRows
    }
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
public struct PaneStreamParams: Encodable, Sendable {
    public let paneID: String
    public let includeHistory: Bool
    public let resumeFrom: UInt64?
    public let epoch: UInt64?
    public let maxFrameBytes: Int?
    public let scrollbackLines: Int?

    public init(
        paneID: String,
        includeHistory: Bool = true,
        resumeFrom: UInt64? = nil,
        epoch: UInt64? = nil,
        maxFrameBytes: Int? = nil,
        scrollbackLines: Int? = nil
    ) {
        self.paneID = paneID
        self.includeHistory = includeHistory
        self.resumeFrom = resumeFrom
        self.epoch = epoch
        self.maxFrameBytes = maxFrameBytes
        self.scrollbackLines = scrollbackLines
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case includeHistory = "include_history"
        case resumeFrom = "resume_from"
        case epoch
        case maxFrameBytes = "max_frame_bytes"
        case scrollbackLines = "scrollback_lines"
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

    public init(
        paneID: String,
        cols: Int,
        rows: Int,
        cellWidthPx: UInt32? = nil,
        cellHeightPx: UInt32? = nil,
        lock: Bool = false
    ) {
        self.paneID = paneID
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.lock = lock
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case cols, rows, lock
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
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
