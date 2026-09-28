import Foundation

// MARK: - Guest access, owner side (guest.invite.create / guest.list / guest.revoke / guest.audit)
//
// The owner manages guests over the normal SSH connection. Every call takes an optional
// `machine` (a saved peer alias) that the coordinator routes to that peer, so a federated
// agent is shared by the daemon that actually runs it. Decoding is lenient in the same way
// as `NotificationsStatus`: unknown keys are ignored and an unknown state or event keeps
// its raw string instead of failing the whole answer.

/// Where an owner RPC about one agent goes: the daemon-local pane id plus, for a federated
/// agent, the peer alias the coordinator routes to. A federated pane id is
/// `<machineID>/<local id>`; only that exact prefix is stripped, because the local id may
/// itself contain slashes.
public struct GuestRoute: Equatable, Sendable {
    public let target: String
    public let machine: String?

    public init(paneID: String, machineID: String?) {
        if let machineID, !machineID.isEmpty, paneID.hasPrefix("\(machineID)/") {
            target = String(paneID.dropFirst(machineID.count + 1))
            machine = machineID
        } else {
            target = paneID
            machine = nil
        }
    }

    public init(agent: AgentInfo) {
        self.init(paneID: agent.paneID, machineID: agent.machineID)
    }

    /// A federated agent's `name`/`terminal_id` carry the same `<machineID>/` prefix; the
    /// daemon that owns the agent (and its guest store) knows them without it.
    public func local(_ value: String?) -> String? {
        guard let value, let machine else { return value }
        let prefix = "\(machine)/"
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }
}

/// The agent a guest or invite is bound to (`grant` in guests.json). The grant's
/// `agent_session` (the daemon's own session identity) is not needed by the app and is
/// deliberately not decoded.
public struct GuestGrant: Decodable, Sendable, Equatable {
    public let terminalID: String?
    /// Nil for an unnamed agent.
    public let agentName: String?

    public init(terminalID: String?, agentName: String?) {
        self.terminalID = terminalID
        self.agentName = agentName
    }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agentName = "agent_name"
    }

    /// Whether this grant is the given agent, by its daemon-local identity. The durable
    /// terminal id decides when both sides have one; the agent name is the fallback for an
    /// answer that lacks it.
    public func matches(terminalID otherTerminal: String?, agentName otherName: String?) -> Bool {
        if let terminalID, let otherTerminal { return terminalID == otherTerminal }
        if let agentName, let otherName { return agentName == otherName }
        return false
    }
}

/// One outstanding or consumed invite. Never carries the secret (only its hash lives on disk).
public struct GuestInviteRecord: Decodable, Sendable, Equatable, Identifiable {
    public let inviteID: String
    public let name: String
    public let grant: GuestGrant?
    public let ownerName: String?
    public let machineLabel: String?
    public let createdMs: UInt64?
    public let expiresMs: UInt64?
    /// The guest id that accepted this invite; nil while it is unused.
    public let usedBy: String?

    public var id: String { inviteID }

    public init(inviteID: String, name: String, grant: GuestGrant?, ownerName: String? = nil,
                machineLabel: String? = nil, createdMs: UInt64? = nil, expiresMs: UInt64? = nil,
                usedBy: String? = nil) {
        self.inviteID = inviteID
        self.name = name
        self.grant = grant
        self.ownerName = ownerName
        self.machineLabel = machineLabel
        self.createdMs = createdMs
        self.expiresMs = expiresMs
        self.usedBy = usedBy
    }

    enum CodingKeys: String, CodingKey {
        case name, grant
        case inviteID = "invite_id"
        case ownerName = "owner_name"
        case machineLabel = "machine_label"
        case createdMs = "created_ms"
        case expiresMs = "expires_ms"
        case usedBy = "used_by"
    }

    /// Still redeemable: nobody used it and it has not expired.
    public func isPending(nowMs: UInt64) -> Bool {
        guard usedBy == nil else { return false }
        guard let expiresMs else { return true }
        return expiresMs > nowMs
    }
}

/// One accepted guest (a device key bound to one agent).
public struct GuestRecord: Decodable, Sendable, Equatable, Identifiable {
    public let guestID: String
    public let name: String
    /// `SHA256:9f3a·e71c·04bd·c21e` — the only key material the owner RPCs expose.
    public let fingerprint: String?
    /// The device class the guest reported when accepting ("iPhone", "iPad").
    public let device: String?
    public let grant: GuestGrant?
    public let createdMs: UInt64?
    public let lastSeenMs: UInt64?
    public let revoked: Bool

