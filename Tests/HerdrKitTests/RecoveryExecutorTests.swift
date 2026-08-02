import XCTest
@testable import HerdrKit

/// A scripted transport that records every operation in order and can be told
/// to fail, stall, or deliver late.
///
/// The interesting cases live here and cannot live against the network: a
/// delayed completion from a retired attempt, a stream that dies on cue, a
/// snapshot that races a reconnect. The log is the test surface — assertions
/// read the ORDER of operations, because ordering is what the coordinator made
/// an acceptance criterion.
final class ScriptedTransport: ExecutorTransport, @unchecked Sendable {
    enum Operation: Equatable {
        case connect(AttemptID)
        case fetchSnapshot(AttemptID)
        case openStream(String, AttemptID)
        case closeAll(AttemptID)
        case discard(AttemptID)
    }

    private let lock = NSLock()
    private var operations: [Operation] = []
    private var terminators: [String: @Sendable () -> Void] = [:]
    var panesToServe: [String]
    var failConnects = false
    /// When set, openStream suspends (a REAL actor suspension, not a thread
    /// block) until the flag clears — the door interleavings walk through.
    private var stalledPanes: Set<String> = []

    func stall(_ pane: String) { lock.lock(); stalledPanes.insert(pane); lock.unlock() }
    func release(_ pane: String) { lock.lock(); stalledPanes.remove(pane); lock.unlock() }
    private func isStalled(_ pane: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stalledPanes.contains(pane)
    }

    init(panes: [String]) { self.panesToServe = panes }

    func log() -> [Operation] { lock.lock(); defer { lock.unlock() }; return operations }
    private func record(_ op: Operation) { lock.lock(); operations.append(op); lock.unlock() }

    /// Kills a pane's stream from the outside, firing its termination exactly
    /// once — the contract the executor promises the policy.
    func killStream(_ pane: String) {
        lock.lock()
        let terminate = terminators.removeValue(forKey: pane)
        lock.unlock()
        terminate?()
    }

    func connect(for attempt: AttemptID) async throws {
        record(.connect(attempt))
        if failConnects { throw TransportError.closedBeforeResponse }
    }

    func fetchSnapshot(for attempt: AttemptID) async throws -> PaneSnapshot {
        record(.fetchSnapshot(attempt))
        let served = lock.withLock { panesToServe }
        return PaneSnapshot(agents: try SessionRecoveryTests.decodePanes(served))
    }

    func openStream(
        pane: String, for attempt: AttemptID,
        onTermination: @escaping @Sendable () -> Void
    ) async throws {
        while isStalled(pane) { try? await Task.sleep(nanoseconds: 10_000_000) }
        record(.openStream(pane, attempt))
        lock.lock(); terminators[pane] = onTermination; lock.unlock()
    }

    func closeAll(for attempt: AttemptID) async { record(.closeAll(attempt)) }
    func discard(attempt: AttemptID) async { record(.discard(attempt)) }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}

