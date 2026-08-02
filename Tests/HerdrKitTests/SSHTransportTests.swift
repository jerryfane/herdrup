import CSSH
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

    /// AXIS: a descriptor `LiveChannel` has released is never closed by
    /// `LiveChannel.close()`, even once the number names something else.
    ///
    /// The previous version of this test asserted nothing of the sort, and its
    /// own comment claimed a canary it never created. It drove `roundTrip`,
    /// whose `defer { live.close() }` is installed only *after* `openSession`
    /// returns — so on a host-key rejection, which happens inside
    /// `openSession`, `close()` was never reached and deleting `release()`
    /// could not have failed it.
    ///
    /// This drives `LiveChannel` directly and plants a real canary. POSIX hands
    /// out the lowest free descriptor, so the canary deterministically occupies
    /// the number just freed — standing in for the unrelated socket a live
    /// process would have opened there, which is where the damage actually
    /// lands.
    func testReleasedDescriptorIsNotClosedOntoARecycledNumber() throws {
        let live = LiveChannel()
        let published = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        try XCTSkipIf(published < 0, "could not open a descriptor")
        XCTAssertTrue(live.adopt(rawSocket: published))

        // Exactly what a post-publication failure path does: close the socket
        // itself, then relinquish the number.
        XCTAssertEqual(close(published), 0)
        live.release()

        let canary = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        try XCTSkipIf(
            canary != published,
            "another thread took the freed descriptor; the canary would prove nothing"
        )
        defer { _ = close(canary) }

        live.close()

        var kind: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(canary, SOL_SOCKET, SO_TYPE, &kind, &size), 0,
            "close() closed a descriptor it had released — the canary socket is gone"
        )
    }

    /// AXIS: a rejected session adoption stops publishing the descriptor.
    ///
    /// `adopt(_ session:)` cleared `rawSocket` only when it accepted. On the
    /// rejected path — cancellation landing between `openSession` returning and
    /// the adoption — both callers close the session and throw, so `LiveChannel`
    /// was left holding a number that had just been closed. The same canary as
    /// the release test, reached through cancellation instead of failure.
    func testRejectedSessionAdoptionStopsPublishingTheDescriptor() throws {
        try SSHRuntime.ensureStarted()
        let live = LiveChannel()
        let published = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        try XCTSkipIf(published < 0, "could not open a descriptor")
        XCTAssertTrue(live.adopt(rawSocket: published))

        // Cancellation lands while openSession is finishing.
        live.interrupt()

        guard let handle = libssh2_session_init_ex(nil, nil, nil, nil) else {
            return XCTFail("libssh2 session init failed")
        }
        let session = SSHTransport.Session(sock: published, handle: handle)
        XCTAssertFalse(live.adopt(session), "a closed LiveChannel must reject the adoption")

        // What both callers do next: close the session and throw. This closes
        // the descriptor.
        session.close()

        let canary = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        try XCTSkipIf(
            canary != published,
            "another thread took the freed descriptor; the canary would prove nothing"
        )
        defer { _ = close(canary) }

        live.close()

        var kind: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(canary, SOL_SOCKET, SO_TYPE, &kind, &size), 0,
            "a rejected adoption left the descriptor published, and close() took the canary"
        )
    }

    /// AXIS: the production failure path — the one that really does call
    /// `close()` after `openSession` released — closes nothing twice.
    ///
    /// `stream` is that path, not `roundTrip`: its `catch` calls `live.close()`
    /// directly, so a host-key rejection reaches teardown holding a descriptor
    /// `openSession` has already closed. Repeated, because a double close is a
    /// tally, not an event: `DescriptorAudit` counts closes that returned EBADF,
    /// which is the only way this is visible from a test at all.
    func testHostKeyRejectionThroughStreamNeverClosesADescriptorTwice() async throws {
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

        let baseline = DescriptorAudit.doubleCloses
        var rejections = 0
        for _ in 0..<25 {
            do {
                for try await _ in transport.stream(#"{"id":"x","method":"events.subscribe","params":{}}"#) {
                    XCTFail("a pinned-mismatch host key must be refused")
                }
                XCTFail("the stream must fail, not finish cleanly")
            } catch let err as SSHError {
                guard case .hostKeyRejected = err else {
                    return XCTFail("expected hostKeyRejected, got \(err)")
                }
                rejections += 1
            }
        }
        XCTAssertEqual(rejections, 25, "every attempt must have reached the rejection path")
        XCTAssertEqual(
            DescriptorAudit.doubleCloses, baseline,
            "LiveChannel closed a descriptor openSession had already closed"
        )
    }

    /// AXIS: `setupTimeout` bounds the *connect*, not only the handshake.
    ///
    /// Blocking `connect()` ran before the descriptor was published and before
    /// libssh2 held any timeout, so neither cancellation nor `setupTimeout`
    /// could reach it and a silent SYN held the worker for the kernel's retry
    /// schedule — minutes.
    ///
    /// The skip matters as much as the assertion: a sandbox that answers
    /// ENETUNREACH immediately would let this pass without ever exercising a
    /// bound, so the address is checked to be genuinely silent first.
    func testConnectIsBoundedBySetupTimeout() async throws {
        try XCTSkipUnless(Self.blackholeSwallowsSYN(), "no silent address available here")

        let transport = SSHTransport(
            credentials: SSHCredentials(
                host: Self.blackholeHost, username: "nobody",
                privateKeyPEM: "not-a-key", remoteSocketPath: "/tmp/unused.sock"),
            setupTimeout: 0.75
        )
        let started = Date()
        do {
            _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#)
            XCTFail("a blackholed address must not connect")
        } catch {}
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 4.0, "connect must honour setupTimeout; took \(elapsed)s")
        XCTAssertGreaterThan(
            elapsed, 0.5,
            "returned in \(elapsed)s — too fast to have waited on a silent peer, so the bound was not exercised"
        )
    }

    /// AXIS: a cancelled connect ends promptly **and reports itself as
    /// cancelled**, not as a connection failure.
    ///
    /// Timing alone would have proved nothing here, and very nearly did: a
    /// mutation deleting the interrupt check left this test green, because
    /// `shutdown()` wakes a connecting `poll` on Linux by itself. The attempt
    /// ended on time — as `connectFailed(ECONNRESET)`, indistinguishable from a
    /// peer that reset us. A caller that retries connection failures would then
    /// retry a request the user had cancelled, which is the herdr#26/#31 class
    /// of defect: a delivery the user did not ask for.
    ///
    /// So the error type is the assertion, and the budget is set far beyond the
    /// timing bound so nothing but cancellation can end the attempt at all.
    func testCancellationInterruptsConnectAndReportsItAsCancellation() async throws {
        try XCTSkipUnless(Self.blackholeSwallowsSYN(), "no silent address available here")

        let transport = SSHTransport(
            credentials: SSHCredentials(
                host: Self.blackholeHost, username: "nobody",
                privateKeyPEM: "not-a-key", remoteSocketPath: "/tmp/unused.sock"),
            setupTimeout: 30
        )
        let started = Date()
        let task = Task { _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let outcome = await task.result

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 2.0,
            "cancel must interrupt a connect in progress; took \(elapsed)s of a 30s budget"
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("a blackholed connect must not succeed")
        }
        XCTAssertTrue(
            error is CancellationError,
            "a cancelled connect surfaced as \(error) — a retrying caller cannot tell it from a peer reset"
        )
    }

    /// AXIS: a cancellation landing in the poll-ready/`SO_ERROR` window is still
    /// reported as a cancellation, not as the peer's refusal.
    ///
    /// I said this could not be staged deterministically and left it uncovered.
    /// That was wrong, and the reviewer supplied the missing half: a
    /// **bound-but-not-listening** loopback port gives EINPROGRESS, then poll
    /// readiness, then a genuine `SO_ERROR = ECONNREFUSED` — a real failure
    /// rather than our own shutdown. Verified 5/5 before writing this.
    ///
    /// With a real post-connect failure available, only a hook was missing. The
    /// distinction matters because a caller that retries connection failures but
    /// not cancellations would, in this window, re-send a request the user
    /// cancelled.
    func testCancellationInsideTheClassificationWindowIsStillCancellation() async throws {
        let (listener, port) = try Self.boundButNotListening()
        defer { _ = close(listener) }

        let reachedWindow = DispatchSemaphore(value: 0)
        let releaseWindow = DispatchSemaphore(value: 0)

        var configured = SSHTransport(
            credentials: SSHCredentials(
                host: "127.0.0.1", port: port, username: "nobody",
                privateKeyPEM: "not-a-key", remoteSocketPath: "/tmp/unused.sock"),
            setupTimeout: 30
        )
        configured.afterConnectReadyHook = {
            reachedWindow.signal()
            _ = releaseWindow.wait(timeout: .now() + 5.0)
        }
        let transport = configured

        let task = Task { _ = try await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#) }
        XCTAssertEqual(
            reachedWindow.wait(timeout: .now() + 10.0), .success,
            "never reached the classification window"
        )
        task.cancel()
        releaseWindow.signal()
        let outcome = await task.result

        guard case .failure(let error) = outcome else {
            return XCTFail("a connection to a non-listening port must not succeed")
        }
        XCTAssertTrue(
            error is CancellationError,
            "cancellation inside the classification window surfaced as \(error)"
        )
    }

    /// A loopback port that is bound but never listened on: connecting to it
    /// goes EINPROGRESS and then fails for real, which is the one thing a
    /// blackhole cannot provide.
    static func boundButNotListening() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw XCTSkip("could not open a socket") }
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
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    /// AXIS: stalled connects do not occupy the bounded queue.
    ///
    /// Six against four workers: if a stalled connect held its worker for the
    /// kernel's retry schedule, the last two could not even begin until the
    /// first four gave up on their own.
    func testStalledConnectsDoNotExhaustTheBlockingQueue() async throws {
        try XCTSkipUnless(Self.blackholeSwallowsSYN(), "no silent address available here")

        let transport = SSHTransport(
            credentials: SSHCredentials(
                host: Self.blackholeHost, username: "nobody",
                privateKeyPEM: "not-a-key", remoteSocketPath: "/tmp/unused.sock"),
            setupTimeout: 0.75
        )
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? await transport.roundTrip(#"{"id":"x","method":"ping","params":{}}"#)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 5.0,
            "six stalled connects over a 4-worker queue took \(elapsed)s; a worker was held past its budget"
        )
    }

    /// AXIS: an expired deadline is not waited out, so a stalled resolver never
    /// becomes the caller's problem.
    func testResolutionGivesUpOnAnExpiredDeadline() {
        let resolution = SSHTransport.ResolutionRegistry.resolution(host: "127.0.0.1", port: 22)
        guard case .gaveUp = resolution.claim(
            by: Date().addingTimeInterval(-1), isInterrupted: { false }
        ) else {
            return XCTFail("an already-expired deadline must not be waited out")
        }
    }

    /// AXIS: an interrupt ends the wait even with budget remaining.
    func testResolutionGivesUpWhenInterrupted() {
        let resolution = SSHTransport.ResolutionRegistry.resolution(host: "127.0.0.1", port: 22)
        guard case .gaveUp = resolution.claim(
            by: Date().addingTimeInterval(30), isInterrupted: { true }
        ) else {
            return XCTFail("an interrupt must end the wait without spending the budget")
        }
    }

    /// AXIS: sixteen overlapping requests for one endpoint construct exactly
    /// ONE resolver, so a wedged DNS server costs one thread rather than one per
    /// request.
    ///
    /// The previous version of this test counted the `Resolution` objects
    /// callers received and allowed up to eight. That cannot see the bug it
    /// names: a check-create-check registry hands every caller the same shared
    /// object while having started and discarded fifteen threads. The reviewer
    /// restored exactly that shape and the mutation SURVIVED — the test passed
    /// against the broken construction it was written to catch.
    ///
    /// So this counts constructions, and holds the first resolution in flight
    /// with a gate so the callers genuinely overlap rather than hoping they do.
    func testOverlappingRequestsConstructExactlyOneResolver() {
        let gate = DispatchSemaphore(value: 0)
        // Each held thread self-releases, so a failure leaves nothing wedged.
        SSHTransport.Resolution.startGate = { _ = gate.wait(timeout: .now() + 2.0) }
        defer { SSHTransport.Resolution.startGate = nil }

        let before = SSHTransport.Resolution.constructionCount
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = SSHTransport.ResolutionRegistry.resolution(
                host: "resolver-construction-probe.invalid", port: 22
            )
        }
        let constructed = SSHTransport.Resolution.constructionCount - before

        XCTAssertEqual(
            constructed, 1,
            "16 overlapping requests started \(constructed) resolver threads; a wedged resolver would cost one each"
        )
        for _ in 0..<16 { gate.signal() }
    }

    /// AXIS: teardown against a peer that has stopped answering returns, rather
    /// than holding a worker for as long as the peer stays silent.
    ///
    /// This is the condition that made the old shape dangerous rather than
    /// merely untidy. `close()` held its mutex across `libssh2_channel_free`,
    /// the post-auth session timeout is zero, and zero means *no timeout* — so
    /// `channel_free` waited for a close reply that never came, while
    /// `interrupt()` blocked trying to take the lock that would have let it
    /// shut the socket down. The caller had already been resumed; the worker
    /// was gone for good.
    ///
    /// The relay produces exactly that: a fully established session, then a peer
    /// that goes quiet without closing. `close()` runs off the test thread so an
    /// unbounded teardown fails the test instead of hanging it.
    func testTeardownIsBoundedWhenThePeerStopsAnswering() throws {
        SSHRuntime.start()
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let pem = try? String(contentsOfFile: Self.keyPath, encoding: .utf8),
              FileManager.default.fileExists(atPath: socketPath)
        else { throw XCTSkip("no local SSH key or herdr socket") }

        let relay = PausableRelay()
        try relay.start()
        defer { relay.stop() }

        let transport = SSHTransport(credentials: SSHCredentials(
            host: "127.0.0.1", port: relay.port, username: NSUserName(),
            privateKeyPEM: pem, remoteSocketPath: socketPath))

        let live = LiveChannel()
        let session = try transport.openSession(publishingTo: live)
        XCTAssertTrue(live.adopt(session))
        let channel = try transport.openChannel(session)
        live.adopt(channel: channel)

        relay.pause()   // the peer goes silent mid-life, without closing

        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            live.close()
            finished.signal()
        }
        thread.name = "teardown-under-test"
        thread.start()

        // The margin is scheduling slack, not a second teardown. It was three
        // seconds, which let a 2s constant pass while teardown actually took
        // 4.3s — the bound was per-call, so channel_free and the session
        // disconnect each got the full two. Both now share one deadline, so the
        // total is what the constant says and the margin can be small enough to
        // notice if that regresses.
        let started = Date()
        XCTAssertEqual(
            finished.wait(timeout: .now() + SSHTransport.teardownTimeout + 0.75), .success,
            "teardown against a silent peer never returned; a worker is stranded"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started), SSHTransport.teardownTimeout + 0.75,
            "teardown exceeded its stated TOTAL bound"
        )
    }

    /// AXIS: `interrupt()` still lands while a teardown is in progress.
    ///
    /// The finite teardown bound and the detach fix different halves of the same
    /// deadlock and the bound alone is not enough: with the mutex held across
    /// teardown, the one call that could have ended the stall early was the one
    /// call that could not run. This pins the other half — `interrupt()` must
    /// return promptly rather than queue behind an unbounded `channel_free`.
    func testInterruptIsNotBlockedByATeardownInProgress() throws {
        SSHRuntime.start()
        guard FileManager.default.fileExists(atPath: Self.keyPath),
              let pem = try? String(contentsOfFile: Self.keyPath, encoding: .utf8),
              FileManager.default.fileExists(atPath: socketPath)
        else { throw XCTSkip("no local SSH key or herdr socket") }

        let relay = PausableRelay()
        try relay.start()
        defer { relay.stop() }

        let transport = SSHTransport(credentials: SSHCredentials(
            host: "127.0.0.1", port: relay.port, username: NSUserName(),
            privateKeyPEM: pem, remoteSocketPath: socketPath))

        let live = LiveChannel()
        let session = try transport.openSession(publishingTo: live)
        XCTAssertTrue(live.adopt(session))
        live.adopt(channel: try transport.openChannel(session))

        relay.pause()

        let closeFinished = DispatchSemaphore(value: 0)
        let closing = Thread {
            live.close()
            closeFinished.signal()
        }
        closing.name = "teardown-under-test"
        let closeStarted = Date()
        closing.start()

        // Waiting on the signal rather than sleeping a guessed interval. The
        // sleep version passed and failed on alternate runs against identical
        // code, because whether teardown had begun was left to scheduling.
        XCTAssertEqual(
            live.teardownBegan.wait(timeout: .now() + 5.0), .success,
            "close() never reached teardown"
        )

        let returned = DispatchSemaphore(value: 0)
        let interrupting = Thread {
            live.interrupt()
            returned.signal()
        }
        interrupting.name = "interrupt-under-test"
        interrupting.start()
        let interruptOutcome = returned.wait(timeout: .now() + 1.0)
        let closeOutcome = closeFinished.wait(timeout: .now() + SSHTransport.teardownTimeout + 5.0)
        let teardownDuration = Date().timeIntervalSince(closeStarted)

        XCTAssertEqual(
            interruptOutcome, .success,
            "interrupt() blocked behind a teardown holding the lock"
        )
        XCTAssertEqual(closeOutcome, .success, "close() never returned")
        // The interrupt does not merely survive the teardown, it ends it: the
        // socket shutdown unblocks channel_free instead of waiting out the 2s
        // bound. An earlier version of this test asserted the opposite — it
        // skipped unless teardown was SLOW, on the assumption that a fast one
        // meant the stall had not reproduced. That had it backwards, and it
        // skipped all ten runs.
        XCTAssertLessThan(
            teardownDuration, SSHTransport.teardownTimeout,
            "teardown ran to its own bound (\(teardownDuration)s); the interrupt did not shorten it"
        )
    }

    /// REGRESSION: values that are not bounds must not reach libssh2 as one.
    ///
    /// `max(_:_:)` does not clamp NaN — every comparison against NaN is false,
    /// so it returns its first argument untouched — and `Int(nan * 1000)` traps.
    /// Infinity has no `Int` representation and traps the same way. Both used to
    /// reach the conversion.
    func testNonFiniteSetupTimeoutsBecomeRepresentableBounds() {
        for requested in [Double.nan, .infinity, -.infinity, -5] {
            let transport = SSHTransport(
                credentials: SSHCredentials(
                    host: "h", username: "u", privateKeyPEM: "k", remoteSocketPath: "/s"),
                setupTimeout: requested)
            XCTAssertTrue(
                transport.setupTimeout.isFinite,
                "\(requested) survived as a non-finite bound"
            )
            XCTAssertGreaterThanOrEqual(transport.setupTimeout, SSHTransport.minimumSetupTimeout)
            XCTAssertLessThanOrEqual(transport.setupTimeout, SSHTransport.maximumSetupTimeout)
            // The conversion that used to trap.
            XCTAssertGreaterThanOrEqual(Int(transport.setupTimeout * 1000), 1)
        }
    }

    /// TEST-NET-1 (RFC 5737). Reserved for documentation and routed nowhere, so
    /// a SYN to it is normally swallowed rather than refused.
    static let blackholeHost = "192.0.2.1"

    /// Confirms the address really is silent *here* before a test depends on it.
    /// Container networks often answer ENETUNREACH at once, which would turn
    /// every bound assertion below into a test of nothing.
    static func blackholeSwallowsSYN() -> Bool {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        guard inet_pton(AF_INET, blackholeHost, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return false }                     // something answered
        guard errno == EINPROGRESS else { return false } // refused or unreachable at once
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        // Silent means still pending after half a second.
        return poll(&descriptor, 1, 500) == 0
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

/// A TCP relay to the local sshd that can be told to stop forwarding without
/// closing anything.
///
/// This is how a stalled peer is produced deterministically. `SilentPeer` never
/// answers at all, so nothing gets past the handshake; this one lets a session
/// establish completely and only then goes quiet — which is the state teardown
/// has to survive. Nothing is closed on pause, so libssh2 waits for a reply that
/// will never arrive rather than seeing an error.
final class PausableRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var running = true
    private var listenFD: Int32 = -1
    private var open: [Int32] = []
    private var parked = Set<Int>()
    private var nextPumpID = 0
    private(set) var port: UInt16 = 0
    private let upstreamPort: UInt16

    init(upstreamPort: UInt16 = 22) { self.upstreamPort = upstreamPort }

    private var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Pauses, and does not return until BOTH directions have observed it.
    ///
    /// Setting the flag alone is not enough and the difference is the whole
    /// test: a pump already inside `read`/`write` forwards one more frame, and
    /// that frame can be precisely the channel-close reply teardown is waiting
    /// for — so the stall never happens and the test passes for the wrong
    /// reason. Under mutation it survived one run in three that way.
    func pause() {
        lock.lock(); paused = true; parked.removeAll(); lock.unlock()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock(); let settled = parked.count; lock.unlock()
            if settled >= 2 { return }
            usleep(5_000)
        }
    }

    private func notePark(_ id: Int) { lock.lock(); parked.insert(id); lock.unlock() }

    func start() throws {
        listenFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listenFD >= 0 else { throw XCTSkip("relay socket unavailable") }
        var on: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &len) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listen(listenFD, 8)

        let accepting = Thread { [self] in
            while isRunning {
                let client = accept(listenFD, nil, nil)
                if client < 0 { return }
                guard let upstream = connectUpstream() else { close(client); continue }
                lock.lock(); open.append(client); open.append(upstream); lock.unlock()
                pump(from: client, to: upstream)
                pump(from: upstream, to: client)
            }
        }
        accepting.name = "relay-accept"
        accepting.start()
    }

    private func connectUpstream() -> Int32? {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = upstreamPort.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { close(fd); return nil }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    private func pump(from source: Int32, to destination: Int32) {
        lock.lock(); let id = nextPumpID; nextPumpID += 1; lock.unlock()
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while isRunning {
                // Paused means the bytes are neither read nor forwarded: the
                // far side simply stops hearing anything, with no error and no
                // close to react to.
                if isPaused { notePark(id); usleep(20_000); continue }
                var descriptor = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 20) > 0 else { continue }
                let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                var written = 0
                while written < n {
                    let w = buffer.withUnsafeBytes {
                        write(destination, $0.baseAddress!.advanced(by: written), n - written)
                    }
                    if w <= 0 { return }
                    written += w
                }
            }
        }
        thread.name = "relay-pump"
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        paused = false
        let sockets = open
        open = []
        lock.unlock()
        for fd in sockets { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
        if listenFD >= 0 { shutdown(listenFD, Int32(SHUT_RDWR)); close(listenFD); listenFD = -1 }
    }
}
