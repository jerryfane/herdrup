import XCTest
import Foundation
@testable import HerdrKit

/// Redeems a REAL pairing code against a REAL running `herdr pair`.
///
/// The unit tests drive a stub daemon, which can only prove that the client agrees with my
/// own idea of the protocol. This one proves the two implementations agree with each other:
/// Rust serde on one side, Swift Codable on the other, meeting at a socket. It is the test
/// that would have caught, for instance, a field-name or an escaping mismatch — Swift's
/// JSONEncoder escapes "/" as "\/", and ed25519 base64 contains "/" about half the time.
///
/// SKIPPED unless the environment supplies a live pairing code, decided from signals
/// INDEPENDENT of the code under test (an env var holding a payload, and a writable
/// authorized_keys path). Once those hold, errors are NOT swallowed as skips — a real
/// regression fails here rather than reporting green.
///
/// To run it:
///   1. `HOME=/tmp/pairhome herdr pair --ttl 120` on the machine
///   2. read the payload out of the QR it printed
///   3. `HERDR_PAIR_PAYLOAD='<that json>' \
///       HERDR_PAIR_AUTHORIZED_KEYS=/tmp/pairhome/.ssh/authorized_keys \
///       swift test --filter PairingLiveTests`
final class PairingLiveTests: XCTestCase {

    private var payloadJSON: String? {
        ProcessInfo.processInfo.environment["HERDR_PAIR_PAYLOAD"]
    }
    private var authorizedKeysPath: String? {
        ProcessInfo.processInfo.environment["HERDR_PAIR_AUTHORIZED_KEYS"]
    }

    /// The whole exchange, against the real daemon.
    ///
    /// Asserts the OUTCOME on the machine's side — that the key actually landed in
    /// `authorized_keys` — not merely that the call returned. A client that reported
    /// success while the daemon wrote nothing would pass a return-value check and leave a
    /// user unable to connect.
    func testARealDaemonAcceptsThisClientsRedemption() throws {
        guard let json = payloadJSON, let keysPath = authorizedKeysPath else {
            throw XCTSkip("set HERDR_PAIR_PAYLOAD and HERDR_PAIR_AUTHORIZED_KEYS (see the doc comment)")
        }

        let payload = try Pairing.parse(qrText: json)
        XCTAssertNotNil(payload.hostKeyFingerprint,
                        "a real daemon on a machine with a host key must supply one to pin")

        // Normally this generates its own key, exercising the real PairingKey path. A
        // supplied PUBLIC key is honoured so the same test can be pointed at a key whose
        // private half lives elsewhere — which is how the sshd login receipt is taken.
        // Only ever a public key: nothing here reads or writes a private one.
        let supplied = ProcessInfo.processInfo.environment["HERDR_PAIR_PUBLIC_KEY"]
        let line = supplied ?? PairingKey(comment: "live-test-device").authorizedKeysLine
        try Pairing.redeem(
            payload: payload,
            publicKeyLine: line,
            deviceLabel: "live test device",
            timeout: 10)

        // The receipt is on the machine, not in the return value.
        let written = try String(contentsOfFile: keysPath, encoding: .utf8)
        XCTAssertTrue(
            written.contains(line),
            "the daemon accepted the redemption but did not write the key")
        XCTAssertTrue(written.contains("herdr-pair"), "the line must carry the revocation marker")
        XCTAssertFalse(written.contains("PRIVATE KEY"), "nothing secret may reach the machine")

        // Single-use: the same code must not work twice. This is the security property
        // that a photograph of the QR cannot defeat.
        let second = PairingKey(comment: "second-device")
        XCTAssertThrowsError(
            try Pairing.redeem(
                payload: payload, publicKeyLine: second.authorizedKeysLine,
                deviceLabel: "second device", timeout: 10),
            "a spent pairing code must not be redeemable again"
        )
        let after = try String(contentsOfFile: keysPath, encoding: .utf8)
        XCTAssertFalse(
            after.contains(second.authorizedKeysLine),
            "a refused redemption must not write anything")
    }
}
