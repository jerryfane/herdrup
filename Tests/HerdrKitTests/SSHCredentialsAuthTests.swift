import XCTest

@testable import HerdrKit

/// The auth-kind discriminator on `SSHCredentials`: each init must map to the
/// right `Auth` case, since `CitadelTransport.makeConnection` branches on it to
/// choose `.ed25519` vs `.passwordBased`. (The `SSHAuthenticationMethod` Citadel
/// builds is opaque, so the actual wiring is proven by the gated live tests; this
/// pins the routing decision that selects it.)
final class SSHCredentialsAuthTests: XCTestCase {
    func testKeyInitMapsToPrivateKeyAuth() {
        let creds = SSHCredentials(
            host: "h", port: 2222, username: "root",
            privateKeyPEM: "PEM", passphrase: "secret", remoteSocketPath: "")
        XCTAssertEqual(creds.auth, .privateKey(pem: "PEM", passphrase: "secret"))
    }

    func testKeyInitWithoutPassphraseHasNilPassphrase() {
        let creds = SSHCredentials(
            host: "h", username: "root", privateKeyPEM: "PEM", remoteSocketPath: "")
        XCTAssertEqual(creds.auth, .privateKey(pem: "PEM", passphrase: nil))
    }

    func testPasswordInitMapsToPasswordAuth() {
        let creds = SSHCredentials(
            host: "h", port: 22, username: "root",
            password: "hunter2", remoteSocketPath: "")
        XCTAssertEqual(creds.auth, .password("hunter2"))
    }
}
