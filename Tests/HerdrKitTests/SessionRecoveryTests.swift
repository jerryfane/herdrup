import XCTest
@testable import HerdrKit

/// A generator that always yields the same bits, so `random(in:)` returns a
/// fixed fraction of its range. Jitter then cannot hide whether the RANGE grew,
/// which is what the growth test needs and what the previous one lacked.
private struct ConstantGenerator: RandomNumberGenerator {
    let bits: UInt64
    mutating func next() -> UInt64 { bits }
}

/// Deterministic generator, so a jitter test asserts a distribution property
/// rather than hoping.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class SessionRecoveryTests: XCTestCase {
    let recovery = SessionRecovery()

    private func plan(
        _ event: ClientEvent, _ state: inout SessionRecovery.State, seed: UInt64 = 1
    ) -> RecoveryPlan {
        var generator = SeededGenerator(seed: seed)
        return recovery.plan(for: event, state: &state, using: &generator)
    }

    private func panes(_ ids: [String]) throws -> [AgentInfo] {
        let entries = ids.map { "{\"pane_id\":\"\($0)\",\"agent\":\"claude\"}" }.joined(separator: ",")
        let json = "{\"id\":\"x\",\"result\":{\"agents\":[\(entries)]}}"
        return try JSONDecoder()
            .decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents
    }

    private func seeded(_ ids: [String]) throws -> SessionRecovery.State {
        var state = SessionRecovery.State()
        _ = recovery.observe(PaneSnapshot(agents: try panes(ids)), state: &state)
        return state
    }

    /// Opens an attempt the way production does, and hands back its identifier
    /// so a test can answer with the right one — or deliberately the wrong one.
    private func connect(
        _ state: inout SessionRecovery.State, at when: Date = Date()
    ) -> AttemptID {
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(opened, at: when), &state)
        return opened
    }

    /// AXIS: a second `connected` for the SAME adopted attempt is a no-op — no
    /// duplicate resync/subscribe, and the stability clock keeps the ORIGINAL
    /// establishment time.
    ///
    /// Reachable on real platforms: a connection can go ready -> waiting ->
    /// ready across a viability blip without failing, so nothing guarantees one
    /// connected per attempt. Before the fix the repeat re-emitted both actions
    /// and overwrote connectedSince — observed streak of 3 instead of 1 in the
    /// sweep's reproduction, because the restarted clock made an 11-second-old
    /// connection look 2 seconds old.
    func testRepeatConnectedForTheAdoptedAttemptIsANoOp() throws {
        var state = try seeded(["p1"])
        let start = Date()
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(opened, at: start), &state)

        let repeated = plan(.connected(opened, at: start.addingTimeInterval(3)), &state)
        XCTAssertTrue(repeated.isEmpty, "a repeat ready is news, not a new adoption")
        XCTAssertEqual(state.connectedSince, start, "the stability clock must keep the original time")

        // The stability consequence, concretely: a failure past the window
        // still clears the streak, because the clock was not restarted.
        _ = plan(.transportFailed(opened, at: start.addingTimeInterval(recovery.stabilityInterval + 1)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1, "the restarted clock would have inherited the streak")
    }

    /// AXIS: foregrounding cancels whatever transport exists BEFORE dialing.
    ///
    /// A foregrounded with a connection still live (the OS never suspended us,
    /// or no backgrounded was delivered) previously minted a replacement while
    /// the old transport stayed open and subscribed — and no later plan ever
    /// closed it: two sockets reading the same panes, forever.
    func testForegroundingWhileConnectedCancelsTheOldTransportFirst() throws {
        var state = try seeded(["p1"])
        let old = connect(&state)

        let resumed = plan(.foregrounded(at: Date()), &state)
        XCTAssertEqual(resumed.actions.first, .cancelTransport,
                       "the live transport must be torn down before a new one dials")
        XCTAssertNotNil(resumed.reconnectAttempt)

        // And the abandoned attempt's late callbacks are stale, both ways.
        XCTAssertEqual(plan(.connected(old, at: Date()), &state).actions, [.discardConnection])
        XCTAssertTrue(plan(.transportFailed(old, at: Date()), &state).isEmpty)
    }

    /// AXIS: beginInitialAttempt is safe to call mid-session — it cancels, and
    /// the stale connectedSince cannot leak subscribes to an abandoned transport.
    ///
    /// The observed composition: begin-while-connected left connectedSince set,
    /// so paneCreated emitted a subscribe for a transport the policy had just
    /// walked away from.
    func testBeginInitialAttemptWhileConnectedCancelsAndClearsAdoption() throws {
        var state = try seeded(["p1"])
        _ = connect(&state)

        let restarted = recovery.beginInitialAttempt(state: &state)
        XCTAssertEqual(restarted.actions.first, .cancelTransport)
        XCTAssertNil(state.connectedSince, "stale adoption state leaks subscribes to a dead transport")
        XCTAssertTrue(plan(.paneCreated("p9"), &state).isEmpty,
                      "no subscribe may target the transport that was just abandoned")
    }

    /// AXIS: beginInitialAttempt while backgrounded dials nothing, matching
    /// every other path's refusal to dial while suspended.
    ///
    /// This was the ONE mint that ignored backgrounding — which also made it
    /// the only route by which the since-removed redundant background guards
    /// were reachable at all.
    func testBeginInitialAttemptWhileBackgroundedDialsNothing() throws {
        var state = try seeded(["p1"])
        _ = plan(.backgrounded(at: Date()), &state)
        XCTAssertTrue(recovery.beginInitialAttempt(state: &state).isEmpty)

        let resumed = plan(.foregrounded(at: Date()), &state)
        XCTAssertNotNil(resumed.reconnectAttempt, "foregrounding must still dial")
    }

    /// AXIS: a pane that first appears in a post-reconnect snapshot gets a
    /// subscription NOW, not at the next reconnect.
    ///
    /// The sweep's reproduction: a pane created during a disconnection gap
    /// arrives via the snapshot (paneCreated never fires for it — the event
    /// stream was down). The old Void observe() recorded it, and it sat on the
    /// "re-subscribe list" unsubscribed for the whole session. Even the
    /// app-layer workaround was closed: paneCreated for it returned nothing,
    /// because the pane was already known.
    func testSnapshotGrowthWhileConnectedSubscribesTheAddedPanes() throws {
        var state = try seeded(["p1"])
        _ = connect(&state)

        let grown = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p3"])), state: &state)
        XCTAssertEqual(grown.subscribes, ["p3"], "exactly the added panes, not the whole set")

        // While disconnected the snapshot only records; the next adoption's
        // full-set subscribe covers it.
        var offline = try seeded(["p1"])
        let recorded = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p4"])), state: &offline)
        XCTAssertTrue(recorded.isEmpty, "no transport, nothing to subscribe on")
        let opened = recovery.beginInitialAttempt(state: &offline).reconnectAttempt!
        XCTAssertEqual(plan(.connected(opened, at: Date()), &offline).subscribes, ["p1", "p4"])
    }

    /// AXIS: the stability window measures EVENT time, not wall-clock time.
    ///
    /// Every prior test used event times near Date(), so `connectedSince =
    /// Date()` — ignoring the event's own timestamp — survived all of them.
    /// Replayed or delayed event delivery is exactly when the two diverge.
    func testStabilityWindowUsesEventTimeNotWallClock() throws {
        var state = try seeded(["p1"])
        // A pre-existing streak, because resetting a streak of ZERO is
        // invisible: the first version of this test started from zero and the
        // wall-clock mutation survived it — 0-reset-then-increment and
        // no-reset-then-increment both land on 1.
        let past = Date().addingTimeInterval(-100)
        let first = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(first, at: past), &state)
        let retry = plan(.transportFailed(first, at: past.addingTimeInterval(0.05)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1, "precondition: a flap on the books")

        // The second connection lasts 15s of EVENT time — past the window, so
        // the streak resets before the increment. Under the wall-clock bug the
        // interval computes as negative and the old streak is inherited.
        let second = retry.reconnectAttempt!
        _ = plan(.connected(second, at: past.addingTimeInterval(1)), &state)
        _ = plan(.transportFailed(
            second, at: past.addingTimeInterval(1 + recovery.stabilityInterval + 5)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1,
                       "a connection that lasted past the window in EVENT time must clear the streak; 2 means the clock was wall time")
    }

    /// THE AXIS for task 4: a client that missed events resyncs rather than
    /// continuing, and does it EXACTLY ONCE per recovery.
    ///
    /// The previous version asserted the plan for `foregrounded` alone, which
    /// pinned a pre-connect action rather than the completed sequence — and hid
    /// that `foregrounded` and `connected` each emitted a resync and a
    /// subscription set, so a client following both opened every persistent
    /// subscription twice.
    func testForegroundingThenConnectingResyncsAndSubscribesExactlyOnce() throws {
        var state = try seeded(["p1", "p2"])

        let backgrounded = plan(.backgrounded(at: Date()), &state)
        XCTAssertEqual(backgrounded.actions, [.cancelTransport], "the stale transport must be torn down first")

        // Short enough that "surely nothing was missed" is tempting — which is
        // exactly the reasoning this must not embody.
        let resumed = plan(.foregrounded(at: Date().addingTimeInterval(0.2)), &state)
        XCTAssertEqual(resumed.actions.first, .cancelTransport,
                       "whatever transport may exist is torn down before dialing")
        XCTAssertEqual(resumed.reconnectDelay, 0)
        XCTAssertFalse(resumed.contains(.resyncAllPanes), "no transport yet to resync on")
        XCTAssertNil(resumed.subscribes, "no transport yet to subscribe on")

        let attempt = resumed.reconnectAttempt!
        let connected = plan(.connected(attempt, at: Date().addingTimeInterval(0.3)), &state)
        XCTAssertEqual(connected.actions, [.resyncAllPanes, .subscribe(["p1", "p2"])],
                       "resync must precede subscription, and both happen once")

        let everything = backgrounded.actions + resumed.actions + connected.actions
        XCTAssertEqual(everything.filter { $0 == .resyncAllPanes }.count, 1,
                       "a recovery emitted more than one resync")
        XCTAssertEqual(everything.filter { if case .subscribe = $0 { return true }; return false }.count, 1,
                       "subscriptions are persistent; emitting them twice opens each pane twice")
    }

    /// AXIS: a connection completing after backgrounding is discarded — BY THE
    /// STALENESS GUARD, which is the one mechanism covering it.
    ///
    /// Backgrounding clears `currentAttempt`, so the late completion cannot
    /// match; a separate isForeground guard once sat behind that check and was
    /// unreachable — the sweep showed this test pinned the staleness path all
    /// along while its name credited the redundant guard.
    func testConnectionCompletingWhileBackgroundedIsDiscardedAsStale() throws {
        var state = try seeded(["p1"])
        _ = plan(.backgrounded(at: Date()), &state)

        let late = plan(.connected(AttemptID(value: 99), at: Date().addingTimeInterval(0.1)), &state)
        XCTAssertEqual(late.actions, [.discardConnection])
        XCTAssertFalse(late.contains(.resyncAllPanes), "no work may start on an unwanted connection")
        XCTAssertNil(late.subscribes, "no subscription may open on an unwanted connection")
    }

    /// AXIS: a network change mid-attempt yields EXACTLY ONE adoption, however
    /// the abandoned attempt's callbacks arrive afterwards.
    ///
    /// Ordering the actions did not fix this and could not: order governs steps
    /// within one plan, and this is about which *attempt* a callback belongs to.
    /// Attempt A is abandoned by the network change, but nothing stops it
    /// finishing — so `connected(A)` must be discarded, `connected(B)` adopted,
    /// and a late `transportFailed(A)` must not tear down the B already in use.
    func testStaleAttemptCallbacksNeitherAdoptNorTearDown() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!

        let changed = plan(.networkChanged(at: Date()), &state)
        let attemptB = changed.reconnectAttempt!
        XCTAssertNotEqual(attemptA, attemptB, "a new attempt must not reuse the abandoned identifier")

        // A finishes anyway.
        let lateA = plan(.connected(attemptA, at: Date()), &state)
        XCTAssertEqual(lateA.actions, [.discardConnection], "an abandoned attempt must not be adopted")

        let adoptedB = plan(.connected(attemptB, at: Date()), &state)
        XCTAssertEqual(adoptedB.actions, [.resyncAllPanes, .subscribe(["p1"])])

        // ...and then A reports its failure, after B is already in use.
        let failedA = plan(.transportFailed(attemptA, at: Date()), &state)
        XCTAssertTrue(failedA.isEmpty, "a stale failure must not schedule a reconnect")
        XCTAssertEqual(state.consecutiveFailures, 0, "a stale failure must not count against the backoff")
        XCTAssertNotNil(state.connectedSince, "a stale failure must not tear down the adopted connection")

        let everything = lateA.actions + adoptedB.actions + failedA.actions
        XCTAssertEqual(everything.filter { $0 == .resyncAllPanes }.count, 1,
                       "exactly one adoption may resync")
        XCTAssertEqual(everything.filter { if case .subscribe = $0 { return true }; return false }.count, 1,
                       "exactly one adoption may subscribe")
    }

    /// AXIS: no field on `State` can hold a resume position.
    ///
    /// The previous version of this test asserted that two identical values were
    /// equal. It pinned nothing — a mutation ADDING `State.rememberedSequence`
    /// compiled and passed it. A behavioural assertion cannot pin the ABSENCE of
    /// API, so this reflects over the surface instead and fails when it grows.
    func testRecoveryStateHasNoFieldThatCouldHoldAResumePosition() {
        let fields = Mirror(reflecting: SessionRecovery.State())
            .children.compactMap(\.label).sorted()
        // Updated once, deliberately, when attempt identity was added — and that
        // is the guard working. `currentAttempt` and `nextAttemptValue` identify
        // a LOCAL connection attempt, a counter this client mints and compares
        // only against itself. Neither is a server position: nothing puts them on
        // the wire, and no herdr API would accept one. The point of this list is
        // that a new field forces that judgement out loud instead of arriving
        // unexamined.
        XCTAssertEqual(
            fields,
            ["connectedSince", "consecutiveFailures", "currentAttempt",
             "isForeground", "knownPanes", "nextAttemptValue"],
            "SessionRecovery.State grew a field; if it can hold a stream position, resumption just became expressible"
        )
        // One level down too: State stores AttemptID, so a position smuggled
        // into AttemptID's fields would be invisible to the check above.
        let attemptFields = Mirror(reflecting: AttemptID(value: 0))
            .children.compactMap(\.label).sorted()
        XCTAssertEqual(attemptFields, ["value"],
                       "AttemptID grew a field; a stream position could hide inside State through it")
    }

    /// AXIS: the backoff RANGE grows exponentially until the cap, then stops.
    ///
    /// The previous version asserted only that each random draw was ≤ the cap.
    /// That is true of a schedule with no growth at all — the reviewer replaced
    /// the exponential ceiling with `maximumDelay` at every failure count and the
    /// test stayed green, so the implementation could lose exponential backoff
    /// while the axis it claimed remained "covered".
    ///
    /// Holding the generator constant makes each draw a fixed fraction of the
    /// range, so growth in the delays IS growth in the range.
    func testBackoffRangeGrowsExponentiallyThenHoldsAtTheCap() {
        var delays: [TimeInterval] = []
        for failures in 1...12 {
            var generator = ConstantGenerator(bits: UInt64.max / 2)
            delays.append(recovery.backoff(failures: failures, using: &generator))
        }

        // Doubling while below the cap.
        for index in 1..<delays.count where delays[index] < recovery.maximumDelay * 0.4 {
            XCTAssertEqual(
                delays[index], delays[index - 1] * 2, accuracy: delays[index] * 0.02,
                "delay \(index + 1) did not double: \(delays[index - 1]) -> \(delays[index])"
            )
        }
        // Growth actually happened, rather than every value sitting at the cap.
        XCTAssertGreaterThan(delays[3], delays[0], "the range never grew")
        XCTAssertLessThan(delays[0], recovery.maximumDelay * 0.1, "the first delay is already at the cap")
        // Constant once capped.
        XCTAssertEqual(delays[11], delays[10], accuracy: 0.001, "delays must stop growing at the cap")
        for delay in delays {
            XCTAssertLessThanOrEqual(delay, recovery.maximumDelay)
        }

        var generator = ConstantGenerator(bits: 0)
        XCTAssertEqual(recovery.backoff(failures: 0, using: &generator), 0, "no failures, no delay")
    }

    /// AXIS: the delay is actually jittered.
    ///
    /// Asserting only "delay ≤ cap" would pass on a fixed schedule, which is the
    /// lockstep reconnect storm jitter exists to prevent. So this asserts SPREAD.
    func testBackoffIsJitteredNotFixed() {
        var delays: Set<Double> = []
        for seed in UInt64(1)...40 {
            var generator = SeededGenerator(seed: seed)
            delays.insert(recovery.backoff(failures: 6, using: &generator))
        }
        XCTAssertGreaterThan(delays.count, 30,
                             "40 clients drew only \(delays.count) distinct delays; they would reconnect in lockstep")
        // Distinctness alone survives a 1ms jitter band, which is still a
        // lockstep storm to the server. The draws must SPREAD across the
        // window: at failure 6 the range is 0..<16s, so 40 draws confined to
        // less than half of it would mean the generator is not doing what
        // full jitter is for.
        let spread = delays.max()! - delays.min()!
        XCTAssertGreaterThan(spread, 8.0,
                             "40 draws span only \(spread)s of a 16s window; that is a band, not jitter")
    }

    /// AXIS: a connection that drops immediately does not reset the backoff.
    ///
    /// Resetting on *established* is the classic form of this bug: a server that
    /// accepts and instantly drops looks like a success every time, so the delay
    /// never grows. The connection has to LAST.
    func testFlappingConnectionDoesNotResetTheBackoff() {
        var state = SessionRecovery.State()
        let start = Date()
        var opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        for attempt in 0..<5 {
            let at = start.addingTimeInterval(Double(attempt) * 0.1)
            _ = plan(.connected(opened, at: at), &state)
            let failed = plan(.transportFailed(opened, at: at.addingTimeInterval(0.05)), &state, seed: 99)
            opened = failed.reconnectAttempt ?? opened
        }
        XCTAssertEqual(state.consecutiveFailures, 5,
                       "five flaps counted \(state.consecutiveFailures) failures; a short-lived connection must not count as healthy")
    }

    /// AXIS: a connection that survived the stability window DOES reset it.
    func testAHealthyConnectionResetsTheBackoff() {
        var state = SessionRecovery.State()
        let start = Date()
        let first = connect(&state, at: start)
        let retry = plan(.transportFailed(first, at: start.addingTimeInterval(0.05)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1)

        let recovered = start.addingTimeInterval(1)
        let second = retry.reconnectAttempt!
        _ = plan(.connected(second, at: recovered), &state)
        _ = plan(.transportFailed(second, at: recovered.addingTimeInterval(recovery.stabilityInterval + 1)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1,
                       "a connection that lasted past the stability window must clear the streak")
    }

    /// AXIS: a pane discovered while connected is subscribed immediately; one
    /// discovered while disconnected waits for the resync rather than opening a
    /// subscription on a transport that does not exist.
    func testPaneCreatedSubscribesOnlyWhenThereIsAConnection() throws {
        var state = try seeded([])
        XCTAssertTrue(plan(.paneCreated("p9"), &state).isEmpty, "no connection, nothing to subscribe on")
        XCTAssertTrue(state.knownPanes.contains("p9"), "but it must still be remembered")

        _ = connect(&state)
        XCTAssertEqual(plan(.paneCreated("p8"), &state).subscribes, ["p8"])
        XCTAssertTrue(plan(.paneCreated("p8"), &state).isEmpty, "a repeat must not re-subscribe")
    }

    /// AXIS: a pane learned about mid-session survives into the next resync.
    ///
    /// Without this it becomes unwatched after the next reconnect, and its
    /// silence is indistinguishable from having no output.
    func testPanesLearnedDuringASessionAreResubscribedAfterReconnect() throws {
        var state = try seeded(["p1"])
        _ = plan(.paneCreated("p2"), &state)
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertEqual(plan(.connected(opened, at: Date()), &state).subscribes, ["p1", "p2"],
                       "a pane discovered mid-session must be re-subscribed, not forgotten")
    }

    /// AXIS: a closed pane stops being re-subscribed, WITHOUT needing a wholesale
    /// replacement of the set.
    ///
    /// Removal used to require passing a fresh full listing, which is what made
    /// partial listings dangerous — there was no other way to drop one.
    func testClosedPanesAreDroppedIncrementally() throws {
        var state = try seeded(["p1", "p2"])
        _ = plan(.paneClosed("p2"), &state)
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertEqual(plan(.connected(opened, at: Date()), &state).subscribes, ["p1"])
    }

    /// AXIS: a snapshot replaces the pane set wholesale.
    ///
    /// Named for what it actually checks. It was called
    /// `testOnlyAnAuthoritativeSnapshotCanReplaceThePaneSet` and claimed to pin
    /// provenance — but making `PaneSnapshot.init` public survived it, because
    /// nothing here inspects who may construct one. That invariant is access
    /// control, and a behavioural test cannot see access control; it is pinned by
    /// `PaneSnapshotAccessTests` below instead.
    func testASnapshotReplacesThePaneSetWholesale() throws {
        var state = try seeded(["p1", "p2", "p3"])
        XCTAssertEqual(state.knownPanes, ["p1", "p2", "p3"])
        recovery.observe(PaneSnapshot(agents: try panes(["p1"])), state: &state)
        XCTAssertEqual(state.knownPanes, ["p1"], "an authoritative listing is still authoritative")
    }

    /// AXIS: a backgrounded client schedules no reconnect — including when the
    /// failing attempt was CURRENT until the backgrounding.
    ///
    /// The previous version fed a never-minted AttemptID(value: 1), so it only
    /// ever exercised an arbitrary-stale failure and could not notice if a
    /// current attempt's failure dialed while suspended.
    func testBackgroundedClientSchedulesNoReconnect() throws {
        var state = try seeded(["p1"])
        let current = connect(&state)
        _ = plan(.backgrounded(at: Date()), &state)

        XCTAssertNil(plan(.transportFailed(current, at: Date()), &state).reconnectDelay,
                     "the just-backgrounded attempt's failure must not dial")
        XCTAssertEqual(state.consecutiveFailures, 0,
                       "backgrounding made that failure stale; it is not a streak")
        XCTAssertNil(plan(.networkChanged(at: Date()), &state).reconnectDelay)

        let resumed = plan(.foregrounded(at: Date()), &state)
        XCTAssertEqual(resumed.reconnectDelay, 0, "returning must reconnect immediately")
        XCTAssertEqual(state.consecutiveFailures, 0, "time spent suspended is not a failure streak")
    }

    /// AXIS: a network change cancels the old transport BEFORE reconnecting, and
    /// does not back off.
    ///
    /// It is not a failure — it is a different network, and the old socket is
    /// bound to an address that may no longer exist. Leaving it open means
    /// discovering it by timeout, which is the slowest possible way.
    func testNetworkChangeCancelsThenReconnectsImmediately() throws {
        var state = try seeded(["p1"])
        let opened = connect(&state)
        _ = plan(.transportFailed(opened, at: Date().addingTimeInterval(0.01)), &state)
        XCTAssertEqual(state.consecutiveFailures, 1)

        let changed = plan(.networkChanged(at: Date()), &state)
        XCTAssertEqual(changed.actions.first, .cancelTransport,
                       "the dead transport must be cancelled before a new one opens")
        XCTAssertEqual(changed.reconnectDelay, 0, "a network change must not back off")
        XCTAssertEqual(state.consecutiveFailures, 0)
    }
}

/// The other half of the resync: `RefreshCoordinator` must actually forget.
final class ResyncInvalidationTests: XCTestCase {
    /// AXIS: after invalidateAll, the next plan FETCHES rather than skipping.
    ///
    /// Asserting the internal state was cleared would test the setter. What
    /// matters is the observable consequence: a pane whose counters have not
    /// moved must still be refetched, because the counters are exactly what
    /// cannot be trusted across a gap.
    func testInvalidationForcesAFetchEvenWhenCountersDidNotMove() throws {
        var coordinator = RefreshCoordinator()
        let json = """
        {"id":"x","result":{"agents":[{"pane_id":"p1","agent":"claude","state_change_seq":1092,\
        "turn_epoch":4,"composer":{"state":"idle"}}]}}
        """
        let agent = try JSONDecoder()
            .decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]

        let now = Date()
        _ = coordinator.plan(agents: [agent], focusedPane: "p1", now: now)
        coordinator.recordFetch(pane: "p1", generation: PaneGeneration(agent), at: now)

        // Nothing moved, and we are inside every interval: normally a skip.
        let quiet = coordinator.plan(agents: [agent], focusedPane: "p1", now: now.addingTimeInterval(0.01))
        XCTAssertEqual(quiet["p1"], .skip, "precondition: an unchanged pane skips, or this proves nothing")

        coordinator.invalidateAll()
        let afterResync = coordinator.plan(
            agents: [agent], focusedPane: "p1", now: now.addingTimeInterval(0.02)
        )
        XCTAssertEqual(
            afterResync["p1"], .fetch,
            "after a gap the pane must be refetched; identical counters are not evidence of no change"
        )
    }
}


