import Foundation

/// One herdr session on a machine (`herdr session list --json`, herdr >= 0.5.3), #347.
/// Field names follow herdr's `session::SessionInfo`.
public struct HerdrSession: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var running: Bool
    public var `default`: Bool

    public var id: String { name }

    public init(name: String, running: Bool, default isDefault: Bool) {
        self.name = name
        self.running = running
        self.default = isDefault
    }

    /// Decodes `{"sessions":[...]}`, keeping only names the app can pass back to
    /// `--session` safely: named sessions by name, then the default session (the
    /// order of the #353 pills: work · personal · default).
    public static func decodeList(_ data: Data) throws -> [HerdrSession] {
        struct Envelope: Decodable { let sessions: [HerdrSession] }
        let all = try JSONDecoder().decode(Envelope.self, from: data).sessions
        return all
            .filter { $0.default || CitadelTransport.isSessionName($0.name) }
            .sorted { lhs, rhs in
                if lhs.default != rhs.default { return rhs.default }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
