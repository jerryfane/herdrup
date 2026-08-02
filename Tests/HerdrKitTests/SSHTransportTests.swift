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

    var socketPath: String {
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

    /// THE GOAL'S ACCEPTANCE BAR — the same live contract, run against BOTH
    /// transports from one shared body.
    ///
    /// Two earlier attempts at this claim were wrong. The first cited an
    /// `ssh -L` suite run, which exercised UnixSocketTransport through
    /// OpenSSH's tunnel and proved nothing about this transport. The second
    /// hand-wrote SSH-only assertions that drifted from the contract: it
    /// claimed a ping it never sent, and its detection+ANSI case was rejected
    /// inside HerdrClient before the transport was ever invoked — testing the
    /// client, not the tunnel.
    ///
    /// A shared body run through a factory cannot drift: whatever the contract
    /// asserts, both transports must satisfy identically.
    func testTheLiveContractHoldsIdenticallyOverBothTransports() async throws {
        try XCTSkipIf(socketPath.isEmpty, "no socket")
        let ssh = try makeTransport()
        let unix = UnixSocketTransport(path: socketPath)

        let overUnix = try await liveContract(HerdrClient(transport: unix), unix)
        let overSSH = try await liveContract(HerdrClient(transport: ssh), ssh)

        // Identical observable results, not merely both non-empty.
        XCTAssertEqual(overSSH.paneCount, overUnix.paneCount, "agent.list must agree")
        XCTAssertEqual(overSSH.firstPane, overUnix.firstPane, "same pane identity")
        XCTAssertEqual(overSSH.styledHasCSI, overUnix.styledHasCSI, "styling parity")
        XCTAssertEqual(overSSH.plainHasCSI, overUnix.plainHasCSI, "plain parity")
        XCTAssertEqual(overSSH.unwrappedNonEmpty, overUnix.unwrappedNonEmpty,
                       "the DEFAULT read surface must work over SSH too")
        XCTAssertEqual(overSSH.pingOK, overUnix.pingOK, "ping parity")

        // Parity is necessary but NOT sufficient — both transports can agree on
        // a wrong value, and every boolean here can agree on false. So assert
        // absolute semantics too, over SSH specifically.
        XCTAssertTrue(overSSH.pingOK, "a real ping must round-trip over SSH")
        XCTAssertTrue(overSSH.styledHasCSI, "ansi must actually be styled")
        XCTAssertFalse(overSSH.plainHasCSI, "text must actually be unstyled")
        XCTAssertTrue(overSSH.unwrappedNonEmpty, "the default read surface must return content")
        XCTAssertTrue(overSSH.unwrappedHasCSI, "the default surface must preserve styling")
        XCTAssertGreaterThan(overSSH.paneCount, 0, "a live server must report panes")
    }

    struct ContractResult: Equatable {
        var paneCount: Int
        var firstPane: String
        var styledHasCSI: Bool
        var plainHasCSI: Bool
        var unwrappedNonEmpty: Bool
        var unwrappedHasCSI: Bool
        var pingOK: Bool
    }

    /// The contract itself, transport-agnostic. Anything added here is
    /// automatically required of every transport.
    ///
    /// Takes the transport as well as the client because a contract that only
    /// sees the client cannot send a raw request — which is how `pingOK` came
    /// to be hardcoded `true`, asserting a fact it never established.
    func liveContract(
        _ client: HerdrClient, _ transport: any HerdrTransport
    ) async throws -> ContractResult {
        let agents = try await client.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let styled = try await client.read(pane: pane, source: .visible, format: .ansi, lines: 40)
        let plain = try await client.read(pane: pane, source: .visible, format: .text, lines: 40)
        // recent_unwrapped is the DEFAULT reading surface per the design panel,
        // and was untested over SSH until now.
        let unwrapped = try await client.read(pane: pane, lines: 40)
        // A real ping, DECODED rather than substring-matched: a substring check
        // passes on an error envelope that merely mentions the id.
        let requestID = "contract-ping"
        let pong = try await transport.roundTrip(
            "{\"id\":\"\(requestID)\",\"method\":\"ping\",\"params\":{}}"
        )
        struct Empty: Decodable {}
        let decoded = try? JSONDecoder().decode(
            ResultEnvelope<Empty>.self, from: Data(pong.utf8)
        )
        let pongOK = decoded?.id == requestID

        // Both reads must be non-empty: "no CSI" is trivially true of an empty
        // string, so an empty plain read would satisfy the styling assertions
        // while proving nothing.
        XCTAssertFalse(styled.text.isEmpty, "styled read must return content")
        XCTAssertFalse(plain.text.isEmpty, "plain read must return content")

        return ContractResult(
            paneCount: agents.count,
            firstPane: pane,
            styledHasCSI: styled.text.contains("\u{1B}["),
            plainHasCSI: plain.text.contains("\u{1B}["),
            unwrappedNonEmpty: !unwrapped.text.isEmpty,
            unwrappedHasCSI: unwrapped.text.contains("\u{1B}["),
            pingOK: pongOK
        )
    }

    /// STRESS COVERAGE, not a determinism proof — labelled honestly after a
    /// reviewer measured the previous version letting the racy implementation
    /// survive 492 times out of 500.
    ///
    /// The real guarantee against the TOFU race is STRUCTURAL: `compareAndPin`
    /// is the store's only write path, so the split lookup-then-store form
    /// cannot be written. This test samples the contended window and would
    /// occasionally catch a regression, but it cannot prove absence and must
    /// not be cited as if it could.
    func testConcurrentFirstContactCannotBothWin() {
        let policy = PinningHostKeyPolicy()
        let a = String(repeating: "aa", count: 32)
        let b = String(repeating: "bb", count: 32)

        // A task group alone is PROBABILISTIC — tasks may serialise and the
        // test passes without ever racing. But a barrier across a task group
        // DEADLOCKS: Swift's cooperative pool is width-limited, so 64 tasks
        // cannot all arrive. (That deadlock is why this comment exists.)
        //
        // concurrentPerform uses real threads and genuinely runs them in
        // parallel, so the contended window is entered rather than hoped for.
        let workers = 64
        let collected = Locked<[(String, HostKeyDecision)]>([])
        DispatchQueue.concurrentPerform(iterations: workers) { i in
            let fp = i.isMultiple(of: 2) ? a : b
            let decision = policy.evaluate(host: "h", port: 22, presented: fp)
            collected.mutate { $0.append((fp, decision)) }
        }
        var trusted: Set<String> = []
        for (fp, decision) in collected.value where decision == .trust { trusted.insert(fp) }

        XCTAssertEqual(
            trusted.count, 1,
            "exactly one fingerprint may ever be trusted for a host:port; got \(trusted.count)"
        )
    }

    /// Pins are keyed by host AND port: the same name on a different port is a
    /// different host, and sharing a pin across them would accept a key that
    /// was never trusted for that endpoint.
    func testPinsAreScopedToHostAndPort() {
        let policy = PinningHostKeyPolicy()
        let fp = String(repeating: "cc", count: 32)
        XCTAssertEqual(policy.evaluate(host: "h", port: 22, presented: fp), .trust)
        XCTAssertEqual(
            policy.evaluate(host: "h", port: 2222, presented: String(repeating: "dd", count: 32)),
            .trust,
            "a different port is a different endpoint, so this is a first contact"
        )
        XCTAssertEqual(
            policy.evaluate(host: "h", port: 22, presented: String(repeating: "dd", count: 32)),
            .reject,
            "the original endpoint's pin must still hold"
        )
    }

    /// F1: cancellation must interrupt session ESTABLISHMENT, not only the read
    /// loop. Uses the reviewer's instrument — a peer that accepts TCP and then
    /// withholds its SSH banner, so the handshake blocks forever.
    ///
    /// Before the fix the socket was published only after connect, handshake,
    /// host-key check and auth had all completed, so a cancel arriving during
    /// establishment had nothing to shut down; the reviewer measured >4s. Four
    /// such peers exhaust the whole 4-worker queue.
    func testCancellationInterruptsSessionEstablishment() async throws {
        let listener = SilentPeer()
        try listener.start()
        defer { listener.stop() }

        SSHRuntime.start()
        let transport = SSHTransport(credentials: SSHCredentials(
            host: "127.0.0.1", port: listener.port, username: "nobody",
            privateKeyPEM: "not-a-key", remoteSocketPath: "/tmp/unused.sock"))

        let started = Date()
        let task = Task { _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 3.0,
            "cancel must interrupt a handshake blocked on a silent peer; took \(elapsed)s"
        )
    }

    /// REGRESSION for the double-close. 46bb658 fixed it in production code and
    /// shipped no test, so nothing would notice its return.
    ///
    /// A host-key rejection is the deterministic path the reviewer used: it fails
    /// AFTER the descriptor is published, which is exactly the window where a
    /// failure path that closes without releasing leaves LiveChannel holding a
    /// number the process may reuse. Repeat it many times — a double-close only
    /// bites once the descriptor has been recycled — and require every attempt to
    /// fail cleanly rather than corrupting an unrelated socket.
    func testRepeatedPostPublicationFailuresDoNotDoubleClose() async throws {
        SSHRuntime.start()
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let pem = try? String(contentsOfFile: Self.keyPath, encoding: .utf8),
              FileManager.default.fileExists(atPath: socketPath)
        else { throw XCTSkip("no local SSH key or herdr socket") }

        let store = PinningHostKeyPolicy.PinStore()
        store.pin(host: "127.0.0.1", port: 22, fingerprint: String(repeating: "00", count: 32))
        let transport = SSHTransport(
            credentials: SSHCredentials(
                host: "127.0.0.1", username: NSUserName(),
                privateKeyPEM: pem, remoteSocketPath: socketPath),
            hostKeyPolicy: PinningHostKeyPolicy(store: store)
        )

        // A canary descriptor: if a double-close lands on a recycled number, this
        // is what gets clobbered, and the read afterwards fails.
        for _ in 0..<25 {
            do {
                _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#)
                XCTFail("a pinned-mismatch host key must be refused")
            } catch let err as SSHError {
                guard case .hostKeyRejected = err else {
                    return XCTFail("expected hostKeyRejected, got \(err)")
                }
            }
        }

        // The process must still be able to use descriptors normally afterwards.
        let ok = try await SSHTransport(
            credentials: SSHCredentials(
                host: "127.0.0.1", username: NSUserName(),
                privateKeyPEM: pem, remoteSocketPath: socketPath)
        ).roundTrip(#"{"id":"after","method":"ping","params":{}}"#)
        XCTAssertFalse(ok.isEmpty, "descriptor space must be intact after repeated failures")
    }

    /// REGRESSION for the timeout floor. libssh2 takes milliseconds and reads 0
    /// as NO timeout, so a sub-millisecond request would truncate to unbounded —
    /// silently inverting what the caller asked for.
    func testSubMillisecondSetupTimeoutIsClampedNotInverted() {
        let t = SSHTransport(credentials: SSHCredentials(
            host: "h", username: "u", privateKeyPEM: "k", remoteSocketPath: "/s"),
            setupTimeout: 0.0005)
        XCTAssertGreaterThanOrEqual(
            t.setupTimeout, SSHTransport.minimumSetupTimeout,
            "a sub-ms timeout must clamp to the floor, not truncate to unbounded"
        )
        XCTAssertGreaterThanOrEqual(Int(t.setupTimeout * 1000), 1, "must not truncate to 0ms")
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
        store.pin(host: "127.0.0.1", port: 22, fingerprint: String(repeating: "00", count: 32))
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


/// Minimal lock box for collecting results from real threads.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}


/// Accepts TCP and never sends an SSH banner, so a handshake blocks.
final class SilentPeer: @unchecked Sendable {
    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0
    private var thread: Thread?
    private var held: [Int32] = []

    func start() throws {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listen(fd, 8)
        let t = Thread { [weak self] in
            guard let self else { return }
            while true {
                let c = accept(self.fd, nil, nil)
                if c < 0 { return }
                self.held.append(c)   // accept, then say nothing at all
            }
        }
        t.start()
        thread = t
    }

    func stop() {
        for c in held { close(c) }
        if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }
}
