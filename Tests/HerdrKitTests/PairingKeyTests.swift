import XCTest
import Crypto
import Citadel
@testable import HerdrKit

/// The round trip that decides whether QR pairing is buildable at all.
///
/// Pairing generates a keypair ON THE PHONE and stores the private half in the Keychain;
/// `CitadelTransport` later parses that same string back to authenticate. If generation
/// and parsing disagree by a single byte of the OpenSSH container, pairing appears to
/// succeed and then fails at connect time — on the user's machine, with no useful error.
/// So the generated key is parsed back through the EXACT call the transport makes.
final class PairingKeyTests: XCTestCase {

    /// GENERATE -> SERIALISE -> PARSE must return the same key.
    ///
    /// Asserted on the raw private key bytes, not on the PEM string: two different PEMs
    /// can encode the same key (the OpenSSH checksum is random per serialisation), so
    /// comparing strings would be both flaky and wrong.
    func testGeneratedKeyParsesBackThroughTheTransportsOwnCall() throws {
        let original = Curve25519.Signing.PrivateKey()
        let pairing = PairingKey(key: original, comment: "herdrup-test")

        // The exact call in CitadelTransport.makeConnection().
        let parsed = try Curve25519.Signing.PrivateKey(
            sshEd25519: Data(pairing.privateKeyPEM.utf8),
            decryptionKey: nil
        )

        XCTAssertEqual(parsed.rawRepresentation, original.rawRepresentation,
                       "a key that does not survive the transport's own parser cannot authenticate")
        XCTAssertEqual(parsed.publicKey.rawRepresentation, original.publicKey.rawRepresentation)
    }

    /// A freshly generated key (no injected input) must round-trip too — the path pairing
    /// actually uses.
    func testFreshlyGeneratedKeyRoundTrips() throws {
        let pairing = PairingKey(comment: "iPhone")
        let parsed = try Curve25519.Signing.PrivateKey(
            sshEd25519: Data(pairing.privateKeyPEM.utf8), decryptionKey: nil)
        XCTAssertEqual(
            PairingKey.authorizedKeysLine(for: parsed.publicKey, comment: "iPhone"),
            pairing.authorizedKeysLine,
            "the public key handed to the machine must match the private key kept on the phone")
    }

    func testPrivateKeyIsOpenSSHFormatted() {
        let pem = PairingKey(comment: "x").privateKeyPEM
        XCTAssertTrue(pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(pem.contains("-----END OPENSSH PRIVATE KEY-----"))
    }

    /// The authorized_keys line must be the three-field shape sshd accepts. A wrong blob
    /// here is silently ignored by sshd — the user just cannot log in, with nothing logged
    /// that names the cause.
    func testAuthorizedKeysLineShape() throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = PairingKey.authorizedKeysLine(for: key.publicKey, comment: "jerry's iPhone")
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        XCTAssertEqual(parts[2], "jerry's iPhone")

        // The base64 field must decode to: string("ssh-ed25519") || string(32 raw bytes).
        let blob = try XCTUnwrap(Data(base64Encoded: parts[1]))
        XCTAssertEqual(blob, PairingKey.publicKeyBlob(key.publicKey))
        XCTAssertEqual(blob.count, 4 + 11 + 4 + 32, "length-prefixed type + length-prefixed 32-byte key")
        XCTAssertEqual(blob.suffix(32), key.publicKey.rawRepresentation)
    }

    /// An empty comment must not leave a trailing space — sshd tolerates it, but the line
    /// is also what a human greps for when revoking, and a stray space makes an exact
    /// match fail.
    func testEmptyCommentProducesTwoFields() {
        let key = Curve25519.Signing.PrivateKey()
        let line = PairingKey.authorizedKeysLine(for: key.publicKey, comment: "   ")
        XCTAssertEqual(line.split(separator: " ").count, 2)
        XCTAssertFalse(line.hasSuffix(" "))
    }

    /// Fingerprints must match `ssh-keygen -lf` so the string the app shows and the string
    /// the machine prints are comparable by eye.
    func testFingerprintIsUnpaddedSHA256OfTheBlob() {
        let key = Curve25519.Signing.PrivateKey()
        let fp = PairingKey.fingerprint(for: key.publicKey)
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        XCTAssertFalse(fp.contains("="), "OpenSSH prints fingerprints unpadded")
        let expected = Data(SHA256.hash(data: PairingKey.publicKeyBlob(key.publicKey)))
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(fp, "SHA256:" + expected)
    }

    /// Two pairings must never collide — each device gets its own revocable key.
    func testEachPairingGeneratesADistinctKey() {
        let a = PairingKey(comment: "a"), b = PairingKey(comment: "b")
        XCTAssertNotEqual(a.authorizedKeysLine, b.authorizedKeysLine)
        XCTAssertNotEqual(a.publicKeyFingerprint, b.publicKeyFingerprint)
    }
}
