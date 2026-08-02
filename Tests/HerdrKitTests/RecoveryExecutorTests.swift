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
        /// Recorded for EVERY registration attempt, throwing or not — the
        /// contract-violation test asserted opens == 0 while the fake returned
        /// before recording failures, so the assertion was vacuous by
        /// construction.
        case openAttempt(String, AttemptID)
        case closeAll(AttemptID)
        case discard(AttemptID)
    }

    private let lock = NSLock()
    private var operations: [Operation] = []
    /// Per REGISTRATION, not per pane: overwriting by pane made an older
    /// registration's closure unselectable, so orphan-callback probes could
    /// never pick the stale one.
    private var terminators: [String: [@Sendable () -> Void]] = [:]
    var panesToServe: [String]
    var failConnects = false
    /// Every openStream throws — a persistently broken conformer.
    var failOpens = false
    /// Every fetchSnapshot throws — establishment fails after connect.
    var failSnapshots = false
    /// Panes whose opens always throw, for paired-control tests where one pane
    /// is healthy and one is not.
    var failingPanes: Set<String> = []
    /// Installs the callback and THEN throws: the ownership violation the seam
    /// now forbids, kept as a probe of what the executor does when a conformer
    /// breaks the contract anyway.
    var installsThenThrows = false
    /// When set, openStream suspends (a REAL actor suspension, not a thread
    /// block) until the flag clears — the door interleavings walk through.
    private var stalledPanes: Set<String> = []

    func stall(_ pane: String) { lock.withLock { _ = stalledPanes.insert(pane) } }
    func release(_ pane: String) { lock.withLock { _ = stalledPanes.remove(pane) } }
    private func isStalled(_ pane: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stalledPanes.contains(pane)
    }

    init(panes: [String]) { self.panesToServe = panes }

    func log() -> [Operation] { lock.lock(); defer { lock.unlock() }; return operations }
    private func record(_ op: Operation) { lock.withLock { operations.append(op) } }

    /// Kills a pane's stream from the outside, firing its termination exactly
    /// once — the contract the executor promises the policy.
    /// Fires the NEWEST registration's termination.
    func killStream(_ pane: String) {
        let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
            guard var list = terminators[pane], !list.isEmpty else { return nil }
            let last = list.removeLast()
            terminators[pane] = list
            return last
        }
        terminate?()
    }

    /// Fires the OLDEST registration's termination — the orphaned-callback case.
    func killOldestRegistration(_ pane: String) {
        let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
            guard var list = terminators[pane], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            terminators[pane] = list
            return first
        }
        terminate?()
    }

    /// A MISBEHAVING transport: fires the SAME registration's termination
    /// twice, which the executor's once-latch must reduce to one death.
    func killStreamTwice(_ pane: String) {
        let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
            guard var list = terminators[pane], !list.isEmpty else { return nil }
            let last = list.removeLast()
            terminators[pane] = list
            return last
        }
        terminate?()
        terminate?()
    }

    /// One-shot, SELF-RELEASING close stall.
    ///
    /// Self-releasing because a test-controlled release deadlocks: the test
    /// awaits the interleaving event, that event parks inside the stalled
    /// closeAll, and the release never runs because the test is still awaiting.
    /// My first version did exactly that and hung the suite.
    private var closeStallSeconds: TimeInterval = 0
    func stallFirstClose(_ seconds: TimeInterval) {
        lock.withLock { closeStallSeconds = seconds }
    }
    private func takeCloseStall() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let seconds = closeStallSeconds
        closeStallSeconds = 0
        return seconds
    }

    func connect(for attempt: AttemptID) async throws {
        record(.connect(attempt))
        if failConnects { throw TransportError.closedBeforeResponse }
    }

    func fetchSnapshot(for attempt: AttemptID) async throws -> PaneSnapshot {
        record(.fetchSnapshot(attempt))
        if failSnapshots { throw TransportError.closedBeforeResponse }
        let served = lock.withLock { panesToServe }
        return PaneSnapshot(agents: try SessionRecoveryTests.decodePanes(served))
    }

    func openStream(
        pane: String, for attempt: AttemptID,
        onTermination: @escaping @Sendable () -> Void
    ) async throws {
        while isStalled(pane) { try? await Task.sleep(nanoseconds: 10_000_000) }
        record(.openAttempt(pane, attempt))
        if failOpens || lock.withLock({ failingPanes.contains(pane) }) {
            if installsThenThrows {
                lock.withLock { terminators[pane, default: []].append(onTermination) }
            }
            throw TransportError.closedBeforeResponse
        }
        record(.openStream(pane, attempt))
        lock.withLock { terminators[pane, default: []].append(onTermination) }
    }

    func closeAll(for attempt: AttemptID) async {
        let stall = takeCloseStall()
        if stall > 0 { try? await Task.sleep(nanoseconds: UInt64(stall * 1_000_000_000)) }
        record(.closeAll(attempt))
    }
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
    /// CONDITION 4's cold-start half. The subscribe-from-memory mutation is
    /// NOT run against this test — cold-start memory is empty, so it survived
    /// here vacuously; the reconnect variant below is the armed one the
    /// mutation kills against. This asserts the happy-path operation order.
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
        // "No work runs on it" is asserted, not narrated: no resync and no
        // stream may target the discarded attempt after its discard. A mutation
        // appending a resync for it survived when only the discard was pinned.
        let ops = transport.log()
        let discardIndex = ops.firstIndex(of: .discard(retired))!
        XCTAssertFalse(ops[discardIndex...].contains(.fetchSnapshot(retired)),
                       "a resync ran on the discarded attempt")
        XCTAssertFalse(ops[discardIndex...].contains { if case .openStream(_, retired) = $0 { return true }; return false },
                       "a stream opened on the discarded attempt")
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
        let resettled = await waitUntil { await executor.subscribedPanes == ["p1"] }
        XCTAssertTrue(resettled, "the replacement never settled; the log below would be mid-flight")
        let streamsBefore = transport.log().filter { if case .openStream = $0 { return true }; return false }.count

        // A's delayed plan arrives: a subscribe bound to the retired attempt.
        // Constructed directly — the executor cannot know how a stale plan was
        // produced, only that its binding does not match.
        await executor.execute(RecoveryPlan([.subscribe(["p1"], on: retired)]))

        let streamsAfter = transport.log().filter { if case .openStream = $0 { return true }; return false }.count
        XCTAssertEqual(streamsAfter, streamsBefore, "a retired attempt's subscribe opened a stream")
        let rejections = await executor.rejections
        XCTAssertEqual(rejections.count, 1, "the rejection must be observable, not silent")
        // first?/??, not [0]: when the guard regressed, the empty-array index
        // trapped with signal 4 and killed the WHOLE suite — a regression must
        // read as failures the harness can classify, not as a crash.
        XCTAssertTrue(rejections.first?.reason.contains("retired") ?? false)
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

    /// AXIS: a stale plan's reconnect neither dials a retired attempt NOR
    /// cancels the current attempt's pending dial — the wedge the sweep
    /// reproduced 4/4: the stale dial's cancel landed on the replacement's
    /// backoff sleep, the silent cancellation return scheduled nothing, and
    /// the executor sat wedged with currentAttempt set and no dial in flight.
    func testAStalePlansReconnectCannotWedgeTheExecutor() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.isConnected }
        let retired = await executor.currentAttempt!

        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }
        let current = await executor.currentAttempt!
        let connectsBefore = transport.log().filter { if case .connect = $0 { return true }; return false }.count

        // The stale plan replays, reconnect bound to the retired attempt.
        await executor.execute(RecoveryPlan([.reconnect(retired, after: 0)]))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(transport.log().suffix(from: 0).contains { op in
            if case .connect(let a) = op { return a == retired } else { return false }
        } && transport.log().filter { $0 == .connect(retired) }.count > 1,
        "the retired attempt was re-dialed")
        let connectsAfter = transport.log().filter { if case .connect = $0 { return true }; return false }.count
        XCTAssertEqual(connectsAfter, connectsBefore, "a stale reconnect dialed something")
        let stillCurrent = await executor.currentAttempt
        XCTAssertEqual(stillCurrent, current, "the stale plan disturbed the current attempt")
        let rejected = await executor.rejections
        XCTAssertTrue(rejected.contains { $0.action == "reconnect" }, "the refusal must be observable")
    }

    /// AXIS: an interleaved replacement's resource claim survives the first
    /// plan's teardown continuation — cancelTransport keeps closing the RIGHT
    /// attempt afterwards.
    ///
    /// The sweep's 4/4 reproduction: two rapid networkChanged; the first plan's
    /// post-closeAll continuation unconditionally cleared resourcedAttempt,
    /// destroying the second plan's claim — after which every teardown closed a
    /// resource-less attempt while the current one's streams leaked forever.
    func testAnInterleavedClaimSurvivesTheFirstPlansTeardown() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.subscribedPanes == ["p1"] }

        transport.stallFirstClose(0.3)   // N1's teardown parks inside closeAll
        Task { await executor.handle(.networkChanged(at: Date())) }   // N1
        try? await Task.sleep(nanoseconds: 50_000_000)
        await executor.handle(.networkChanged(at: Date()))            // N2, unstalled
        let settled = await waitUntil { await executor.isConnected }
        XCTAssertTrue(settled, "the replacement never connected")
        let current = await executor.currentAttempt!
        // N1's continuation resumes after its stall and writes its clear.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The decisive probe: a THIRD teardown must close the CURRENT attempt.
        await executor.handle(.backgrounded(at: Date()))
        let closed = await waitUntil {
            transport.log().contains { $0 == .closeAll(current) }
        }
        XCTAssertTrue(closed,
                      "teardown closed a resource-less attempt while the current one's streams leaked")
    }

    /// AXIS: the executor HONOURS the policy's backoff — the dial waits exactly
    /// the drawn delay, pinned through the sleeper seam because wall-clock
    /// assertions let a delete-the-delay mutation survive 5/5.
    func testTheDialHonoursThePolicysBackoffDelay() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        transport.failConnects = true
        let recorder = SleepRecorder()
        let executor = RecoveryExecutor(
            recovery: SessionRecovery(), transport: transport,
            generator: SeededGenerator(seed: 42))
        await executor.setSleeper { delay in await recorder.record(delay) }

        await executor.start()
        let reachedSleep = await waitUntil { await recorder.recorded().count >= 1 }
        XCTAssertTrue(reachedSleep, "the failed dial never reached its backoff sleep")

        let delays = await recorder.recorded()
        // Deterministic: the seeded generator draws the same jitter every run.
        var reference = SeededGenerator(seed: 42)
        let expected = SessionRecovery().backoff(failures: 1, using: &reference)
        // XCTUnwrap, not `!`: with the delay deleted the assertion above fails
        // AND the force-unwrap trapped with signal 4, which the mutation
        // harness reads as INVALID rather than KILLED — a real kill misfiled as
        // a broken run. Same class the sweep found in the rejection test.
        let slept = try XCTUnwrap(delays.first, "no delay was recorded")
        XCTAssertEqual(slept, expected, accuracy: 0.0001,
                       "the executor slept \(slept)s where the policy drew \(expected)s")
        XCTAssertGreaterThan(expected, 0, "a zero draw would make this assertion vacuous")
    }

    /// AXIS: teardown actually reaches the transport — a networkChanged closes
    /// the attempt that held resources. The executor could previously leak
    /// every stream with the suite green: nothing pinned closeAll at all.
    func testTeardownClosesTheResourcedAttemptAtTheTransport() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.subscribedPanes == ["p1"] }
        let resourced = await executor.currentAttempt!

        await executor.handle(.networkChanged(at: Date()))
        XCTAssertTrue(transport.log().contains(.closeAll(resourced)),
                      "the resourced attempt's streams were never closed at the transport")
    }

    /// AXIS: a transport double-firing one termination produces ONE death — the
    /// once-latch enforces the contract the seam previously only stated. The
    /// probe without it: three opens for one real death, a permanent
    /// double-subscription the policy cannot dedup without swallowing real
    /// second deaths.
    func testADoubleFiredTerminationProducesOneDeath() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.subscribedPanes == ["p1"] }
        let attempt = await executor.currentAttempt!

        transport.killStreamTwice("p1")
        _ = await waitUntil {
            transport.log().filter { $0 == .openStream("p1", attempt) }.count >= 2
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(transport.log().filter { $0 == .openStream("p1", attempt) }.count, 2,
                       "one death must produce exactly one replacement open")
        let rejections = await executor.rejections
        XCTAssertTrue(rejections.contains { $0.reason.contains("duplicate termination") },
                      "the dropped duplicate must be observable")
    }