final class RecoveryExecutorTests: XCTestCase {
    /// Waits until the executor settles (no fixed sleeps: poll a condition).
    private func waitUntil(
        _ timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// THE HAPPY PATH, asserted on the operation ORDER: dial, resync, then
    /// streams — and every stream open comes AFTER the snapshot fetch.
    ///
    /// CONDITION 4 lives here: resync-before-subscribe is documented as
    /// load-bearing, so this test must FAIL when the order is swapped. It does
    /// so structurally — subscriptions exist only downstream of `apply` — and
    /// the mutation reintroducing memory-derived early subscription is run
    /// against exactly this assertion.
    func testColdStartResyncsBeforeAnyStreamOpens() async throws {
        let transport = ScriptedTransport(panes: ["p1", "p2"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()

        let settled = await waitUntil { await executor.subscribedPanes == ["p1", "p2"] }
        XCTAssertTrue(settled, "the cold start never reached full subscription")

        let ops = transport.log()
        guard case .connect(let attempt) = ops.first else {
            return XCTFail("the first operation must be the dial, got \(ops)")
        }
        XCTAssertEqual(ops[1], .fetchSnapshot(attempt), "resync must be the first post-connect operation")
        let firstStream = ops.firstIndex { if case .openStream = $0 { return true }; return false }
        let snapshotIndex = ops.firstIndex(of: .fetchSnapshot(attempt))!
        XCTAssertNotNil(firstStream)
        XCTAssertGreaterThan(firstStream!, snapshotIndex,
                             "a stream opened BEFORE the snapshot: subscribe-from-memory is back")
        XCTAssertEqual(Set(ops.compactMap { if case .openStream(let p, _) = $0 { return p }; return nil }),
                       ["p1", "p2"])
    }

    /// CONDITION 4, armed: a RECONNECT adoption — where memory is non-empty —
    /// must still fetch the snapshot before any stream opens.
    ///
    /// The cold-start version of this assertion let the subscribe-from-memory
    /// mutation SURVIVE, because a cold start has nothing remembered and the
    /// wrongly-early subscription opened zero streams. The hazard only arms
    /// when adoption happens with knowledge aboard; this drives it.
    func testReconnectAdoptionResyncsBeforeAnyStreamOpensDespiteMemory() async throws {
        let transport = ScriptedTransport(panes: ["p1", "p2"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.subscribedPanes == ["p1", "p2"] }

        // Memory is now non-empty. Reconnect.
        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.subscribedPanes == ["p1", "p2"] }
        let attemptB = await executor.currentAttempt!

        let ops = transport.log()
        let snapshotB = ops.firstIndex(of: .fetchSnapshot(attemptB))
        let firstStreamB = ops.firstIndex { if case .openStream(_, attemptB) = $0 { return true }; return false }
        XCTAssertNotNil(snapshotB); XCTAssertNotNil(firstStreamB)
        XCTAssertGreaterThan(firstStreamB!, snapshotB!,
                             "a stream opened on B before B's snapshot: memory-derived subscription is back")
    }

    /// CONDITION 1, half one: a connection completing for a RETIRED attempt is
    /// discarded at the transport, and no work runs on it.
    func testADelayedCompletionFromARetiredAttemptIsDiscardedAtTheTransport() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.isConnected }

        // The network changes; attempt A is retired, B dials.
        let retired = await executor.currentAttempt!
        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }

        // A's completion arrives late, as an event (the second door).
        await executor.handle(.connected(retired, at: Date()))

        XCTAssertTrue(transport.log().contains(.discard(retired)),
                      "the stale completion must be discarded AT the transport, not only in policy")
        let current = await executor.currentAttempt
        XCTAssertNotEqual(current, retired, "the retired attempt must not have been adopted")
    }

    /// CONDITION 1, half two: a subscribe bound to a retired attempt is
    /// REJECTED at execution, observably.
    func testASubscribeBoundToARetiredAttemptIsRejectedAtExecution() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let recovery = SessionRecovery()
        let executor = RecoveryExecutor(recovery: recovery, transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.isConnected }
        let retired = await executor.currentAttempt!

        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }
        let streamsBefore = transport.log().filter { if case .openStream = $0 { return true }; return false }.count

        // A's delayed plan arrives: a subscribe bound to the retired attempt.
        // Constructed directly — the executor cannot know how a stale plan was
        // produced, only that its binding does not match.
        await executor.execute(RecoveryPlan([.subscribe(["p1"], on: retired)]))

        let streamsAfter = transport.log().filter { if case .openStream = $0 { return true }; return false }.count
        XCTAssertEqual(streamsAfter, streamsBefore, "a retired attempt's subscribe opened a stream")
        let rejections = await executor.rejections
        XCTAssertEqual(rejections.count, 1, "the rejection must be observable, not silent")
        XCTAssertTrue(rejections[0].reason.contains("retired"))
    }

    /// REQUIREMENT ONE end-to-end: one pane's stream dies; exactly that pane is
    /// re-subscribed, exactly once, on the same attempt; the other pane's
    /// stream is untouched.
    func testASingleStreamDeathResubscribesExactlyThatPane() async throws {
        let transport = ScriptedTransport(panes: ["p1", "p2"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.subscribedPanes == ["p1", "p2"] }
        let attempt = await executor.currentAttempt!
        let opensBefore = transport.log().filter { if case .openStream = $0 { return true }; return false }

        transport.killStream("p2")

        let reopened = await waitUntil {
            transport.log().filter { $0 == .openStream("p2", attempt) }.count == 2
        }
        XCTAssertTrue(reopened, "the dead pane was never re-subscribed")
        let opensAfter = transport.log().filter { if case .openStream = $0 { return true }; return false }
        XCTAssertEqual(opensAfter.count, opensBefore.count + 1,
                       "exactly ONE stream open may follow one death — \(opensAfter.count - opensBefore.count) did")
        XCTAssertEqual(transport.log().filter { $0 == .openStream("p1", attempt) }.count, 1,
                       "the living pane's stream must be untouched")
    }

    /// AXIS: a retirement interleaving MID-LOOP stops the remaining streams —
    /// the binding holds per pane, not merely at the loop's door.
    ///
    /// The actor suspends at every openStream await. The binding was checked
    /// once before the loop, so a networkChanged arriving while pane 1's open
    /// was suspended let pane 2 open for the RETIRED attempt — after closeAll
    /// had already run for it, so the late stream was an orphan nothing would
    /// ever close.
    func testARetirementMidSubscribeLoopStopsTheRemainingStreams() async throws {
        let transport = ScriptedTransport(panes: ["a-first", "b-second"])
        let executor = RecoveryExecutor(transport: transport)
        transport.stall("a-first")             // pane 1 suspends inside its open
        await executor.start()

        _ = await waitUntil {
            transport.log().contains { if case .fetchSnapshot = $0 { return true }; return false }
        }
        let attemptA = await executor.currentAttempt!

        // While the loop is suspended on pane 1, the world moves.
        await executor.handle(.networkChanged(at: Date()))
        transport.release("a-first")

        // Give A's loop every chance to finish; B's own subscribes are for
        // attempt B and do not confound the assertion.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(transport.log().contains { $0 == .openStream("b-second", attemptA) },
                       "the loop opened a stream for a retired attempt after its closeAll")
    }

    /// A dial that fails schedules the retry through the policy (backoff), and
    /// a network change cancels a pending dial rather than racing it.
    func testAFailedDialRetriesAndACancelledDialDoesNotLand() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        transport.failConnects = true
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()

        let retried = await waitUntil(8) {
            transport.log().filter { if case .connect = $0 { return true }; return false }.count >= 2
        }
        XCTAssertTrue(retried, "a failed dial must retry through the policy's backoff")

        transport.failConnects = false
        await executor.handle(.backgrounded(at: Date()))
        let connectsAtBackground = transport.log().filter { if case .connect = $0 { return true }; return false }.count
        try? await Task.sleep(nanoseconds: 500_000_000)
        let connectsAfter = transport.log().filter { if case .connect = $0 { return true }; return false }.count
        XCTAssertEqual(connectsAfter, connectsAtBackground,
                       "a pending dial survived backgrounding: the cancel did not land")
    }
}

