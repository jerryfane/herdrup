import Foundation

/// What a guest holds after accepting an invite: one agent on one machine. The app
/// persists this as a "shared with you" machine.
public struct GuestAccess: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let guestID: String
    /// The name the host labels this guest's prompts with.
    public let guestName: String
    public let machineLabel: String
    public let ownerName: String
    public let agentName: String
    /// The host-local pane id of the shared agent.
    public let agentTarget: String
    public let endpoint: RelayEndpoint
    public let acceptedAt: Date

    public var id: String { "\(endpoint.hostID)/\(guestID)" }

    public init(
        guestID: String, guestName: String, machineLabel: String, ownerName: String,
        agentName: String, agentTarget: String, endpoint: RelayEndpoint, acceptedAt: Date
    ) {
        self.guestID = guestID
        self.guestName = guestName
        self.machineLabel = machineLabel
        self.ownerName = ownerName
        self.agentName = agentName
        self.agentTarget = agentTarget
        self.endpoint = endpoint
        self.acceptedAt = acceptedAt
    }

    /// The composer placeholder: "Message <agent> as <name>".
    public var composerPlaceholder: String { "Message \(agentName) as \(guestName)" }

    public func transport(identity: GuestIdentity, connector: RelaySocketConnector = URLSessionRelayConnector()) -> RelayTransport {
        RelayTransport(endpoint: endpoint, identity: identity, connector: connector)
    }
}

public enum GuestSession {
    private struct AcceptHello: Encodable {
        let v = 1
        let inviteID: String
        let secret: String
        let device: String

        enum CodingKeys: String, CodingKey {
            case v, secret, device
            case inviteID = "invite_id"
        }
    }

    /// Redeems `invite` with this device's key. The host binds the key to the guest
    /// it creates, so every later connection with the same key is this guest.
    public static func accept(
        _ invite: GuestInvite, identity: GuestIdentity, device: String = "iPhone",
        now: Date = Date(), connector: RelaySocketConnector = URLSessionRelayConnector()
    ) async throws -> GuestAccess {
        if invite.isExpired(now: now) { throw GuestInvite.Failure.expired }
        let endpoint = RelayEndpoint(relay: invite.relay, hostID: invite.hostID, hostPublicKey: invite.hostPublicKey)
        let hello = try JSONEncoder().encode(AcceptHello(inviteID: invite.inviteID, secret: invite.secret, device: device))
        let session = try await RelaySession.open(endpoint: endpoint, identity: identity, hello: hello, connector: connector)
        session.close()
        return try access(from: session.reply, invite: invite, endpoint: endpoint, now: now)
    }

    static func access(from reply: [String: Any], invite: GuestInvite, endpoint: RelayEndpoint, now: Date) throws -> GuestAccess {
        func text(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty else { return nil }
            return string
        }
        let agent = reply["agent"] as? [String: Any]
        guard let guestID = text(reply["guest_id"]), let target = text(agent?["target"]) else {
            throw GuestError.secureChannelFailed("the host's acceptance is incomplete")
        }
        return GuestAccess(
            guestID: guestID,
            guestName: text(reply["name"]) ?? invite.guestName,
            machineLabel: text(reply["machine_label"]) ?? invite.machineLabel,
            ownerName: text(reply["owner_name"]) ?? invite.ownerName,
            agentName: text(agent?["name"]) ?? invite.agentName,
            agentTarget: target,
            endpoint: endpoint,
            acceptedAt: now)
    }
}
