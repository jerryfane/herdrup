import Foundation

/// A one-time invite to reach one agent on someone else's machine.
///
/// The payload is JSON, base64url-encoded without padding. Three link forms carry it:
/// the app link `herdrup://guest-invite#<payload>` (the QR code), the web link
/// `https://<relay>/i/<payload>` that owners share, and the older web link
/// `https://<relay>/i#<payload>`. Messages splits a link at the `#`, so the shared web
/// link carries the payload in its path; the relay's landing page passes it through
/// without storing or logging it. A web link only counts on its own invite's relay.
public struct GuestInvite: Equatable, Sendable {
    public static let appLinkPrefix = "herdrup://guest-invite#"
    /// The longest label the app will display from an invite.
    public static let maxLabelLength = 128

    public let relay: URL
    public let hostID: String
    public let hostPublicKey: Data
    public let inviteID: String
    public let secret: String
    public let machineLabel: String
    public let ownerName: String
    public let agentName: String
    public let guestName: String
    public let expires: Date

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The text holds no guest invite link.
        case notAnInvite
        /// The payload is not base64url JSON with the expected fields.
        case malformed(String)
        /// A newer app wrote this invite.
        case unsupportedVersion(Int)
        case expired

        public var description: String {
            switch self {
            case .notAnInvite: return "this isn't a HerdrUp invite link"
            case .malformed(let field): return "this invite is damaged (\(field))"
            case .unsupportedVersion(let v): return "this invite needs a newer HerdrUp (version \(v))"
            case .expired: return "this invite has expired; ask for a new one"
            }
        }
    }

    public init(
        relay: URL, hostID: String, hostPublicKey: Data, inviteID: String, secret: String,
        machineLabel: String, ownerName: String, agentName: String, guestName: String, expires: Date
    ) {
        self.relay = relay
        self.hostID = hostID
        self.hostPublicKey = hostPublicKey
        self.inviteID = inviteID
        self.secret = secret
        self.machineLabel = machineLabel
        self.ownerName = ownerName
        self.agentName = agentName
        self.guestName = guestName
        self.expires = expires
    }

    /// Parses an invite from a link in either form, or from text that contains one
    /// (a pasted message, a scanned QR). Expiry is checked against `now`.
    public static func parse(_ text: String, now: Date = Date()) throws -> GuestInvite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed] + trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var damaged: Failure?
        for candidate in candidates {
            guard let link = Link(candidate) else { continue }
            do {
                let invite = try decode(payload: link.payload)
                if let web = link.web, !web.isOnRelay(invite.relay) { throw Failure.notAnInvite }
                if invite.isExpired(now: now) { throw Failure.expired }
                return invite
            } catch let failure as Failure {
                damaged = damaged ?? failure
            }
        }
        throw damaged ?? Failure.notAnInvite
    }

    /// Whether `text` has the shape of an invite link in any form. The payload and the
    /// relay are only checked by `parse`.
    public static func isInviteLink(_ text: String) -> Bool {
        Link(text) != nil
    }

    /// `text` with an older `…/i#<payload>` web link rewritten to the `…/i/<payload>`
    /// form that survives Messages; any other text comes back unchanged.
    public static func pathFormWebLink(_ text: String) -> String {
        guard let link = Link(text), let web = link.web, web.fragmentForm, let base = web.base.string
        else { return text }
        return "\(base)/i/\(link.payload)"
    }

    /// An invite link split into its payload and, for a web link, where it points.
    struct Link {
        let payload: String
        let web: Web?

        /// A web link's origin and the path before `/i`, which must be its relay's.
        struct Web {
            /// Scheme, host, port and relay path; no query or fragment.
            let base: URLComponents
            /// `/i#<payload>` rather than `/i/<payload>`.
            let fragmentForm: Bool

            func isOnRelay(_ relay: URL) -> Bool {
                guard let relay = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return false }
                var relayPath = relay.percentEncodedPath
                while relayPath.hasSuffix("/") { relayPath.removeLast() }
                return relay.scheme == base.scheme
                    && relay.host?.lowercased() == base.host?.lowercased()
                    && relay.port == base.port
                    && relayPath == base.percentEncodedPath
            }
        }

        /// Exactly `herdrup://guest-invite#<payload>`, `https://<host>[/<path>]/i/<payload>`
        /// or `https://<host>[/<path>]/i#<payload>`; nil for anything else.
        init?(_ text: String) {
            if text.hasPrefix(GuestInvite.appLinkPrefix) {
                let payload = String(text.dropFirst(GuestInvite.appLinkPrefix.count))
                guard !payload.isEmpty else { return nil }
                self.init(payload: payload, web: nil)
                return
            }
            guard let components = URLComponents(string: text),
                  components.scheme == "https",
                  components.host?.isEmpty == false,
                  components.user == nil, components.password == nil,
                  components.percentEncodedQuery == nil
            else { return nil }
            let path = components.percentEncodedPath
            let payload: String
            let basePath: Substring
            let fragmentForm: Bool
            if let fragment = components.percentEncodedFragment {
                guard path.hasSuffix("/i"), !fragment.isEmpty else { return nil }
                payload = fragment
                basePath = path.dropLast(2)
                fragmentForm = true
            } else {
                guard let marker = path.range(of: "/i/", options: .backwards) else { return nil }
                payload = String(path[marker.upperBound...])
                basePath = path[..<marker.lowerBound]
                guard !payload.isEmpty, !payload.contains("/") else { return nil }
                fragmentForm = false
            }
            var base = URLComponents()
            base.scheme = components.scheme
            base.percentEncodedHost = components.percentEncodedHost
            base.port = components.port
            base.percentEncodedPath = String(basePath)
            self.init(payload: payload, web: Web(base: base, fragmentForm: fragmentForm))
        }

        private init(payload: String, web: Web?) {
            self.payload = payload
            self.web = web
        }
    }

    private struct Wire: Codable {
        let v: Int
        let relay: String
        let hostID: String
        let hostPub: String
        let inviteID: String
        let secret: String
        let machineLabel: String
        let ownerName: String
        let agentName: String
        let guestName: String
        let expiresUnix: Int64

        enum CodingKeys: String, CodingKey {
            case v, relay, secret
            case hostID = "host_id"
            case hostPub = "host_pub"
            case inviteID = "invite_id"
            case machineLabel = "machine_label"
            case ownerName = "owner_name"
            case agentName = "agent_name"
            case guestName = "guest_name"
            case expiresUnix = "expires_unix"
        }
    }

    private struct VersionProbe: Decodable { let v: Int }

    static func decode(payload: String) throws -> GuestInvite {
        guard let json = Base64URL.decode(payload) else { throw Failure.malformed("encoding") }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: json) else {
            throw Failure.malformed("json")
        }
        guard probe.v == 1 else { throw Failure.unsupportedVersion(probe.v) }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: json)
        } catch DecodingError.keyNotFound(let key, _) {
            throw Failure.malformed(key.stringValue)
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            throw Failure.malformed(context.codingPath.last?.stringValue ?? "json")
        } catch {
            throw Failure.malformed("json")
        }

        guard let relay = URL(string: wire.relay), Self.isAllowedRelay(relay) else {
            throw Failure.malformed("relay")
        }
        guard Base64URL.decode(wire.hostID)?.count == 16 else { throw Failure.malformed("host_id") }
        guard let hostPub = Base64URL.decode(wire.hostPub), hostPub.count == 32 else {
            throw Failure.malformed("host_pub")
        }
        guard Base64URL.decode(wire.inviteID)?.count == 16 else { throw Failure.malformed("invite_id") }
        guard Base64URL.decode(wire.secret)?.count == 32 else { throw Failure.malformed("secret") }
        guard GuestName.isValid(wire.guestName) else { throw Failure.malformed("guest_name") }
        for (field, value) in [("machine_label", wire.machineLabel), ("owner_name", wire.ownerName),
                               ("agent_name", wire.agentName)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, value.count <= maxLabelLength,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw Failure.malformed(field) }
        }
        guard wire.expiresUnix > 0 else { throw Failure.malformed("expires_unix") }

        return GuestInvite(
            relay: relay, hostID: wire.hostID, hostPublicKey: hostPub, inviteID: wire.inviteID,
            secret: wire.secret, machineLabel: wire.machineLabel, ownerName: wire.ownerName,
            agentName: wire.agentName, guestName: wire.guestName,
            expires: Date(timeIntervalSince1970: TimeInterval(wire.expiresUnix)))
    }

    /// HTTPS, or plain HTTP to this machine for a relay under local development.
    /// The relay only forwards Noise ciphertext, but a guest socket still must not
    /// be steered to an arbitrary cleartext endpoint.
    static func isAllowedRelay(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        default: return false
        }
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now >= expires
    }

    /// The base64url payload every link form carries.
    public var payload: String {
        let wire = Wire(
            v: 1, relay: relay.absoluteString, hostID: hostID, hostPub: Base64URL.encode(hostPublicKey),
            inviteID: inviteID, secret: secret, machineLabel: machineLabel, ownerName: ownerName,
            agentName: agentName, guestName: guestName, expiresUnix: Int64(expires.timeIntervalSince1970))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of strings and integers cannot fail.
        return Base64URL.encode(try! encoder.encode(wire))
    }

    public var appLink: URL {
        URL(string: Self.appLinkPrefix + payload)!
    }

    /// The shareable web link, in the path form the daemon hands out.
    public var webLink: URL {
        var base = relay.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/i/\(payload)")!
    }
}

/// base64url without padding, as the guest protocol uses everywhere.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: rejects padding and the standard-alphabet `+` and `/`.
    public static func decode(_ text: String) -> Data? {
        guard !text.contains(where: { $0 == "=" || $0 == "+" || $0 == "/" }) else { return nil }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}