actor SleepRecorder {
    private var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
    func recorded() -> [TimeInterval] { delays }
}

    /// AXIS: a teardown completing WHILE an open is in flight leaves no stream
    /// registered for the retired attempt — the recheck-and-reap after the
    /// await, which the pre-await guard structurally cannot cover.
    ///
    /// The earlier mid-loop regression missed this: it asserted the SECOND pane
    /// stayed closed, while the first pane's registration was recorded after
    /// closeAll and unexamined.
    func testAnOpenCompletingAfterTeardownIsReaped() async throws {
        let transport = ScriptedTransport(panes: ["only"])
        let executor = RecoveryExecutor(transport: transport)
        transport.stall("only")                       // the open suspends
        await executor.start()
        _ = await waitUntil {
            transport.log().contains { if case .fetchSnapshot = $0 { return true }; return false }
        }
        let retired = await executor.currentAttempt!

        await executor.handle(.networkChanged(at: Date()))   // teardown completes
        transport.release("only")                            // the open lands late

        let reaped = await waitUntil {
            let ops = transport.log()
            guard let open = ops.firstIndex(of: .openStream("only", retired)) else { return false }
            return ops[open...].contains(.closeAll(retired))
        }
        XCTAssertTrue(reaped,
                      "a stream published for the retired attempt after its teardown was never reaped")
        let rejected = await executor.rejections
        XCTAssertTrue(rejected.contains { $0.reason.contains("reaped") }, "the reap must be observable")
    }

    /// AXIS: a persistently failing openStream cannot spin — the failure count
    /// caps the retries and the pane is left visibly unsubscribed.
    ///
    /// Without the cap: an open that throws becomes streamFailed, the policy
    /// re-admits, the re-admission opens again — an unbounded, delay-free loop
    /// that saturates the actor. Deterministic here: the transport always
    /// throws, and the sleeper is recorded rather than slept.
    func testAPersistentlyFailingOpenCannotSpin() async throws {
        let transport = ScriptedTransport(panes: ["bad"])
        transport.failOpens = true
        let recorder = SleepRecorder()
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { delay in await recorder.record(delay) }
        await executor.start()

        let capped = await waitUntil(8) {
            await executor.rejections.contains { $0.reason.contains("left unsubscribed") }
        }
        XCTAssertTrue(capped, "the retry loop never hit its cap")

        let backoffs = await recorder.recorded()
        XCTAssertGreaterThan(backoffs.count, 0, "retries must be delayed, not immediate")
        XCTAssertTrue(backoffs.allSatisfy { $0 > 0 })
        XCTAssertLessThanOrEqual(backoffs.count, RecoveryExecutor.openFailureCap,
                                 "retries exceeded the cap: \(backoffs.count) attempts")

        // KNOWN GAP, asserted so it cannot change silently and ESCALATED rather
        // than fixed here: the ledger still lists the pane, because admission
        // happens at observe time and records intent, not an open stream. The
        // pane therefore reads as subscribed while nothing is watching it —
        // the silence class this task exists to remove, one level in. Closing
        // it means the policy distinguishing admitted-from-open, which is a
        // POLICY change and belongs in its own review round (condition 2).
        let subscribed = await executor.subscribedPanes
        XCTAssertTrue(subscribed.contains("bad"),
                      "documented gap changed: the ledger no longer lists an unopenable pane — if this now fails, the policy gained admitted-vs-open and this test should assert the better behaviour")
    }

    /// AXIS: a conformer that violates the seam — installing a callback and
    /// THEN throwing — cannot make the executor open a third stream when that
    /// orphaned callback finally fires.
    ///
    /// The seam now forbids this outright; the test records what happens when a
    /// conformer breaks the contract anyway, because "requirement on the
    /// conformer" is only as strong as what the executor does when it is
    /// violated.
    func testAnOrphanedCallbackFromAFailedRegistrationCannotStackStreams() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        transport.failOpens = true
        transport.installsThenThrows = true
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { _ in }
        await executor.start()
        _ = await waitUntil(8) {
            await executor.rejections.contains { $0.reason.contains("left unsubscribed") }
        }
        let attemptsAtCap = transport.log().filter {
            if case .openAttempt = $0 { return true }; return false
        }.count
        XCTAssertGreaterThan(attemptsAtCap, 0, "precondition: registrations were attempted")
        XCTAssertLessThanOrEqual(attemptsAtCap, RecoveryExecutor.openFailureCap + 1,
                                 "the cap did not bound registration attempts")

        // The OLDEST registration's orphaned callback fires late.
        transport.killOldestRegistration("p1")
        try? await Task.sleep(nanoseconds: 300_000_000)

        let attemptsAfter = transport.log().filter {
            if case .openAttempt = $0 { return true }; return false
        }.count
        XCTAssertEqual(attemptsAfter, attemptsAtCap,
                       "an orphaned callback restarted registration attempts past the cap")
        XCTAssertEqual(transport.log().filter { if case .openStream = $0 { return true }; return false }.count, 0,
                       "no open ever succeeded, so none may be recorded")
    }

    /// AXIS: the diagnostics buffer is bounded and drainable — append-only was
    /// a slow leak on a long-running client, where stale plans and duplicate
    /// callbacks are rare but unbounded over days.
    func testRejectionsAreBoundedAndDrainable() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.isConnected }
        let retired = await executor.currentAttempt!
        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }

        // More stale plans than the buffer holds.
        for _ in 0..<(RecoveryExecutor.rejectionCapacity + 20) {
            await executor.execute(RecoveryPlan([.subscribe(["p1"], on: retired)]))
        }

        let held = await executor.rejections.count
        XCTAssertLessThanOrEqual(held, RecoveryExecutor.rejectionCapacity,
                                 "the buffer grew past its cap: \(held)")
        let dropped = await executor.droppedRejections
        XCTAssertGreaterThan(dropped, 0, "overflow must be counted, not silent")

        let drained = await executor.drainRejections()
        XCTAssertEqual(drained.entries.count, held)
        let afterDrain = await executor.rejections.count
        XCTAssertEqual(afterDrain, 0, "drain must clear")
    }

    /// AXIS: failure counters are retired with their attempt — they were one
    /// more unbounded structure, and the whole-suite mutation removing the
    /// retirement SURVIVED because nothing observed the count.
    func testFailureCountersAreRetiredWithTheirAttempt() async throws {
        let transport = ScriptedTransport(panes: ["bad"])
        transport.failingPanes = ["bad"]
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { _ in }
        await executor.start()
        _ = await waitUntil(8) { await executor.openFailureEntryCount > 0 }

        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }
        // The new attempt fails "bad" afresh; only ITS keys may exist.
        _ = await waitUntil(8) {
            await executor.rejections.contains { $0.reason.contains("left unsubscribed") }
        }
        let staleFree = await executor.openFailureEntryCountForRetiredAttempts == 0
        XCTAssertTrue(staleFree, "retired attempts' failure counters were retained")
    }

    /// THE COORDINATOR'S PAIRED CONTROL: a healthy pane reports `.open` AND a
    /// persistently-failing pane reports `.admittedNotOpen`, through the SAME
    /// accessor in the same test. One control alone is satisfied by a
    /// degenerate implementation answering the same thing for everything —
    /// this is the discriminating-evidence requirement made executable.
    func testPaneStatusDiscriminatesOpenFromAdmittedNotOpen() async throws {
        let transport = ScriptedTransport(panes: ["healthy", "broken"])
        transport.failingPanes = ["broken"]
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { _ in }
        await executor.start()
        _ = await waitUntil(8) {
            await executor.rejections.contains { $0.reason.contains("left unsubscribed") }
        }
        let healthySettled = await waitUntil { await executor.paneStatus("healthy") == .open }
        XCTAssertTrue(healthySettled, "the healthy pane must report open")

        let brokenStatus = await executor.paneStatus("broken")
        guard case .admittedNotOpen(let attempts, let lastError) = brokenStatus else {
            return XCTFail("the unwatched pane reads as \(brokenStatus) — the silent-pane lie, unqueryable")
        }
        XCTAssertGreaterThan(attempts, 0, "the attempt count must be carried")
        XCTAssertNotNil(lastError, "the last error must be carried")
        let unknown = await executor.paneStatus("never-heard-of")
        XCTAssertEqual(unknown, .notAdmitted)
    }

    /// AXIS: a failure while establishing (snapshot fetch throws) closes the
    /// failed attempt's resources BEFORE the replacement's claim installs.
    ///
    /// The failure paths route through the policy, whose plan is reconnect
    /// only — no cancelTransport — so the replacement dial overwrote the claim
    /// and the failed attempt's connection and any opened streams became
    /// unreachable forever. The reviewer's probe: B connected with no
    /// closeAll(A) anywhere in the log.
    func testAnEstablishmentFailureClosesTheFailedAttemptBeforeReplacement() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        transport.failSnapshots = true
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { _ in }
        await executor.start()

        let secondConnect = await waitUntil {
            transport.log().filter { if case .connect = $0 { return true }; return false }.count >= 2
        }
        XCTAssertTrue(secondConnect, "the snapshot failure never produced a replacement dial")

        let ops = transport.log()
        guard case .connect(let attemptA) = ops.first else { return XCTFail("no first dial") }
        // XCTUnwrap, not `!`: the force-unwrap after a failing NotNil turned a
        // real kill into signal 4 — the crash-instead-of-fail class, third
        // instance today, caught by the mutation run reading INVALID.
        let closeA = try XCTUnwrap(ops.firstIndex(of: .closeAll(attemptA)),
                                   "the failed attempt's resources were never closed — unreachable forever")
        let secondDial = try XCTUnwrap(ops.firstIndex { op in
            if case .connect(let a) = op { return a != attemptA } else { return false }
        })
        XCTAssertLessThan(closeA, secondDial, "the close must precede the replacement's dial")
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
        // Short, and NOT the pin: the deterministic pin is the sleeper-based
        // test above — this residual window only catches a dial that fires
        // immediately despite the cancel.
        try? await Task.sleep(nanoseconds: 200_000_000)
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
    private struct Key: Hashable {
        let attempt: AttemptID
        let pane: String
    }

    private let client: HerdrClient
    private let lock = NSLock()
    private var streams: [Key: Task<Void, Never>] = [:]
    private var tornDown: Set<AttemptID> = []

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
            // A teardown-by-closeAll is not a death: the seam requires that a
            // stream torn down deliberately fires no termination — the first
            // version fired on cancellation, so every teardown would have
            // produced a spurious streamFailed per pane.
            guard !Task.isCancelled else { return }
            onTermination()
        }
        // Registered under the lock, and reaped immediately if a teardown for
        // this attempt already ran — the same register-after-close window the
        // executor closes on its side; a conformer must not leave one either.
        let key = Key(attempt: attempt, pane: pane)
        let stillWanted = lock.withLock { () -> Bool in
            guard !tornDown.contains(attempt) else { return false }
            streams[key] = task
            return true
        }
        if !stillWanted { task.cancel() }
    }

    /// Attempt-SCOPED, as the seam requires. The first version dropped every
    /// stream regardless of attempt — `attempt` was unused — which violated
    /// the very requirement this adapter is cited as proving implementable.
    func closeAll(for attempt: AttemptID) async {
        let mine = lock.withLock { () -> [Key: Task<Void, Never>] in
            tornDown.insert(attempt)
            let matching = streams.filter { $0.key.attempt == attempt }
            for key in matching.keys { streams.removeValue(forKey: key) }
            return matching
        }
        for task in mine.values { task.cancel() }
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
