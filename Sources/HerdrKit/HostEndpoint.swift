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

    /// Whether this destination is a Tailscale address, and therefore unreachable
    /// from a device that is not on the same tailnet.
    ///
    /// This exists to CLASSIFY A FAILURE, not to gate a connection: a phone off the
    /// tailnet cannot route here at all, so retrying is futile in a way that an
    /// ordinary unreachable host is not (a LAN box may simply be rebooting). See
    /// `SessionRecovery.giveUpAfterFailures`.
    ///
    /// Address-range matching on purpose — no interface probing, so it needs no
    /// permissions and cannot be wrong about what the app is actually dialing.
    public var isTailnetAddress: Bool {
        Self.isCarrierGradeNAT(host) || Self.isMagicDNSName(host)
    }

    /// Tailscale hands out `100.64.0.0/10`. A /10, NOT a /8: `100.63.x.x` and
    /// `100.128.x.x` are ordinary public addresses and must not be swept up, or a
    /// real host on the public internet would stop retrying after three failures.
    private static func isCarrierGradeNAT(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        // Every octet must read exactly as a number, so "100.64.0.0.evil.com" and
        // "100.0x40.0.0" cannot pass as addresses.
        var values: [UInt16] = []
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt16(octet), value <= 255 else { return false }
            values.append(value)
        }
        return values[0] == 100 && (64...127).contains(values[1])
    }

    /// MagicDNS names end in `.ts.net`. The leading dot is load-bearing: without it
    /// `notts.net` matches, and requiring a non-empty label before it keeps a bare
    /// `ts.net` out.
    private static func isMagicDNSName(_ host: String) -> Bool {
        let name = host.lowercased()
        let suffix = ".ts.net"
        return name.hasSuffix(suffix) && name.count > suffix.count
    }

    private static func validPort(_ s: Substring) -> UInt16? {
        // ASCII digits only: UInt16("+22") parses to 22 and UInt16 accepts other
        // sign/format oddities, so require the text to read exactly as a number.
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let p = UInt16(s), p >= 1 else { return nil }  // UInt16 rejects >65535; guard rejects 0
        return p
    }
}
