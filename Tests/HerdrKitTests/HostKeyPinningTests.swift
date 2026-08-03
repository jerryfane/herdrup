import XCTest
import Foundation
import NIOSSH
import NIOCore
import NIOEmbedded
@testable import HerdrKit

final class HostKeyPinningTests: XCTestCase {

    // Two distinct, valid ed25519 host keys (throwaway, generated with
    // ssh-keygen). "A different key" is exactly the interception/rotation case
    // pinning must catch.
    private static let keyAText = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFC/pYhTFrUoMpRRfd1LTRs7gZ7TZuv4MPD7PcWa01KM fixture-a"
    private static let keyBText = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtaOymmREbaU+scg5KF53w9vK9ijZSY27ib0eXyGNeK fixture-b"

    private func keyA() throws -> NIOSSHPublicKey { try NIOSSHPublicKey(openSSHPublicKey: Self.keyAText) }
    private func keyB() throws -> NIOSSHPublicKey { try NIOSSHPublicKey(openSSHPublicKey: Self.keyBText) }

    /// Runs the validator's decision synchronously and returns the promise result.
    private func decide(_ validator: PinningHostKeyValidator,
                        _ key: NIOSSHPublicKey,
                        on loop: EmbeddedEventLoop) -> Result<Void, Error> {
        let promise = loop.makePromise(of: Void.self)
        var captured: Result<Void, Error>?
        promise.futureResult.whenComplete { captured = $0 }
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        loop.run()
        return captured!
    }

    private func isRejected(_ result: Result<Void, Error>) -> Bool {
        if case .failure(let error) = result, case TransportError.hostKeyRejected = error { return true }
        return false
    }

    private func isTrusted(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    // MARK: - fingerprint

    /// The fingerprint is deterministic: the same key hashes to the same string
    /// every time, or a pin taken on one connection would never match the next.
    func testFingerprintIsStableForSameKey() throws {
        let key = try keyA()
        let first = sshHostKeyFingerprintSHA256(key)
        let second = sshHostKeyFingerprintSHA256(key)
        XCTAssertEqual(first, second, "the fingerprint is not stable for one key")
        XCTAssertEqual(first.count, 64, "SHA256 hex should be 64 characters, got \(first.count)")
    }

    /// Two different keys must not share a fingerprint — otherwise a substituted
    /// key would silently satisfy the pin.
    func testFingerprintDiffersForDifferentKeys() throws {
        let fpA = sshHostKeyFingerprintSHA256(try keyA())
        let fpB = sshHostKeyFingerprintSHA256(try keyB())
        XCTAssertNotEqual(fpA, fpB, "two distinct host keys collided to one fingerprint")
    }

    // MARK: - validator

    /// First contact: the validator trusts and records the key.
    func testValidatorTrustsAndPinsOnFirstContact() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let policy = PinningHostKeyPolicy()
        let validator = PinningHostKeyValidator(host: "h", port: 22, policy: policy)

        XCTAssertNil(policy.pinnedFingerprint(for: "h", port: 22),
                     "precondition: nothing pinned before first contact")
        let result = decide(validator, try keyA(), on: loop)

        XCTAssertTrue(isTrusted(result), "first contact was not trusted: \(result)")
        XCTAssertEqual(policy.pinnedFingerprint(for: "h", port: 22),
                       sshHostKeyFingerprintSHA256(try keyA()),
                       "first contact did not pin the presented key")
    }

    /// The SAME key on reconnect is trusted — the pin must not flap and lock out
    /// a legitimate reconnection.
    func testValidatorTrustsSameKeyOnReconnect() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let validator = PinningHostKeyValidator(host: "h", port: 22, policy: PinningHostKeyPolicy())

        XCTAssertTrue(isTrusted(decide(validator, try keyA(), on: loop)),
                      "precondition: first contact must be trusted")
        XCTAssertTrue(isTrusted(decide(validator, try keyA(), on: loop)),
                      "the same key was rejected on reconnect")
    }

    /// A CHANGED key is refused with `hostKeyRejected`. The precondition (key A
    /// was trusted first) is what makes this non-vacuous: it proves the reject is
    /// specifically the change, not a validator that refuses everything.
    func testValidatorRejectsChangedKey() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let validator = PinningHostKeyValidator(host: "h", port: 22, policy: PinningHostKeyPolicy())

        XCTAssertTrue(isTrusted(decide(validator, try keyA(), on: loop)),
                      "precondition: the first key must be trusted and pinned")
        let changed = decide(validator, try keyB(), on: loop)
        XCTAssertTrue(isRejected(changed),
                      "a changed host key was not rejected with hostKeyRejected: \(changed)")
    }

    /// The same key name on a different port pins independently — the pin is
    /// keyed by host AND port, so port 2222 is a distinct endpoint from port 22.
    func testDifferentPortsPinIndependently() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let policy = PinningHostKeyPolicy()
        let v22 = PinningHostKeyValidator(host: "h", port: 22, policy: policy)
        let v2222 = PinningHostKeyValidator(host: "h", port: 2222, policy: policy)

        XCTAssertTrue(isTrusted(decide(v22, try keyA(), on: loop)),
                      "precondition: port 22 pins key A")
        // Port 2222 has no pin yet, so a DIFFERENT key there is first-contact
        // trusted, not rejected against port 22's pin.
        XCTAssertTrue(isTrusted(decide(v2222, try keyB(), on: loop)),
                      "port 2222 was judged against port 22's pin instead of its own")
        // And each port keeps its own pin.
        XCTAssertTrue(isRejected(decide(v22, try keyB(), on: loop)),
                      "port 22 accepted key B, so the pins are not isolated by port")
    }
}
