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
    /// Only the FIRST open of each pane succeeds; every later one throws. Lets
    /// a test have one live registration and no possible replacement, without
    /// racing a flag against the executor.
    var onlyFirstOpenSucceeds = false
    private var opensSeen: Set<String> = []
    /// Installs the callback and THEN throws: the ownership violation the seam
    /// now forbids, kept as a probe of what the executor does when a conformer
    /// breaks the contract anyway.
    var installsThenThrows = false
    /// When set, openStream suspends (a REAL actor suspension, not a thread
    /// block) until the flag clears — the door interleavings walk through.
    private var stalledPanes: Set<String> = []

    func stall(_ pane: String) { lock.withLock { _ = stalledPanes.insert(pane) } }
    /// Releases both gates: the shared pane stall and the catch window's own.
    /// The catch release is LATCHED rather than a removal — a removal can be
    /// undone by a later insert, which is precisely how the replacement attempt
    /// re-armed a gate the test had already opened.
    func release(_ pane: String) {
        lock.withLock { _ = stalledPanes.remove(pane); _ = catchReleased.insert(pane) }
    }

    /// Kill-on-registration: arms a flag so the pane's NEXT registered
    /// terminator fires immediately, INSIDE openStream before it returns —
    /// the termination-races-the-return interleaving made deterministic.
    private var killOnRegister: Set<String> = []
    func releaseAndKill(_ pane: String) {
        lock.withLock {
            _ = stalledPanes.remove(pane)
            _ = killOnRegister.insert(pane)
        }
    }

    /// The first open for this pane SUCCEEDS and fires its termination before
    /// returning; every later one fails (via failingPanes). That is the
    /// termination-races-the-return window with a deterministic aftermath:
    /// replacements exhaust, so a false publish by the original call is the
    /// only way the pane can ever read .open.
    private var succeedOnceThenKill: Set<String> = []
    func killDuringFirstSuccessfulOpen(_ pane: String) {
        lock.withLock { _ = succeedOnceThenKill.insert(pane) }
    }
    /// The pane's FIRST open throws; its SECOND open parks until released.
    /// Later opens pass through untouched.
    ///
    /// That pair IS the catch-path window and nothing else. While the second
    /// open (the policy's replacement, dialed from inside
    /// `handle(.streamFailed)`) sits suspended, the outer subscribe loop is
    /// parked in the middle of its catch — the one position from which a
    /// retirement is invisible to both the post-open reap and the backoff
    /// guard. Encoded as a single armed seam rather than composed from
    /// `failingPanes` + `stall`, because composing them cannot express
    /// "throw, THEN park" for one pane: the stall precedes the failure check,
    /// so a pre-set stall would park the first open instead of the retry and
    /// the window would never open.
    ///
    /// The throwing entry drops its registration, so live registrations and
    /// entered opens are DIFFERENT counts here — use `openEntryCount` for "how
    /// many opens happened" and `registrationCount` for "how many callbacks are
    /// live". Conflating them is what armed this window on a contract
    /// violation for a whole round.
    private var catchPathWindow: Set<String> = []
    private var openCounts: [String: Int] = [:]
    func armCatchPathWindow(_ pane: String) {
        lock.withLock { _ = catchPathWindow.insert(pane) }
    }
    /// 0 = not armed for this pane, 1 = the throwing first open, 2+ = a retry.
    private func catchPathPhase(_ pane: String) -> Int {
        lock.withLock {
            guard catchPathWindow.contains(pane) else { return 0 }
            openCounts[pane, default: 0] += 1
            return openCounts[pane] ?? 0
        }
    }

    /// How many times `openStream` has been ENTERED for this pane, counted
    /// independently of how many terminators are live.
    ///
    /// The two are not the same number and conflating them cost a whole round.
    /// `registrationCount` was serving as "how many opens have happened", which
    /// is only true if a throwing open leaves its registration behind — the
    /// exact thing `ExecutorTransport` forbids. So the precondition was reading
    /// evidence that existed only because the fake broke the contract under
    /// test: fix the fake and the count silently drops to 1 and the window
    /// never arms. Entry count answers the question directly and stays correct
    /// whether an open throws, stalls, or succeeds.
    private var openEntries: [String: Int] = [:]
    func openEntryCount(_ pane: String) -> Int { lock.withLock { openEntries[pane] ?? 0 } }

    /// Whether the pane's catch-window retry is CURRENTLY parked.
    ///
    /// Stronger than the entry count as a precondition, and the difference is a
    /// real race rather than a nicety: the entry count is incremented at the top
    /// of `openStream`, the gate is entered further down, and a test that
    /// observed the count could call `release` in between — releasing a gate
    /// nothing had entered yet. The open then parked forever and the test timed
    /// out having proven nothing (1 run in 5). Observing the gate itself cannot
    /// be early by construction.
    func retryIsParked(_ pane: String) -> Bool { lock.withLock { catchParkedEntry[pane] != nil } }

    /// The catch window's gate, private to it and keyed to one INVOCATION.
    /// Deliberately not `stalledPanes`: that set is keyed by pane and shared
    /// with every other stall seam, so a second attempt opening the same pane
    /// re-armed it under a test that had already released it.
    private var catchParkedEntry: [String: Int] = [:]
    private var catchReleased: Set<String> = []

    /// Drops the registration this call made, so a throwing open leaves none.
    /// Deliberately NOT applied on the `installsThenThrows` path: that one
    /// exists to break the contract on purpose.
    private func dropOwnRegistration(_ pane: String) {
        lock.withLock {
            guard var list = terminators[pane], !list.isEmpty else { return }
            list.removeLast()
            terminators[pane] = list
        }
    }
    private func isStalled(_ pane: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stalledPanes.contains(pane)
    }

    init(panes: [String]) { self.panesToServe = panes }

    func log() -> [Operation] { lock.lock(); defer { lock.unlock() }; return operations }
    private func record(_ op: Operation) { lock.withLock { operations.append(op) } }

    /// Kills a pane's stream from the outside, firing its termination exactly
    /// once — the contract the executor promises the policy.
    /// How many terminators are currently registered for a pane — an
    /// observable precondition, so a test can wait for the registration to
    /// EXIST rather than for a proxy that precedes it.
    func registrationCount(_ pane: String) -> Int {
        lock.withLock { terminators[pane]?.count ?? 0 }
    }

    /// Fires the NEWEST registration's termination. Returns whether one fired:
    /// a silent no-op kill made a death-race test pass by never racing.
    @discardableResult
    func killStream(_ pane: String) -> Bool {
        let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
            guard var list = terminators[pane], !list.isEmpty else { return nil }
            let last = list.removeLast()
            terminators[pane] = list
            return last
        }
        terminate?()
        return terminate != nil
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
        // Registered BEFORE the stall so a suspended open can be terminated
        // from outside — that is the reviewer's interleaving: the death is
        // processed while the call is still suspended, and the call then
        // returns and tries to publish.
        // Both the terminator registration AND the first-open claim happen
        // BEFORE the stall. Claiming after it made the slot stealable: a
        // replacement triggered by the death reached the check first, became
        // "the first open", and published legitimately — the test flaked 1 run
        // in 4 reporting .open for a reason that had nothing to do with the
        // guard under test.
        let laterOpen = lock.withLock { () -> Bool in
            openEntries[pane, default: 0] += 1
            terminators[pane, default: []].append(onTermination)
            guard onlyFirstOpenSucceeds else { return false }
            return !opensSeen.insert(pane).inserted
        }
        // NOT contract-abiding, and deliberately so — like `installsThenThrows`,
        // `onlyFirstOpenSucceeds` is a probe of what the executor does when a
        // conformer RETAINS a callback it promised to drop. The orphan IS the
        // observable in the false-open test; dropping it here made that test's
        // precondition read 0 registrations and the hazard vanish.
        if laterOpen { throw TransportError.closedBeforeResponse }
        // Armed catch-path window: entry 1 throws, entry 2 parks. EXACTLY entry
        // 2 — later entries pass straight through.
        //
        // Both the "exactly" and the private gate are corrections, not
        // tidiness. Stalling every entry >= 2 through the shared, pane-keyed
        // `stalledPanes` let the REPLACEMENT ATTEMPT re-arm the retired
        // attempt's gate: once B started, B's own open for the same pane
        // reinserted it after the test had released A, so both calls parked and
        // neither outcome ever appeared. The unmutated regression timed out
        // 1 run in 20, and worse, the guard-removal mutant reached that same
        // dead third outcome 1 in 11 — a mutant escaping into a timeout is
        // indistinguishable from a mutant that was killed, so the race
        // corrupted the mutation evidence, not just the test.
        let phase = catchPathPhase(pane)
        if phase == 1 {
            dropOwnRegistration(pane)      // the contract: a throwing open leaves nothing live
            throw TransportError.closedBeforeResponse
        }
        if phase == 2 {
            // Keyed to THIS invocation. No other call, on any attempt, can
            // enter or re-arm it.
            lock.withLock { catchParkedEntry[pane] = openEntries[pane] }
            while lock.withLock({ !catchReleased.contains(pane) }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            lock.withLock { catchParkedEntry[pane] = nil }
        }
        while isStalled(pane) { try? await Task.sleep(nanoseconds: 10_000_000) }
        record(.openAttempt(pane, attempt))
        let succeedThisOnce = lock.withLock { succeedOnceThenKill.remove(pane) != nil }
        if succeedThisOnce {
            record(.openStream(pane, attempt))
            // Fires INSIDE the call: the executor's publish runs after this.
            let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
                guard var list = terminators[pane], !list.isEmpty else { return nil }
                let last = list.removeLast()
                terminators[pane] = list
                return last
            }
            terminate?()
            return
        }
        if failOpens || lock.withLock({ failingPanes.contains(pane) }) {
            // The deliberate violation is RETAINING the entry registration, not
            // adding a second one. This used to append the identical closure
            // again, so each failed open left TWO retained callbacks while the
            // test and the doc comment both describe one — the probe was
            // exercising a hazard twice the size of the one it documents.
            if !installsThenThrows { dropOwnRegistration(pane) }
            throw TransportError.closedBeforeResponse
        }
        record(.openStream(pane, attempt))
        let fireNow = lock.withLock { killOnRegister.remove(pane) != nil }
        if fireNow {
            // Fire BEFORE returning: the executor's success path runs after
            // this, which is exactly the window under test.
            let terminate = lock.withLock { () -> (@Sendable () -> Void)? in
                guard var list = terminators[pane], !list.isEmpty else { return nil }
                let last = list.removeLast()
                terminators[pane] = list
                return last
            }
            terminate?()
        }
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
    /// A one-shot latch: fires once, and `wait()` suspends until it has. Both
    /// sides are safe to call in either order, which is the point — a signal
    /// that only works when fired second is a race dressed as a helper.
    final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var hasFired: Bool { lock.withLock { fired } }
        func fire() { lock.withLock { fired = true } }
        func wait() async {
            while !hasFired { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

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

        // Settle on the TRANSPORT LOG, which is what every assertion below
        // reads, rather than on the ledger. The ledger records a subscription
        // before the transport finishes opening it, so waiting on
        // subscribedPanes could return with only p1's openStream logged — the
        // final set assertion then failed about 1 run in 5. Same shape as the
        // precondition defects reviewed out of this file: the wait observed
        // something that PRECEDES what the assertion inspects.
        let settled = await waitUntil {
            Set(transport.log().compactMap { if case .openStream(let p, _) = $0 { return p }; return nil })
                == ["p1", "p2"]
        }
        XCTAssertTrue(settled, "the cold start never opened both streams")
        let ledger = await executor.subscribedPanes
        XCTAssertEqual(ledger, ["p1", "p2"],
                       "the ledger disagrees with the streams actually opened")

        let ops = transport.log()
        guard case .connect(let attempt) = ops.first else {
            return XCTFail("the first operation must be the dial, got \(ops)")
        }
        XCTAssertEqual(ops[1], .fetchSnapshot(attempt), "resync must be the first post-connect operation")
        let firstStream = ops.firstIndex { if case .openStream = $0 { return true }; return false }
        let snapshotIndex = try XCTUnwrap(ops.firstIndex(of: .fetchSnapshot(attempt)))
        XCTAssertGreaterThan(try XCTUnwrap(firstStream), snapshotIndex,
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
        let attemptBOptional = await executor.currentAttempt
        let attemptB = try XCTUnwrap(attemptBOptional)

        let ops = transport.log()
        let snapshotB = ops.firstIndex(of: .fetchSnapshot(attemptB))
        let firstStreamB = ops.firstIndex { if case .openStream(_, attemptB) = $0 { return true }; return false }
        XCTAssertGreaterThan(try XCTUnwrap(firstStreamB), try XCTUnwrap(snapshotB),
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
        let retiredOptional = await executor.currentAttempt
        let retired = try XCTUnwrap(retiredOptional)
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
        // XCTUnwrap, not `!`: removing transport.discard failed the assertion
        // above AND then crashed here with signal 4, which the harness reads as
        // INVALID rather than KILLED — a real kill misfiled as a broken run.
        let discardIndex = try XCTUnwrap(ops.firstIndex(of: .discard(retired)))
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
        let retiredOptional = await executor.currentAttempt
        let retired = try XCTUnwrap(retiredOptional)

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
        let attemptOptional = await executor.currentAttempt
        let attempt = try XCTUnwrap(attemptOptional)
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

        // Wait for the first pane's REGISTRATION, not fetchSnapshot: the fake
        // logs the snapshot before returning it and before the stalled stream
        // registers, so waiting on it let networkChanged retire A BEFORE the
        // loop began — the mutation removing the per-pane guard then built and
        // passed. Fourth instance in this file of a test observing something
        // that precedes the window it names.
        let inWindow = await waitUntil { transport.registrationCount("a-first") > 0 }
        XCTAssertTrue(inWindow, "the subscribe loop never entered its first open; the window was not exercised")
        let attemptAOptional = await executor.currentAttempt
        let attemptA = try XCTUnwrap(attemptAOptional)

        // While the loop is suspended on pane 1, the world moves.
        await executor.handle(.networkChanged(at: Date()))
        transport.release("a-first")

        // Give A's loop every chance to finish; B's own subscribes are for
        // attempt B and do not confound the assertion.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(transport.log().contains { $0 == .openStream("b-second", attemptA) },
                       "the loop opened a stream for a retired attempt after its closeAll")
    }

    /// AXIS: a retirement landing while the loop is parked in its CATCH — not
    /// its open — still stops the remaining panes.
    ///
    /// The sibling test above covers the success path, where the post-open reap
    /// catches the retirement on its way out. This one covers the path the reap
    /// never sees: the open THREW, so the catch awaits `handle(.streamFailed)`,
    /// the policy dials a replacement, and that replacement suspends. The outer
    /// loop is now parked at a suspension point that returns to the TOP OF THE
    /// NEXT ITERATION rather than through the reap.
    ///
    /// This is a review finding, not a hypothesis: round seven built this probe
    /// against a head where I had removed the guard covering it, and watched
    /// the loop open the second pane for an attempt that was already dead.
    func testARetirementDuringAFailedOpensHandlingStopsTheRemainingStreams() async throws {
        let transport = ScriptedTransport(panes: ["a-fails", "z-must-not-open"])
        let executor = RecoveryExecutor(transport: transport)
        transport.armCatchPathWindow("a-fails")   // open 1 throws, open 2 stalls
        await executor.start()

        // The window is ENTERED when the replacement open exists: entry 1 is the
        // throwing open, entry 2 is the retry the policy dialed from inside
        // handle(.streamFailed), and the retry stalls immediately after
        // entering. Two ENTRIES therefore prove the outer loop is parked in its
        // catch — the precondition the whole test rests on.
        //
        // Counted as entries, not live registrations. The first version waited
        // on registrationCount >= 2, which only reached 2 because the fake
        // registered a terminator and then threw — the one thing
        // ExecutorTransport forbids a throwing open to do. Making the fake obey
        // its own contract dropped that count to 1 and the window stopped
        // arming: the precondition had been reading an artifact of the
        // violation rather than the retry it named.
        let inWindow = await waitUntil { transport.retryIsParked("a-fails") }
        XCTAssertTrue(inWindow,
                      "the failed open never produced a replacement; the catch-path window never opened")
        XCTAssertGreaterThanOrEqual(transport.openEntryCount("a-fails"), 2,
                                    "parked without a second entry: the stall is not the retry's")
        // Two entries, exactly ONE live registration: the stalled retry's. The
        // throwing first open left nothing behind, which is the seam contract
        // holding — and asserting it here is what stops this precondition from
        // silently going back to counting orphans.
        XCTAssertEqual(transport.registrationCount("a-fails"), 1,
                       "expected only the stalled retry to hold a registration; the throwing open left an orphan")
        let attemptAOptional = await executor.currentAttempt
        let attemptA = try XCTUnwrap(attemptAOptional)

        // The world moves while the loop is parked mid-catch.
        await executor.handle(.networkChanged(at: Date()))
        transport.release("a-fails")

        // Settle on an OUTCOME, not on elapsed time. A fixed sleep let the
        // guard-removal mutant pass 1 run in 9: the negative assertion was
        // inspected before the faulty outer loop had resumed, so "no forbidden
        // open yet" and "no forbidden open ever" were indistinguishable. Wait
        // until one of the two mutually exclusive outcomes is observable.
        let forbidden: () -> Bool = { transport.log().contains { $0 == .openAttempt("z-must-not-open", attemptA) } }
        let settled = await waitUntil {
            if forbidden() { return true }
            return await executor.rejections.contains { $0.reason.contains("attempt retired while handling an open failure") }
        }
        XCTAssertTrue(settled, "neither outcome was reached; the test proved nothing either way")
        XCTAssertFalse(forbidden(),
                       "the loop resumed from its catch and opened a stream for a retired attempt")
    }

    /// AXIS: a retirement landing during a pane's RETRY BACKOFF stops the
    /// retry, rather than opening a channel for a dead attempt and reaping it.
    ///
    /// The third suspension point in the subscribe loop, and the last one with
    /// no test of its own. Its mutation SURVIVED when this test did not exist:
    /// the post-open reap makes deleting the guard harmless to correctness — an
    /// open bound to a retired attempt is still closed — so the surviving
    /// difference is one wasted channel open against a connection that is
    /// already being torn down. That is a real difference and it is observable,
    /// so it gets pinned rather than argued about. Removing the guard on the
    /// strength of "the reap covers it" is exactly the reasoning that failed
    /// review at round seven; the rule this file now follows is that a
    /// suspension point keeps its own guard AND its own test.
    func testARetirementDuringARetryBackoffStopsTheRetry() async throws {
        let transport = ScriptedTransport(panes: ["p"])
        let executor = RecoveryExecutor(transport: transport)
        transport.failingPanes = ["p"]           // every open throws -> a retry is dialed

        // Park the backoff instead of sleeping it: the retry's suspension has
        // to be held open long enough to retire the attempt underneath it, and
        // wall-clock timing cannot pin that without flaking.
        //
        // Installed BEFORE start(), and selective on the delay. Installing it
        // after start() raced the executor's own first backoff, which then ran
        // on the REAL sleeper and burned a retry before the seam existed — the
        // test saw 2 opens where it asserted 1, intermittently. Selective
        // because `dial` shares this seam: parking every call would park the
        // initial connect and nothing would ever happen. 0.25 is failures(1) *
        // 0.25, the first pane-retry backoff and the only delay under test.
        let parked = Signal()
        let release = Signal()
        await executor.setSleeper { delay in
            guard delay == 0.25 else {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return
            }
            parked.fire()
            await release.wait()
        }
        await executor.start()

        // Entering the backoff is the precondition, and it is observed rather
        // than assumed: it can only be reached after the first open threw and
        // the policy dialed a replacement for the same pane on the same
        // attempt, which is the exact state the guard exists for.
        let inBackoff = await waitUntil { parked.hasFired }
        XCTAssertTrue(inBackoff, "the retry never reached its backoff; the window was not exercised")
        let attemptAOptional = await executor.currentAttempt
        let attemptA = try XCTUnwrap(attemptAOptional)
        let opensBefore = transport.log().filter { $0 == .openAttempt("p", attemptA) }.count
        XCTAssertEqual(opensBefore, 1, "expected exactly the one failed open before the backoff")

        await executor.handle(.networkChanged(at: Date()))
        release.fire()

        // Same reasoning as the catch-path regression: settle on whichever
        // outcome occurs rather than on a fixed duration, so a slow resume
        // cannot be read as a passing guard.
        let opensFor: () -> Int = { transport.log().filter { $0 == .openAttempt("p", attemptA) }.count }
        let settled = await waitUntil {
            if opensFor() > 1 { return true }
            return await executor.rejections.contains { $0.reason.contains("attempt retired during retry backoff") }
        }
        XCTAssertTrue(settled, "neither outcome was reached; the test proved nothing either way")
        XCTAssertEqual(opensFor(), 1,
                       "the retry woke from its backoff and opened a channel for a retired attempt")
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
        let retiredOptional = await executor.currentAttempt
        let retired = try XCTUnwrap(retiredOptional)

        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.isConnected }
        let currentOptional = await executor.currentAttempt
        let current = try XCTUnwrap(currentOptional)
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
        let currentOptional = await executor.currentAttempt
        let current = try XCTUnwrap(currentOptional)
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
        let resourcedOptional = await executor.currentAttempt
        let resourced = try XCTUnwrap(resourcedOptional)

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
        let attemptOptional = await executor.currentAttempt
        let attempt = try XCTUnwrap(attemptOptional)

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
        let retiredOptional = await executor.currentAttempt
        let retired = try XCTUnwrap(retiredOptional)

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
        // EXACT, not <=: the <= form let the failures <= cap off-by-one mutant
        // survive the whole executor selection. The cap means exactly cap
        // failed registrations: cap attempts, cap-1 backoffs between them.
        XCTAssertEqual(backoffs.count, RecoveryExecutor.openFailureCap - 1,
                       "expected exactly \(RecoveryExecutor.openFailureCap - 1) backoffs, got \(backoffs.count)")
        let attempts = transport.log().filter { if case .openAttempt = $0 { return true }; return false }.count
        XCTAssertEqual(attempts, RecoveryExecutor.openFailureCap,
                       "expected exactly \(RecoveryExecutor.openFailureCap) registration attempts, got \(attempts)")

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
        XCTAssertEqual(attemptsAtCap, RecoveryExecutor.openFailureCap,
                       "expected exactly \(RecoveryExecutor.openFailureCap) registration attempts, got \(attemptsAtCap)")

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
        let retiredOptional = await executor.currentAttempt
        let retired = try XCTUnwrap(retiredOptional)
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

    /// AXIS: a retired attempt's delayed termination cannot flip a LIVE pane's
    /// status — the reviewer's probe: p1 open on B, A's stale termination
    /// arrives, and B's status fell to admittedNotOpen while its stream lived.
    func testAStaleTerminationCannotFlipALivePanesStatus() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.start()
        _ = await waitUntil { await executor.paneStatus("p1") == .open }

        // A's registration survives the teardown in the fake's registry (the
        // stale callback the wire can always deliver late); B re-opens p1.
        await executor.handle(.networkChanged(at: Date()))
        _ = await waitUntil { await executor.paneStatus("p1") == .open }

        // The OLDEST registration — A's — fires its termination late.
        transport.killOldestRegistration("p1")
        try? await Task.sleep(nanoseconds: 300_000_000)

        let status = await executor.paneStatus("p1")
        XCTAssertEqual(status, .open,
                       "a stale termination flipped a live pane to \(status)")
    }

    /// AXIS: a termination racing the open's suspension cannot yield a false
    /// .open — the reviewer's probe: replacements exhausted, then the
    /// terminated ORIGINAL call returned and published, and paneStatus lied
    /// .open forever after.
    func testATerminationDuringTheOpenCannotPublishAFalseOpen() async throws {
        let transport = ScriptedTransport(panes: ["p1"])
        let executor = RecoveryExecutor(transport: transport)
        await executor.setSleeper { _ in }
        transport.onlyFirstOpenSucceeds = true     // one live registration, no replacements
        transport.stall("p1")                      // the open suspends, terminator registered
        await executor.start()

        // Wait for the REGISTRATION, not a proxy: the reviewer showed that
        // waiting on fetchSnapshot lets killStream be a silent no-op, after
        // which releasing the stall publishes a legitimately live stream and
        // the test passes without ever racing anything.
        let registered = await waitUntil { transport.registrationCount("p1") > 0 }
        XCTAssertTrue(registered, "no terminator was ever registered; the race could not happen")

        // The stream dies while its open is STILL SUSPENDED.
        XCTAssertTrue(transport.killStream("p1"), "the death did not fire; the race did not happen")
        try? await Task.sleep(nanoseconds: 150_000_000)
        transport.release("p1")                    // the original call now returns
        try? await Task.sleep(nanoseconds: 400_000_000)

        // UNCONDITIONAL, and on the FULL status: a terminated registration must
        // neither publish .open nor erase why the pane is unopenable.
        let status = await executor.paneStatus("p1")
        guard case .admittedNotOpen(let attempts, let lastError) = status else {
            return XCTFail("a terminated registration published .open (status: \(status))")
        }
        XCTAssertEqual(attempts, RecoveryExecutor.openFailureCap,
                       "exhausted retry state was erased: attempts reported \(attempts)")
        XCTAssertNotNil(lastError, "the last error was erased with the retry state")

        // And a retained orphan callback must not restart registrations past the
        // cap. Observed through registrationCount, NOT the .openAttempt log:
        // with onlyFirstOpenSucceeds every replacement registers its terminator
        // and then throws BEFORE .openAttempt is recorded, so the log-equality
        // form stayed true even when restarts happened — the reviewer isolated
        // exactly that, seeing registrations grow 4 -> 9 while the shipped
        // assertion passed. Third time on this test family that the OBSERVABLE,
        // not the assertion, was what let a mutant through.
        let registrationsBefore = transport.registrationCount("p1")
        XCTAssertGreaterThan(registrationsBefore, 0, "precondition: registrations exist to observe")
        transport.killOldestRegistration("p1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let registrationsAfter = transport.registrationCount("p1")
        XCTAssertEqual(registrationsAfter, registrationsBefore - 1,
                       "expected exactly the killed callback to be consumed; \(registrationsBefore) -> \(registrationsAfter) means restarts past the exhausted cap")
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
