import Foundation

/// A stable per-host bucket key for scoping app-side state to one SSH connection.
public enum HostKey {
    /// `host:port`, with the host lowercased and stripped of brackets + trailing dots so common
    /// spellings of the same box share one bucket. This is NOT the pin-grade IPv6 canonicalization the
    /// host-key policy uses — a rare IPv6 re-spelling here only splits a cosmetic terminal bucket,
    /// never a security boundary, so the cheaper normalization is deliberate.
    public static func canonical(host: String, port: UInt16) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        h = h.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return "\(h):\(port)"
    }
}

/// Saved terminals partitioned by host, so each connected host shows only its OWN terminals. A
/// terminal is a pane on one daemon, so a single global list wrongly surfaces another host's panes
/// (the phantom-terminal bug). The per-host add/remove/rename logic stays in `SavedTerminals`; this
/// just buckets it by an opaque host key. Codable so the app persists it in UserDefaults.
public struct HostScopedTerminals: Codable, Equatable, Sendable {
    private var byHost: [String: SavedTerminals]

    public init(byHost: [String: SavedTerminals] = [:]) {
        self.byHost = byHost
    }

    public func terminals(host: String) -> [SavedTerminal] {
        byHost[host]?.terminals ?? []
    }

    @discardableResult
    public mutating func add(
        paneID: String, createdUnixMs: UInt64, host: String, id: UUID = UUID()
    ) -> SavedTerminal {
        var list = byHost[host] ?? SavedTerminals()
        let created = list.add(paneID: paneID, createdUnixMs: createdUnixMs, id: id)
        byHost[host] = list
        return created
    }

    public mutating func remove(id: UUID, host: String) {
        guard var list = byHost[host] else { return }
        list.remove(id: id)
        byHost[host] = list
    }

    public mutating func rename(id: UUID, to label: String, host: String) {
        guard var list = byHost[host] else { return }
        list.rename(id: id, to: label)
        byHost[host] = list
    }

    /// One-time legacy migration: fold a pre-scoping flat list into `host`'s bucket, but ONLY when
    /// that host has no bucket yet — so the first host connected after the upgrade inherits the
    /// owner's existing terminals (their main box), and every host stays isolated thereafter. Returns
    /// true if it folded, so the caller can retire the legacy blob.
    @discardableResult
    public mutating func migrateLegacy(_ legacy: SavedTerminals, into host: String) -> Bool {
        guard byHost[host] == nil, !legacy.terminals.isEmpty else { return false }
        byHost[host] = legacy
        return true
    }
}