/// Access control is the provenance guarantee, so it is checked against the
/// COMPILER'S OWN view of the module surface.
///
/// Two weaker versions preceded this. A behavioural test could not see access
/// control at all and passed with the initialiser made public. A textual scan
/// then caught that exact spelling and nothing else: `public` on the preceding
/// line, `package` instead of `public`, or an added `public init(paneIDs:)` all
/// compiled and all survived it — and the last two genuinely reopen the path
/// this type exists to close.
///
/// `swift symbolgraph-extract` reports what is actually visible outside the
/// module, so formatting, access-level spelling and additional initialisers are
/// all covered by construction rather than by enumeration.
final class PaneSnapshotAccessTests: XCTestCase {
    func testPaneSnapshotExposesNoInitialiserOutsideTheModule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")

        // The triple is the directory name, so this does not hardcode a platform.
        let modules = try FileManager.default
            .contentsOfDirectory(atPath: build.path)
            .map { build.appendingPathComponent($0).appendingPathComponent("debug/Modules") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("HerdrKit.swiftmodule").path) }
        let moduleDir = try XCTUnwrap(
            modules, "no built HerdrKit.swiftmodule; the access invariant went UNCHECKED"
        )
        let triple = moduleDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

        // A FRESH directory per run, removed afterwards. The first version wrote
        // to a persistent per-triple directory and ignored the process exit
        // status, so a FAILED extraction quietly reused the previous run's graph
        // and passed — the reviewer reproduced it by breaking the subcommand.
        // Stale evidence is worse than no evidence: it looks identical to fresh.
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdrkit-symbolgraph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let swift = ["/opt/swift/usr/bin/swift", "/usr/bin/swift"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(
            swift, "no swift toolchain found; the access invariant went UNCHECKED"
        ))
        process.arguments = [
            "symbolgraph-extract", "-module-name", "HerdrKit", "-target", triple,
            "-I", moduleDir.path,
            "-I", root.appendingPathComponent("Sources/CSSH").path,
            "-output-dir", output.path, "-minimum-access-level", "package",
        ]
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stderrText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<none>"
        guard process.terminationStatus == 0 else {
            return XCTFail(
                "symbolgraph-extract exited \(process.terminationStatus); the access invariant "
                + "went UNCHECKED. stderr: \(stderrText)")
        }

        let graph = output.appendingPathComponent("HerdrKit.symbols.json")
        guard let data = try? Data(contentsOf: graph) else {
            return XCTFail("extraction exited 0 but produced no graph; the access invariant went UNCHECKED")
        }
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let symbols = try XCTUnwrap(decoded?["symbols"] as? [[String: Any]])

        // Sanity: the extraction has to have seen the type, or an empty result
        // would look like a pass.
        let snapshotSymbols = symbols.filter {
            (($0["pathComponents"] as? [String])?.first) == "PaneSnapshot"
        }
        XCTAssertFalse(snapshotSymbols.isEmpty, "PaneSnapshot is not in the surface at all; wrong module or stale build")

        // The WHOLE surface, not just initialisers. The init-only version let a
        // `public static func make(...) -> PaneSnapshot` reopen outside-module
        // construction without failing anything — construction is what the type
        // forbids, and a factory constructs. Whitelisting every symbol means any
        // new member at package access or above must be judged here, out loud.
        let surface = snapshotSymbols.compactMap { symbol -> String? in
            guard let kind = (symbol["kind"] as? [String: Any])?["identifier"] as? String,
                  let path = symbol["pathComponents"] as? [String] else { return nil }
            return "\(kind) \(path.joined(separator: "."))"
        }.sorted()
        XCTAssertEqual(
            surface,
            ["swift.func.op PaneSnapshot.!=(_:_:)",
             "swift.property PaneSnapshot.paneIDs",
             "swift.struct PaneSnapshot"],
            "PaneSnapshot's package-visible surface changed; anything that can CONSTRUCT one from caller data reopens the filtered-list path observe() exists to close"
        )
    }
}
