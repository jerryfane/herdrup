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

        // Breaking at the ack would pin acknowledgement, not persistence — a
        // server that acked then closed would pass. That is the identical
        // defect being fixed in herdr-ios#2, shipped again here, so the same
        // observation helper is used: wait out an idle window and require the
        // stream still open.
        // Inlined rather than shared: task 5 generalises this into
        // observeSubscription on its own branch, and task 1 must not depend on
        // an unmerged sibling PR.
        let stream = client.subscribe([Subscription(.paneTurnCompleted, paneID: pane)])
        let ack = Flag(), ended = Flag()
        let consumer = Task {
            do {
                for try await line in stream where line == .subscriptionStarted { ack.raise() }
                ended.raise()
            } catch { ended.raise() }
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let sawAck = ack.isSet, closed = ended.isSet
        consumer.cancel()

        XCTAssertTrue(sawAck, "the event channel must acknowledge over SSH")
        XCTAssertFalse(closed, "the event stream must STAY open over SSH, not merely acknowledge")
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

    /// THE GOAL'S ACCEPTANCE BAR, now encoded rather than asserted.
    ///
    /// The PR originally cited a separate `ssh -L` run of the whole suite as
    /// proof. That run exercised UnixSocketTransport through OpenSSH's tunnel —
    /// it proved OpenSSH forwards correctly, NOT that this transport carries the
    /// protocol. The claim was wrong, and only a test that drives the contract
    /// through SSHTransport itself can settle it.
    func testTheLiveTransportContractHoldsThroughSSHTransport() async throws {
        let transport = try makeTransport()
        let client = HerdrClient(transport: transport)

        // list -> read (styled) -> read (plain) -> ping, all through SSH.
        let agents = try await client.agentList()
        XCTAssertFalse(agents.isEmpty)
        let agent = try XCTUnwrap(agents.first)
        XCTAssertNotNil(agent.stateChangeSeq, "revision gating needs this over SSH too")

        let styled = try await client.read(pane: agent.paneID, source: .visible, format: .ansi, lines: 40)
        let plain = try await client.read(pane: agent.paneID, source: .visible, format: .text, lines: 40)
        XCTAssertTrue(styled.text.contains("\u{1B}["))
        XCTAssertFalse(plain.text.contains("\u{1B}["))

        // detection+ansi must still be refused client-side over SSH.
        do {
            _ = try await client.read(pane: agent.paneID, source: .detection, format: .ansi)
            XCTFail("detection+ansi must be refused regardless of transport")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "herdrkit_invalid_read")
        }
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


/// Minimal thread-safe flag for observing a stream from outside its task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func raise() { lock.lock(); value = true; lock.unlock() }
}
