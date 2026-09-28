import Foundation
import Crypto

/// The initiator side of `Noise_IK_25519_ChaChaPoly_SHA256` (Noise spec rev 34), which
/// is how a guest phone talks to a host daemon through the relay.
///
/// Only what IK needs is here: no PSK, no rekey, no fallback. The guest already knows
/// the host's static key from the invite, so message 1 carries the guest's static key
/// and an encrypted payload, and message 2 completes the handshake.
public enum NoiseIK {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    /// The Noise message ceiling.
    public static let maxMessageBytes = 65535
    static let tagBytes = 16
    /// The largest plaintext one transport message can carry.
    public static let maxPlaintextBytes = maxMessageBytes - tagBytes
    static let dhBytes = 32

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A message was too short to hold the fields the pattern requires.
        case truncated
        /// A message would exceed the 65535-byte Noise ceiling.
        case messageTooLarge(Int)
        /// AEAD authentication failed: the wrong key, or bytes changed on the way.
        case decryptFailed
        /// A key had the wrong length or was rejected by X25519.
        case badKey
        /// The 2^64-1 nonce space ran out.
        case nonceExhausted
        /// A handshake step was called out of order.
        case outOfOrder

        public var description: String {
            switch self {
            case .truncated: return "noise message truncated"
            case .messageTooLarge(let n): return "noise message of \(n) bytes exceeds \(NoiseIK.maxMessageBytes)"
            case .decryptFailed: return "noise decryption failed"
            case .badKey: return "noise key rejected"
            case .nonceExhausted: return "noise nonce exhausted"
            case .outOfOrder: return "noise handshake step out of order"
            }
        }
    }

    /// One direction's cipher: a ChaChaPoly key plus the 64-bit counter nonce.
    /// Unchecked because swift-crypto on Linux does not mark the immutable
    /// `SymmetricKey` Sendable.
    public struct CipherState: @unchecked Sendable {
        var key: SymmetricKey?
        var nonce: UInt64 = 0

        init(key: SymmetricKey? = nil) {
            self.key = key
        }

        var hasKey: Bool { key != nil }

        /// Noise nonces are 32 zero bits followed by the counter little-endian.
        static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
            var bytes = Data(count: 4)
            withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
            // 12 bytes is always a valid ChaChaPoly nonce.
            return try! ChaChaPoly.Nonce(data: bytes)
        }

        mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
            guard let key else { return plaintext }
            // 2^64-1 is reserved by the spec and must never be used.
            guard nonce < UInt64.max else { throw Failure.nonceExhausted }
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(nonce), authenticating: ad)
            nonce += 1
            // `ciphertext` can be a slice of the combined box; rebase so callers get
            // zero-based bytes.
            var out = Data(capacity: box.ciphertext.count + NoiseIK.tagBytes)
            out.append(contentsOf: box.ciphertext)
            out.append(contentsOf: box.tag)
            return out
        }

        mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
            guard let key else { return ciphertext }
            guard nonce < UInt64.max else { throw Failure.nonceExhausted }
            guard ciphertext.count >= NoiseIK.tagBytes else { throw Failure.truncated }
            let body = ciphertext.prefix(ciphertext.count - NoiseIK.tagBytes)
            let tag = ciphertext.suffix(NoiseIK.tagBytes)
            let plaintext: Data
            do {
                let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(nonce), ciphertext: body, tag: tag)
                plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            } catch {
                throw Failure.decryptFailed
            }
            // The nonce advances only on success, so a forged message cannot desync it.
            nonce += 1
            return plaintext
        }
    }

    /// The chaining key, handshake hash and current cipher of a handshake.
    struct SymmetricState {
        var ck: Data
        var h: Data
        var cipher = CipherState()

        init(protocolName: String) {
            let name = Data(protocolName.utf8)
            if name.count <= 32 {
                h = name + Data(count: 32 - name.count)
            } else {
                h = Data(SHA256.hash(data: name))
            }
            ck = h
        }

        mutating func mixHash(_ data: Data) {
            h = Data(SHA256.hash(data: h + data))
        }

        mutating func mixKey(_ ikm: Data) {
            let (ck, k) = NoiseIK.hkdf(chainingKey: ck, ikm: ikm)
            self.ck = ck
            cipher = CipherState(key: SymmetricKey(data: k))
        }

        mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
            let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
            mixHash(ciphertext)
            return ciphertext
        }

        mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
            let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
            mixHash(ciphertext)
            return plaintext
        }

        func split() -> (CipherState, CipherState) {
            let (k1, k2) = NoiseIK.hkdf(chainingKey: ck, ikm: Data())
            return (CipherState(key: SymmetricKey(data: k1)), CipherState(key: SymmetricKey(data: k2)))
        }
    }

    /// Noise's two-output HKDF over HMAC-SHA256.
    static func hkdf(chainingKey: Data, ikm: Data) -> (Data, Data) {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: chainingKey))))
        let out1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: tempKey))
        let out2 = Data(HMAC<SHA256>.authenticationCode(for: out1 + Data([0x02]), using: tempKey))
        return (out1, out2)
    }

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            return shared.withUnsafeBytes { Data($0) }
        } catch {
            throw Failure.badKey
        }
    }

    /// The guest side of the IK handshake. Call `writeMessage1`, then `readMessage2`,
    /// which returns the responder's payload and the transport ciphers.
    public struct Initiator {
        private var state: SymmetricState
        private let staticKey: Curve25519.KeyAgreement.PrivateKey
        private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
        private let remoteStatic: Data
        private var step = 0

        /// `ephemeral` is injectable only so tests can replay published vectors; a
        /// real session must let it default to a fresh key.
        public init(
            prologue: Data,
            staticKey: Curve25519.KeyAgreement.PrivateKey,
            remoteStatic: Data,
            ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
        ) throws {
            guard remoteStatic.count == NoiseIK.dhBytes else { throw Failure.badKey }
            self.staticKey = staticKey
            self.ephemeralKey = ephemeral
            self.remoteStatic = remoteStatic
            state = SymmetricState(protocolName: NoiseIK.protocolName)
            state.mixHash(prologue)
            // Pre-message pattern `<- s`: the responder's static key is known up front.
            state.mixHash(remoteStatic)
        }

        /// `-> e, es, s, ss` followed by the encrypted payload.
        public mutating func writeMessage1(payload: Data) throws -> Data {
            guard step == 0 else { throw Failure.outOfOrder }
            let e = ephemeralKey.publicKey.rawRepresentation
            var message = e
            state.mixHash(e)
            state.mixKey(try NoiseIK.dh(ephemeralKey, remoteStatic))
            message += try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
            state.mixKey(try NoiseIK.dh(staticKey, remoteStatic))
            message += try state.encryptAndHash(payload)
            guard message.count <= NoiseIK.maxMessageBytes else { throw Failure.messageTooLarge(message.count) }
            step = 1
            return message
        }

        /// `<- e, ee, se` followed by the responder's payload. Returns the payload
        /// and the transport session.
        public mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: Transport) {
            guard step == 1 else { throw Failure.outOfOrder }
            guard message.count <= NoiseIK.maxMessageBytes else { throw Failure.messageTooLarge(message.count) }
            guard message.count >= NoiseIK.dhBytes + NoiseIK.tagBytes else { throw Failure.truncated }
            let re = Data(message.prefix(NoiseIK.dhBytes))
            state.mixHash(re)
            state.mixKey(try NoiseIK.dh(ephemeralKey, re))
            state.mixKey(try NoiseIK.dh(staticKey, re))
            let payload = try state.decryptAndHash(Data(message.dropFirst(NoiseIK.dhBytes)))
            step = 2
            let (send, receive) = state.split()
            return (payload, Transport(send: send, receive: receive, handshakeHash: state.h))
        }
    }

    /// The post-handshake session. The initiator sends with the first split cipher and
    /// receives with the second.
    public struct Transport: Sendable {
        var send: CipherState
        var receive: CipherState
        public let handshakeHash: Data

        public mutating func encrypt(_ plaintext: Data) throws -> Data {
            guard plaintext.count <= NoiseIK.maxPlaintextBytes else {
                throw Failure.messageTooLarge(plaintext.count + NoiseIK.tagBytes)
            }
            return try send.encrypt(ad: Data(), plaintext: plaintext)
        }

        public mutating func decrypt(_ message: Data) throws -> Data {
            guard message.count <= NoiseIK.maxMessageBytes else { throw Failure.messageTooLarge(message.count) }
            return try receive.decrypt(ad: Data(), ciphertext: message)
        }

        /// Splits a byte stream into transport messages no larger than Noise allows.
        public mutating func encryptChunked(_ plaintext: Data) throws -> [Data] {
            var out: [Data] = []
            var offset = plaintext.startIndex
            repeat {
                let end = plaintext.index(offset, offsetBy: NoiseIK.maxPlaintextBytes, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
                out.append(try encrypt(Data(plaintext[offset..<end])))
                offset = end
            } while offset < plaintext.endIndex
            return out
        }
    }
}
