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
    public let turnEpoch: Int64?
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
    public let stateChangeSeq: Int64?
    public let turn: Int?
    public let turnEpoch: Int64?
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

// MARK: - Events

/// Subscription types the server actually accepts.
///
/// Deliberately does NOT include `pane.output_changed`: that kind exists inside
/// the server (`EventKind::PaneOutputChanged`) but is absent from the
/// `Subscription` enum, so subscribing to it is rejected. Verified by reading
/// the server's own rejection message. The consequence is that events give only
/// coarse invalidation — there is no per-output tick to drive terminal refresh.
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
