import Foundation
import NIOSSH
import NIOCore
import Crypto

// Host-key pinning, transport-independent.
//
// This lived in SSHTransport.swift while libssh2 was the only transport, but the
// pinning policy is not a libssh2 mechanic — it is the trust decision the whole
// client depends on. It moved here so it survives the libssh2 removal, and so
// the pure-Swift transport can share exactly the same policy rather than
// reimplement TOFU against Citadel's validator.

/// What the caller decides when a host key is seen.
public enum HostKeyDecision: Sendable, Equatable {
    /// Accept and remember this fingerprint.
    case trust
    /// Refuse the connection.
    case reject
}

/// Consulted on every connect. A changed key is never silently accepted: the
/// policy compares and pins as one operation, and a change is refused.
public protocol HostKeyPolicy: Sendable {
    /// Decide, compare and pin as ONE operation.
    ///
    /// A split lookup-then-callback interface is a TOFU race: two concurrent
    /// first connections can both observe no pin, trust different keys, and
    /// overwrite each other — silently violating hard-stop-on-change at exactly
    /// the moment pinning is supposed to establish trust. Keyed by host AND
    /// port, since two hosts can share a name on different ports.
    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision
}

/// Pins on first contact and hard-stops on change.
public struct PinningHostKeyPolicy: HostKeyPolicy {
    private let store: PinStore

    public init(store: PinStore = PinStore()) {
        self.store = store
    }

    /// Compare-and-pin under a single lock, so concurrent first contacts cannot
    /// both win. A key that differs from the pin is always refused: a changed
    /// host key is indistinguishable from interception, and this transport
    /// carries an operator's whole fleet.
    public func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        store.compareAndPin(key: "\(host):\(port)", presented: presented)
    }

    public func pinnedFingerprint(for host: String, port: UInt16 = 22) -> String? {
        store.pinned(key: "\(host):\(port)")
    }

    /// In-memory pin store.
    ///
    /// Pins survive for the PROCESS lifetime, not across launches: a fresh
    /// `PinStore()` per transport means a transport recreated after an app
    /// restart has no record of the earlier pin and would trust a substituted
    /// key as first contact. So the default policy uses the process-wide
    /// `.shared` store (all default transports in a process share pins), and a
    /// shipping client that needs cross-LAUNCH TOFU must inject a persistent,
    /// e.g. Keychain-backed, store via `PinningHostKeyPolicy(store:)`. This type
    /// is the persistence seam; it deliberately keeps no platform storage of its
    /// own so it still builds on Linux.
    public final class PinStore: @unchecked Sendable {
        private let lock = NSLock()
        private var pins: [String: String] = [:]

        /// Process-wide store backing the default pinning policy, so two
        /// transports created with the default initializer enforce one pin set
        /// rather than each trusting first contact independently.
        public static let shared = PinStore()

        public init() {}

        /// Read-only inspection, for tests and diagnostics.
        public func pinned(key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return pins[key]
        }

        /// Seeds a pin. Expressed through the same atomic primitive so there is
        /// no separate write path to misuse.
        @discardableResult
        public func pin(host: String, port: UInt16 = 22, fingerprint: String) -> HostKeyDecision {
            compareAndPin(key: "\(host):\(port)", presented: fingerprint)
        }

        /// THE ONLY WRITE PATH. Structural, not merely careful: with no separate
        /// lookup-then-store API, the racy split form cannot be written at all.
        /// A concurrency test can only ever sample a race — the reviewer showed
        /// the previous one let the split form survive 492 times in 500 — so the
        /// guarantee has to come from the shape of the interface, not from a
        /// test that hopes to catch it.
        func compareAndPin(key: String, presented: String) -> HostKeyDecision {
            lock.lock(); defer { lock.unlock() }
            if let existing = pins[key] {
                return existing == presented ? .trust : .reject
            }
            pins[key] = presented
            return .trust
        }
    }
}

// MARK: - Citadel / nio-ssh bridge

/// SHA256 fingerprint of a host key's SSH wire format, hex-encoded.
///
/// Stable across connections to the same unchanged host and collision-resistant
/// — the two properties a pin needs. Computed over the same wire encoding
/// `NIOSSHPublicKey.write(to:)` produces (the "ssh-ed25519"/etc. type tag plus
/// the key material), so two distinct keys cannot collapse to one pin, and a
/// key type change registers as a change too.
public func sshHostKeyFingerprintSHA256(_ key: NIOSSHPublicKey) -> String {
    var buffer = ByteBuffer()
    key.write(to: &buffer)
    let digest = SHA256.hash(data: Data(buffer.readableBytesView))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Bridges a `HostKeyPolicy` to Citadel/nio-ssh's host-key validation, so the
/// pure-Swift transport pins exactly the way the libssh2 one did.
///
/// nio-ssh hands the presented `NIOSSHPublicKey` to this delegate, which must
/// succeed or fail a promise. It computes the pin fingerprint, asks the policy
/// (which compares-and-pins atomically), and FAILS the promise on rejection —
/// stopping the handshake before any authentication or command runs, so a
/// changed or unknown host key never sees the private key or a request.
///
/// One instance per target: nio-ssh's delegate is handed only the key, never the
/// endpoint, so the host/port the pin is keyed by must be captured here.
public final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: UInt16
    private let policy: HostKeyPolicy

    public init(host: String, port: UInt16, policy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.policy = policy
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = sshHostKeyFingerprintSHA256(hostKey)
        switch policy.evaluate(host: host, port: port, presented: fingerprint) {
        case .trust:
            validationCompletePromise.succeed(())
        case .reject:
            validationCompletePromise.fail(TransportError.hostKeyRejected(host: host, fingerprint: fingerprint))
        }
    }
}
