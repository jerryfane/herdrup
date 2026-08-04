import Foundation

/// A parsed SSH destination — host plus port. Lives in HerdrKit (not on the
/// SwiftUI view) so it is covered by the Linux suite: it is pure string logic
/// with a real hazard, and the app target cannot be compiled or tested on Linux.
///
/// The load-bearing rule: an EXPLICIT port that does not parse is REJECTED, never
/// silently replaced with 22. Substituting 22 for a typo'd port ("[fe80::1]:80222")
/// reaches a real host on a port the user never typed and TOFU-pins whatever
/// service answers there — a wrong-target connect, not a harmless default.
public struct HostEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parses "host" | "host:port" | "[ipv6]" | "[ipv6]:port". Returns nil when
    /// input is empty, a bracket is malformed, or a port is present but not a
    /// valid 1–65535 — so the caller can refuse rather than connect somewhere
    /// unintended. A bare IPv6 literal (many colons, no brackets) stays whole on
    /// the default port.
    public static func parse(_ raw: String) -> HostEndpoint? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }   // no closing bracket
            let inner = String(s[s.index(after: s.startIndex)..<close])
            guard !inner.isEmpty else { return nil }                       // "[]"
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return HostEndpoint(host: inner, port: 22) } // "[ipv6]"
            // Anything after "]" must be exactly ":<valid port>", else reject —
            // this is the branch that used to fail OPEN to :22.
            guard rest.hasPrefix(":"), let port = validPort(rest.dropFirst()) else { return nil }
            return HostEndpoint(host: inner, port: port)
        }

        // Unbracketed. Exactly one colon is host:port; zero or many (a bare IPv6)
        // is the whole string on the default port.
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard !parts[0].isEmpty, let port = validPort(parts[1]) else { return nil }
            return HostEndpoint(host: String(parts[0]), port: port)
        }
        return HostEndpoint(host: s, port: 22)
    }

    private static func validPort(_ s: Substring) -> UInt16? {
        guard let p = UInt16(s), p >= 1 else { return nil }  // UInt16 rejects >65535; guard rejects 0
        return p
    }
}
