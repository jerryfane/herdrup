import Foundation

// A guest's view of the shared agent's Gram (herdrup#338), over the guest relay. The host
// decides what is visible: the granted agent's own Grams to the owner since the grant, plus
// the guest's own posts to it. The owner's read, claim and origin fields never reach a
// guest; `read` is the guest's own mark.

/// A file on a Gram a guest can see. `mime` and `sha256` may be absent on the wire.
public struct GuestGramFile: Decodable, Sendable, Equatable {
    public let name: String
    public let size: UInt64
    public let mime: String
    public let sha256: String?

    public init(name: String, size: UInt64, mime: String = "", sha256: String? = nil) {
        self.name = name
        self.size = size
        self.mime = mime
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey { case name, size, mime, sha256 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(UInt64.self, forKey: .size)
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    }

    public var displaySize: String { GramFile.displaySize(of: size) }
}

/// One Gram in the guest's list.
public struct GuestGramMessage: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let direction: GramDirection
    /// The agent for its Grams; the guest's own name on the guest's posts.
    public let from: String
    public let text: String
    public let createdUnixMs: UInt64
    public let file: GuestGramFile?
    /// The guest has seen it. `var` for the optimistic flip after `gram.mark_read`.
    public var read: Bool

    public init(id: String, direction: GramDirection, from: String, text: String,
                createdUnixMs: UInt64, file: GuestGramFile? = nil, read: Bool) {
        self.id = id
        self.direction = direction
        self.from = from
        self.text = text
        self.createdUnixMs = createdUnixMs
        self.file = file
        self.read = read
    }

    enum CodingKeys: String, CodingKey {
        case id, direction, from, text, file, read
        case createdUnixMs = "created_unix_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        direction = try c.decode(GramDirection.self, forKey: .direction)
        from = try c.decode(String.self, forKey: .from)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdUnixMs = try c.decode(UInt64.self, forKey: .createdUnixMs)
        file = try c.decodeIfPresent(GuestGramFile.self, forKey: .file)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
    }

    /// The agent sent it (as opposed to the guest's own post).
    public var isFromAgent: Bool { direction == .agentToOwner }
    /// Only the agent's Grams can be unread; the guest wrote their own.
    public var isUnread: Bool { isFromAgent && !read }
    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdUnixMs) / 1000.0) }
}

/// One page of the guest's `gram.list`, newest first.
public struct GuestGramPage: Decodable, Sendable, Equatable {
    public let messages: [GuestGramMessage]
    /// Older messages remain; absent reads as "this is everything".
    public let hasMore: Bool

    public init(messages: [GuestGramMessage], hasMore: Bool = false) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([GuestGramMessage].self, forKey: .messages) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    /// Unread Grams from the agent on this page.
    public var unreadCount: Int { messages.filter(\.isUnread).count }
}

/// Where a tapped push for a shared agent goes. Guest pushes carry a `herdr_guest` object
/// naming the invite's host and the guest, so the app opens that share's own screens and
/// never an owner screen, whatever other keys the payload also carries.
public struct GuestPushRoute: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A new Gram: the share's Gram tab.
        case gram
        /// A status change (needs you, finished, died), or a kind this build doesn't know:
        /// the share's terminal.
        case status
    }

    public let hostID: String
    public let guestID: String?
    public let kind: Kind
    public let gramID: String?

    public init(hostID: String, guestID: String?, kind: Kind, gramID: String? = nil) {
        self.hostID = hostID
        self.guestID = guestID
        self.kind = kind
        self.gramID = gramID
    }

    /// Nil when the payload is not a guest push (no `herdr_guest.host_id`).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let guest = userInfo["herdr_guest"] as? [String: Any],
              let hostID = guest["host_id"] as? String, !hostID.isEmpty
        else { return nil }
        let guestID = (guest["guest_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let gramID = (guest["gram_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(hostID: hostID, guestID: guestID,
                  kind: guest["kind"] as? String == "gram" ? .gram : .status, gramID: gramID)
    }

    /// The share this push is for: the one on its host held as its guest. Nil when the
    /// phone no longer holds it (left, or another install's guest).
    public func access(in shares: [GuestAccess]) -> GuestAccess? {
        shares.first { share in
            share.endpoint.hostID == hostID && (guestID == nil || share.guestID == guestID)
        }
    }
}

/// What a tapped notification opens. A payload that carries `herdr_guest` at all is a guest
/// push, and its classification ends there: a well-formed one opens its share, a malformed
/// one opens nothing. Its other keys (`gram`, `pane_id`) are never read, so no guest push,
/// malformed or mixed, can open an owner screen.
public enum PushTapTarget: Equatable, Sendable {
    /// A guest push naming its host: open that share, if the phone holds it.
    case guest(GuestPushRoute)
    /// A guest push without a usable host: drop the tap.
    case droppedGuest
    /// The owner's Gram page.
    case ownerGram
    /// The owner's pane.
    case ownerPane(String)
    /// Nothing to open.
    case none

    public init(userInfo: [AnyHashable: Any]) {
        if userInfo["herdr_guest"] != nil {
            self = GuestPushRoute(userInfo: userInfo).map(PushTapTarget.guest) ?? .droppedGuest
        } else if userInfo["gram"] as? Bool == true {
            self = .ownerGram
        } else if let paneID = userInfo["pane_id"] as? String, !paneID.isEmpty {
            self = .ownerPane(paneID)
        } else {
            self = .none
        }
    }
}