/// The live half of the verification bar: the executor against the REAL herdr
/// socket, through a real `HerdrClient`.
///
/// Test-local adapter, deliberately: the production SSH adapter belongs to the
/// app layer and needs credentials this box's suite already exercises
/// elsewhere; what the LIVE bar proves here is that the executor's contract —
/// connect, snapshot, per-pane streams — is implementable over the actual
/// wire, not just the scripted fake.
final class LiveHerdrTransport: ExecutorTransport, @unchecked Sendable {
    private let client: HerdrClient
    private let lock = NSLock()
    private var streams: [String: Task<Void, Never>] = [:]

    init(client: HerdrClient) { self.client = client }

    func connect(for attempt: AttemptID) async throws {
        _ = try await client.agentList()   // a real round trip is the connection proof
    }

    func fetchSnapshot(for attempt: AttemptID) async throws -> PaneSnapshot {
        try await client.paneSnapshot()
    }

    func openStream(
        pane: String, for attempt: AttemptID,
        onTermination: @escaping @Sendable () -> Void
    ) async throws {
        let stream = client.subscribe([Subscription(.paneTurnCompleted, paneID: pane)])
        let task = Task {
            do { for try await _ in stream {} } catch {}
            onTermination()
        }
        lock.lock(); streams[pane] = task; lock.unlock()
    }

    func closeAll(for attempt: AttemptID) async {
        lock.lock(); let open = streams; streams = [:]; lock.unlock()
        for task in open.values { task.cancel() }
    }

    func discard(attempt: AttemptID) async { await closeAll(for: attempt) }
}

final class LiveRecoveryExecutorTests: XCTestCase {
    /// The executor cold-starts against the real server: dials, resyncs from
    /// the real pane set, and opens a real event stream per pane.
    func testExecutorColdStartsAgainstTheLiveServer() async throws {
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: path), "no live herdr server")

        let client = HerdrClient(transport: UnixSocketTransport(path: path))
        let transport = LiveHerdrTransport(client: client)
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()

        let deadline = Date().addingTimeInterval(10)
        var subscribed: Set<String> = []
        while Date() < deadline {
            subscribed = await executor.subscribedPanes
            if !subscribed.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let known = await executor.knownPanes
        XCTAssertFalse(known.isEmpty, "the live resync must discover the real panes")
        XCTAssertEqual(subscribed, known, "every discovered pane must carry a live stream")
        let connected = await executor.isConnected
        XCTAssertTrue(connected)

        // Teardown so the suite leaves no streams behind on the live server.
        await executor.handle(.backgrounded(at: Date()))
    }
}
