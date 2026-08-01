import XCTest
@testable import HerdrKit

/// Drives the real thing: a real sshd, a real SSH session, a real
/// direct-streamlocal channel, and the real herdr socket at the far end.
///
/// The axis is deliberately NOT "does a connection open". It is that **herdr
/// traffic traverses an SSH tunnel** — the same suite that passes over a plain
/// unix socket must pass over SSH, or the transport is not carrying the
/// protocol. A connection-opens test would pass while the protocol was broken.
///
/// Skips when the local SSH prerequisites are absent so other environments stay
/// honest about what they did not cover, rather than failing for the wrong reason.
final class SSHTransportTests: XCTestCase {
    private static let keyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"

    private var socketPath: String {
        ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
    }

    private func makeTransport() throws -> SSHTransport {
        SSHRuntime.start()
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let pem = try? String(contentsOfFile: Self.keyPath, encoding: .utf8),
              FileManager.default.fileExists(atPath: socketPath)
        else {
            throw XCTSkip("no local SSH key or herdr socket; SSH transport not exercisable here")
        }
        let creds = SSHCredentials(
            host: "127.0.0.1",
            username: NSUserName(),
            privateKeyPEM: pem,
            remoteSocketPath: socketPath
        )
        return SSHTransport(credentials: creds)
    }

    /// THE AXIS: herdr answers a real request through the tunnel.
    func testHerdrAnswersThroughTheTunnel() async throws {
        let transport = try makeTransport()
        let client = HerdrClient(transport: transport)
        let agents = try await client.agentList()
        XCTAssertFalse(agents.isEmpty, "a live server should report agents through SSH")
        XCTAssertFalse(try XCTUnwrap(agents.first).paneID.isEmpty)
    }

    /// Styled reads must survive the tunnel — the reading surface depends on it,
    /// and a transport that silently stripped escapes would still pass a
    /// "connection opens" test.
    func testStyledReadSurvivesTheTunnel() async throws {
        let transport = try makeTransport()
        let client = HerdrClient(transport: transport)
        let agents = try await client.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let styled = try await client.read(pane: pane, source: .visible, format: .ansi, lines: 40)
        XCTAssertTrue(styled.text.contains("\u{1B}["), "ansi styling must survive the tunnel")
    }

    /// The persistent half of the protocol must work over SSH too. Opening a
    /// channel proves nothing here — the server must answer the subscription.
    func testSubscriptionIsAcknowledgedThroughTheTunnel() async throws {
        let transport = try makeTransport()
        let client = HerdrClient(transport: transport)
        let agents = try await client.agentList()
        let pane = try XCTUnwrap(agents.first).paneID

        var sawAck = false
        for try await line in client.subscribe([Subscription(.paneTurnCompleted, paneID: pane)]) {
            if line == .subscriptionStarted { sawAck = true; break }
        }
        XCTAssertTrue(sawAck, "the event channel must work over SSH, not only the command channel")
    }

    /// Single-shot is a property of herdr, not of the local socket, so it must
    /// still hold through the tunnel. Two independent round trips must both
    /// succeed — each opening its own channel is exactly why the pool in task 3
    /// is needed.
    func testEachRoundTripGetsItsOwnChannel() async throws {
        let transport = try makeTransport()
        let a = try await transport.roundTrip(#"{"id":"a","method":"ping","params":{}}"#)
        let b = try await transport.roundTrip(#"{"id":"b","method":"ping","params":{}}"#)
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(b.isEmpty)
    }

    /// A changed host key must hard-stop. Pin a deliberately wrong fingerprint
    /// and require the connection to be refused — the failure mode this guards
    /// is interception, so "it connected anyway" is the defect.
    func testAChangedHostKeyIsRefused() async throws {
        SSHRuntime.start()
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let pem = try? String(contentsOfFile: Self.keyPath, encoding: .utf8),
              FileManager.default.fileExists(atPath: socketPath)
        else { throw XCTSkip("no local SSH key or herdr socket") }

        let store = PinningHostKeyPolicy.PinStore()
        store.pin(host: "127.0.0.1", fingerprint: String(repeating: "00", count: 32))
        let policy = PinningHostKeyPolicy(store: store)
        let transport = SSHTransport(
            credentials: SSHCredentials(
                host: "127.0.0.1",
                username: NSUserName(),
                privateKeyPEM: pem,
                remoteSocketPath: socketPath
            ),
            hostKeyPolicy: policy
        )
        do {
            _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#)
            XCTFail("a changed host key must refuse the connection")
        } catch let err as SSHError {
            guard case .hostKeyRejected = err else {
                return XCTFail("expected hostKeyRejected, got \(err)")
            }
        }
    }
}
