import Foundation

// Wire types for herdr's `gram.*` methods — the owner<->agent message channel.
// Field names mirror the server schema (src/api/schema/gram.rs::GramMessageInfo)
// so the app decodes it byte-for-byte. The app is the OWNER: it reads the owner
// view (`gram.list` with no caller pane), posts to agents (`gram.post`), and
// marks messages read (`gram.mark_read`). `gram.send`/`gram.grab` are agent-side
// (the `herdr gram` CLI) and are intentionally not modelled here.

/// Which way a gram message flows.
public enum GramDirection: String, Decodable, Sendable, Equatable {
    case agentToOwner = "agent_to_owner"
    case ownerToAgent = "owner_to_agent"
}

/// One gram message as returned by the server.
public struct GramMessage: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let direction: GramDirection
    /// Sender identity: an agent's name/identity for `agentToOwner`, or "owner".
    public let from: String
    /// For `ownerToAgent`: the addressed agent (direct), or nil for the shared
    /// grab-queue. Always nil for `agentToOwner`.
    public let to: String?
    public let text: String
    /// The agent that claimed a shared-queue item; nil while unclaimed.
    public let grabbedBy: String?
    public let grabbedUnixMs: UInt64?
    public let createdUnixMs: UInt64
    /// The owner has viewed this `agentToOwner` message. `var` so the app can flip
    /// it locally for an optimistic update after `gram.mark_read` (the rest of the
    /// message is immutable / decode-only).
    public var readByOwner: Bool

    enum CodingKeys: String, CodingKey {
        case id, direction, from, to, text
        case grabbedBy = "grabbed_by"
        case grabbedUnixMs = "grabbed_unix_ms"
        case createdUnixMs = "created_unix_ms"
        case readByOwner = "read_by_owner"
    }

    /// A message an agent sent the owner (vs one the owner posted).
    public var isFromAgent: Bool { direction == .agentToOwner }

    /// A shared, still-open queue item the owner posted (any agent may claim).
    public var isOpenQueueItem: Bool {
        direction == .ownerToAgent && to == nil && grabbedBy == nil
    }

    /// An agent->owner message the owner has not yet read.
    public var isUnread: Bool { isFromAgent && !readByOwner }

    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdUnixMs) / 1000.0) }
}

/// `gram.list` result (`type: "gram_list"`). Only `messages` is decoded.
struct GramListResult: Decodable {
    let messages: [GramMessage]
}

/// `gram.post` / `gram.send` / `gram.grab` result (`type` varies). Only the echoed
/// `message` is decoded — the type discriminator is ignored.
struct GramMessageResult: Decodable {
    let message: GramMessage
}