    public var id: String { guestID }

    public init(guestID: String, name: String, fingerprint: String? = nil, device: String? = nil,
                grant: GuestGrant?, createdMs: UInt64? = nil, lastSeenMs: UInt64? = nil,
                revoked: Bool = false) {
        self.guestID = guestID
        self.name = name
        self.fingerprint = fingerprint
        self.device = device
        self.grant = grant
        self.createdMs = createdMs
        self.lastSeenMs = lastSeenMs
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, device, grant, revoked
        case guestID = "guest_id"
        case createdMs = "created_ms"
        case lastSeenMs = "last_seen_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guestID = try c.decode(String.self, forKey: .guestID)
        name = try c.decode(String.self, forKey: .name)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        grant = try c.decodeIfPresent(GuestGrant.self, forKey: .grant)
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .createdMs)
        lastSeenMs = try c.decodeIfPresent(UInt64.self, forKey: .lastSeenMs)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
    }
}

/// The daemon's relay link, which runs only while a guest or pending invite exists.
public struct GuestLinkStatus: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case off, connecting, up, retrying
        /// A state a newer daemon added; kept verbatim rather than failing `guest.list`.
        case other(String)
    }

    public let state: State
    public let lastError: String?

    public init(state: State, lastError: String? = nil) {
        self.state = state
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case state
        case lastError = "last_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .state) ?? "off" {
        case "off": state = .off
        case "connecting": state = .connecting
        case "up": state = .up
        case "retrying": state = .retrying
        case let raw: state = .other(raw)
        }
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Result of `guest.list`.
public struct GuestListing: Decodable, Sendable, Equatable {
    public let guests: [GuestRecord]
    public let invites: [GuestInviteRecord]
    public let link: GuestLinkStatus?

    public init(guests: [GuestRecord] = [], invites: [GuestInviteRecord] = [], link: GuestLinkStatus? = nil) {
        self.guests = guests
        self.invites = invites
        self.link = link
    }

    enum CodingKeys: String, CodingKey { case guests, invites, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guests = try c.decodeIfPresent([GuestRecord].self, forKey: .guests) ?? []
        invites = try c.decodeIfPresent([GuestInviteRecord].self, forKey: .invites) ?? []
        link = try c.decodeIfPresent(GuestLinkStatus.self, forKey: .link)
    }

    /// Guests who can still reach the agent: revoked ones stay in the store for the log.
    public var activeGuests: [GuestRecord] { guests.filter { !$0.revoked } }

    public func pendingInvites(nowMs: UInt64) -> [GuestInviteRecord] {
        invites.filter { $0.isPending(nowMs: nowMs) }
    }

    /// The non-revoked guests bound to one agent, by its daemon-local identity.
    public func activeGuests(terminalID: String?, agentName: String?) -> [GuestRecord] {
        activeGuests.filter { $0.grant?.matches(terminalID: terminalID, agentName: agentName) == true }
    }
}

/// Result of `guest.invite.create`: the stored invite plus both link forms. `url` is the
/// `herdrup://guest-invite#…` app link (the QR code); `webURL` is the shareable https form.
public struct GuestInviteCreated: Decodable, Sendable, Equatable {
    public let invite: GuestInviteRecord
    public let url: String
    public let webURL: String

    public init(invite: GuestInviteRecord, url: String, webURL: String) {
        self.invite = invite
        self.url = url
        self.webURL = webURL
    }

    enum CodingKeys: String, CodingKey {
        case invite, url
        case webURL = "web_url"
    }
}

/// What `guest.revoke` removes: an accepted guest (closing its live sessions) or an unused invite.
public enum GuestRevokeTarget: Sendable, Equatable {
    case guest(String)
    case invite(String)
}

public enum GuestAuditEvent: Sendable, Equatable {
    case accepted, connected, prompt, upload, denied, paused, revoked
    case other(String)

    init(raw: String) {
        switch raw {
        case "accepted": self = .accepted
        case "connected": self = .connected
        case "prompt": self = .prompt
        case "upload": self = .upload
        case "denied": self = .denied
        case "paused": self = .paused
        case "revoked": self = .revoked
        default: self = .other(raw)
        }
    }
}

public struct GuestAuditFile: Decodable, Sendable, Equatable {
    public let name: String
    public let size: UInt64?
    public let sha256: String?

