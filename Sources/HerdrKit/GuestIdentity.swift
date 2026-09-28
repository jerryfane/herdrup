import Foundation
import Crypto

/// Where the guest device key lives. The app backs this with the Keychain
/// (this-device-only); tests use memory. Kept as a protocol so HerdrKit stays free
/// of the Security framework and builds on Linux.
public protocol GuestKeyStore: Sendable {
    /// The stored 32-byte X25519 private key, or nil when none exists yet.
    func loadGuestKey() throws -> Data?
    func saveGuestKey(_ rawKey: Data) throws
}

/// This install's X25519 device key: the static key a guest proves in every Noise
/// handshake. One per install; it never leaves the device. Unchecked because
/// swift-crypto on Linux does not mark the immutable key type Sendable.
public struct GuestIdentity: @unchecked Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public var fingerprint: String { Self.fingerprint(of: publicKey) }

    public enum Failure: Error, Equatable {
        /// The store returned bytes that are not an X25519 key. Replacing the key
        /// would silently sever every share, so this is surfaced instead.
        case corruptKey
    }

    /// Loads the stored key, or generates and stores one on first use.
    public static func loadOrCreate(store: GuestKeyStore) throws -> GuestIdentity {
        if let raw = try store.loadGuestKey() {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
                throw Failure.corruptKey
            }
            return GuestIdentity(privateKey: key)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try store.saveGuestKey(key.rawRepresentation)
        return GuestIdentity(privateKey: key)
    }

    /// `SHA256:` plus the lowercase hex of the first 8 bytes of SHA-256(public key),
    /// in groups of four joined by `·`, e.g. `SHA256:9f3a·e71c·04bd·c21e`. The host
    /// shows the same string, so the owner can compare it with the guest's phone.
    public static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { byte -> String in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        var groups: [Substring] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 4)
            groups.append(hex[index..<end])
            index = end
        }
        return "SHA256:" + groups.joined(separator: "·")
    }
}

/// A key store that lives only as long as the process: for tests and screenshots.
public final class InMemoryGuestKeyStore: GuestKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    public init(key: Data? = nil) {
        self.key = key
    }

    public func loadGuestKey() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    public func saveGuestKey(_ rawKey: Data) throws {
        lock.lock(); defer { lock.unlock() }
        key = rawKey
    }
}