    public init(name: String, size: UInt64? = nil, sha256: String? = nil) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// One line of `audit.jsonl`, as `guest.audit` returns it (newest first).
public struct GuestAuditEntry: Decodable, Sendable, Equatable {
    public let tsMs: UInt64
    public let guestID: String?
    public let name: String?
    public let fingerprint: String?
    public let event: GuestAuditEvent
    public let pane: String?
    public let method: String?
    public let text: String?
    public let file: GuestAuditFile?

    public init(tsMs: UInt64, guestID: String?, name: String?, fingerprint: String? = nil,
                event: GuestAuditEvent, pane: String? = nil, method: String? = nil,
                text: String? = nil, file: GuestAuditFile? = nil) {
        self.tsMs = tsMs
        self.guestID = guestID
        self.name = name
        self.fingerprint = fingerprint
        self.event = event
        self.pane = pane
        self.method = method
        self.text = text
        self.file = file
    }

    enum CodingKeys: String, CodingKey {
        case name, fingerprint, event, pane, method, text, file
        case tsMs = "ts_ms"
        case guestID = "guest_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tsMs = try c.decode(UInt64.self, forKey: .tsMs)
        guestID = try c.decodeIfPresent(String.self, forKey: .guestID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        event = GuestAuditEvent(raw: try c.decode(String.self, forKey: .event))
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        file = try c.decodeIfPresent(GuestAuditFile.self, forKey: .file)
    }
}

/// One machine whose guest store the owner's Settings reads. `alias` nil is the connected
/// machine; a peer is addressed by its saved-profile alias, which the coordinator routes.
public struct GuestMachine: Hashable, Sendable {
    public let alias: String?
    public let label: String

    public init(alias: String?, label: String) {
        self.alias = alias
        self.label = label
    }

    /// Every machine that can hold guests: the connected one first, then the UNION of the
    /// saved machine profiles and the peers that currently expose agents, by alias. A saved
    /// machine running no agents still keeps its guests and invites, so it must be listed;
    /// an agent-derived peer covers an older daemon without `machine.status`. Peers sort by
    /// label; a saved profile's label wins over the one derived from agents.
    public static func directory(localLabel: String, savedMachines: [SavedMachineStatus],
                                 agentPeers: [PeerSummary]) -> [GuestMachine] {
        var labels: [String: String] = [:]
        for peer in agentPeers { labels[peer.alias] = peer.displayName }
        for saved in savedMachines {
            let label = saved.displayLabel.trimmingCharacters(in: .whitespaces)
            labels[saved.profileID] = label.isEmpty ? (labels[saved.profileID] ?? saved.profileID) : label
        }
        let peers = labels
            .map { GuestMachine(alias: $0.key, label: $0.value) }
            .sorted { ($0.label, $0.alias ?? "") < ($1.label, $1.alias ?? "") }
        return [GuestMachine(alias: nil, label: localLabel)] + peers
    }
}

// MARK: Request params

struct GuestInviteCreateParams: Encodable {
    let target: String
    let name: String
    let ownerName: String
    let machineLabel: String
    let ttlSecs: UInt64?
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case target, name, machine
        case ownerName = "owner_name"
        case machineLabel = "machine_label"
        case ttlSecs = "ttl_secs"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(name, forKey: .name)
        try c.encode(ownerName, forKey: .ownerName)
        try c.encode(machineLabel, forKey: .machineLabel)
        try c.encodeIfPresent(ttlSecs, forKey: .ttlSecs)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestListParams: Encodable {
    let machine: String?

    enum CodingKeys: String, CodingKey { case machine }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestRevokeParams: Encodable {
    let target: GuestRevokeTarget
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case machine
        case guestID = "guest_id"
        case inviteID = "invite_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .guest(let id): try c.encode(id, forKey: .guestID)
        case .invite(let id): try c.encode(id, forKey: .inviteID)
        }
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestAuditParams: Encodable {
    /// The daemon caps a page at 500 entries.
    static let maxLimit = 500

    let guestID: String?
    let limit: Int
    let beforeMs: UInt64?
    let machine: String?

    enum CodingKeys: String, CodingKey {
        case limit, machine
        case guestID = "guest_id"
        case beforeMs = "before_ms"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(guestID, forKey: .guestID)
        try c.encode(min(max(limit, 1), Self.maxLimit), forKey: .limit)
        try c.encodeIfPresent(beforeMs, forKey: .beforeMs)
        try c.encodeIfPresent(machine, forKey: .machine)
    }
}

struct GuestAuditResult: Decodable {
    let entries: [GuestAuditEntry]
}
