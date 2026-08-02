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
struct SeededGenerator: RandomNumberGenerator {
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

    /// Lock-protected result carrier: the compiler cannot verify a captured
    /// mutable local across threads, and under strict concurrency the pattern
    /// is a build error even when an NSLock makes it operationally sound.
    final class PlanBox: @unchecked Sendable {
        private let lock = NSLock()
        private var plan: RecoveryPlan?
        func set(_ value: RecoveryPlan) { lock.lock(); plan = value; lock.unlock() }
        func snapshot() -> RecoveryPlan? { lock.lock(); defer { lock.unlock() }; return plan }
    }

    static func decodePanes(_ ids: [String]) throws -> [AgentInfo] {
        let entries = ids.map { "{\"pane_id\":\"\($0)\",\"agent\":\"claude\"}" }.joined(separator: ",")
        let json = "{\"id\":\"x\",\"result\":{\"agents\":[\(entries)]}}"
        return try JSONDecoder()
            .decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents
    }

    private func panes(_ ids: [String]) throws -> [AgentInfo] {
        let entries = ids.map { "{\"pane_id\":\"\($0)\",\"agent\":\"claude\"}" }.joined(separator: ",")
        let json = "{\"id\":\"x\",\"result\":{\"agents\":[\(entries)]}}"
        return try JSONDecoder()
            .decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents
    }

    private func seeded(_ ids: [String]) throws -> SessionRecovery.State {
        // Planted directly: in production knowledge arrives via a transport's
        // snapshot (observe now REQUIRES provenance), but a test legitimately
        // starts with knowledge already held. knownPanes is informational, so
        // direct planting cannot leak into subscriptions.
        var state = SessionRecovery.State()
        state.knownPanes = Set(ids)
        _ = try panes(ids)   // keep the fixture honest about decodability
        return state
    }

    /// Opens an attempt the way production does, and hands back its identifier
    /// so a test can answer with the right one — or deliberately the wrong one.
    /// Mimics the executor's adoption flow: connect, then feed the
    /// authoritative snapshot (here: current knownPanes as the server's answer)
    /// through observe — which is where subscriptions come from now.
    private func connect(
        _ state: inout SessionRecovery.State, at when: Date = Date()
    ) -> AttemptID {
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(opened, at: when), &state)
        _ = recovery.observe(
            PaneSnapshot(agents: try! panes(Array(state.knownPanes))), from: opened, state: &state)
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

        // FROM THE MINTED ATTEMPT, NAMED — not read back out of the state.
        // `state.currentAttempt` forwards to `authority.current`, so reading it
        // here silently retargets the test to whatever the transition left
        // current. Binding it makes the premise a claim that can fail.
        let minted = try XCTUnwrap(restarted.reconnectAttempt)
        XCTAssertEqual(state.currentAttempt, minted,
                       "the restart did not become current; the event below is not from the attempt under test")
        XCTAssertTrue(plan(.paneCreated("p9", from: minted), &state).isEmpty,
                      "an event from the CURRENT attempt, before its adoption is processed, admits nothing "
                      + "— it needs nothing, because the post-adoption snapshot covers it via observe. "
                      + "(This does NOT pin the abandoned-attempt path: `minted` IS current here, so "
                      + "provenance passes and the cleared connectedSince is what rejects. The stale-attempt "
                      + "path is pinned by testALatePaneEventFromAnAbandonedAttemptActsOnNothing.)")

        // POSITIVE CONTROL. It establishes CAUSATION and nothing more, and the
        // difference matters enough to write down.
        //
        // What it fixes: `.isEmpty` on its own is consistent with the event
        // being inert for any reason at all. Adopting `minted` supplies the one
        // missing condition and nothing else, so a subscribe appearing here
        // proves the emptiness above was caused by the cleared adoption.
        // Deleting the adoption below leaves no subscribe: KILLED, so this
        // control is armed and adoption is its premise.
        //
        // What it does NOT fix, measured after adding it rather than assumed:
        // substituting a stranger AttemptID for `minted` in the assertion ABOVE
        // still SURVIVES. Provenance rejects a stranger to the identical
        // observable, and the control below reads `minted` independently, so
        // nothing binds the two lines to one attempt. The negative line is
        // therefore not attempt-discriminating; attempt discrimination is
        // pinned by testALatePaneEventFromAnAbandonedAttemptActsOnNothing.
        _ = plan(.connected(minted, at: Date()), &state)
        XCTAssertEqual(plan(.paneCreated("p9", from: minted), &state).subscribes, ["p9"],
                       "the same event still admits nothing after adoption; the emptiness above was "
                       + "never attributable to the cleared adoption")
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
        let opened = connect(&state)

        let grown = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p3"])), from: opened, state: &state)
        XCTAssertEqual(grown.subscribes, ["p3"], "exactly the added panes, not the whole set")

        // A snapshot from an attempt that is no longer current is ignored
        // WHOLLY — no subscriptions and no knowledge mutation. Disconnected
        // discovery has no other path: snapshots only arrive over transports.
        var offline = try seeded(["p1"])
        let stale = recovery.beginInitialAttempt(state: &offline).reconnectAttempt!
        // CONNECT IT FIRST. Without this the attempt is current-but-unconnected,
        // which rejects snapshots for a DIFFERENT reason — so deleting the
        // networkChanged below left the test green and it pinned the connection
        // gate rather than abandonment.
        XCTAssertEqual(plan(.connected(stale, at: Date()), &offline).actions,
                       [.resyncAllPanes(stale)],
                       "the attempt never adopted; the abandonment below is not the gate under test")
        _ = plan(.networkChanged(at: Date()), &offline)   // stale is abandoned
        XCTAssertNotEqual(offline.currentAttempt, stale, "the attempt was not abandoned")
        let ignored = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p4"])), from: stale, state: &offline)
        XCTAssertTrue(ignored.isEmpty, "an abandoned attempt's snapshot must admit nothing")
        XCTAssertEqual(offline.knownPanes, ["p1"], "nor may it mutate knowledge")

        // The CURRENT attempt's snapshot supplies both knowledge and subscriptions.
        let fresh = recovery.beginInitialAttempt(state: &offline).reconnectAttempt!
        XCTAssertEqual(plan(.connected(fresh, at: Date()), &offline).actions, [.resyncAllPanes(fresh)])
        let resub = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p4"])), from: fresh, state: &offline)
        XCTAssertEqual(resub.subscribes, ["p1", "p4"])
    }

    /// AXIS: a callback minted before a State replacement can never be adopted
    /// by the replacement.
    ///
    /// A bare counter restarted at 1 in a fresh State, so the DISCARDED state's
    /// first attempt matched the new state's first attempt and a late connected
    /// was adopted — defeating the stale-callback protection at the exact
    /// moment (a caller rebuilding state) it was needed. Identity now carries a
    /// per-State random epoch.
    func testCallbacksFromAReplacedStateAreStale() throws {
        var state = try seeded(["p1"])
        let preReplacement = recovery.beginInitialAttempt(state: &state).reconnectAttempt!

        // A MARKER THAT CROSSES THE ASSIGNMENT. Deleting the rebuild left this
        // green: both attempts are minted from the same lineage either way and
        // the identities still differ, so "not equal" proved nothing about
        // replacement. knownPanes is value-stored, so it travels with the
        // rebuilt State and distinguishes it from the original.
        state = try seeded(["p1", "replacement-marker"])   // the caller rebuilds their state
        XCTAssertTrue(state.knownPanes.contains("replacement-marker"),
                      "the state was never replaced; every assertion below is about the original")
        let postReplacement = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertNotEqual(preReplacement, postReplacement,
                          "a rebuilt State reminted an identical attempt identity")

        let late = plan(.connected(preReplacement, at: Date()), &state)
        XCTAssertEqual(late.actions, [.discardConnection],
                       "a callback from the discarded state was adopted as current")
    }

    /// AXIS: restoring a SAVED COPY of State and minting again cannot
    /// reproduce a previously minted identity.
    ///
    /// The epoch design survived a rebuilt State and fell to this: State is a
    /// value, so save -> mint A -> restore the save -> mint replays the same
    /// (epoch, counter) and A's late callback impersonated the current
    /// attempt. Identity is now a per-mint UUID derived from nothing State
    /// stores, so no replay of stored contents can reproduce it.
    func testMintingAfterASavedCopyRestoreCannotReproduceAnIdentity() throws {
        var state = try seeded(["p1"])
        let saved = state
        // MARK THE LIVE STATE so the restore below is observable. Deleting
        // `state = saved` left these tests green: the authority is shared by
        // reference, so the assertions held whether or not the value copy was
        // ever restored — they pinned the reference behaviour and said nothing
        // about replay, which is the entire subject. knownPanes is
        // value-stored, so it travels with the copy and distinguishes them.
        state.knownPanes.insert("live-marker-1")
        let minted = recovery.beginInitialAttempt(state: &state).reconnectAttempt!

        state = saved   // the replay
        XCTAssertFalse(state.knownPanes.contains("live-marker-1"),
                       "the saved copy was never restored; this test is not about replay")
        let reminted = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertNotEqual(minted, reminted,
                          "a saved-copy restore reproduced a previously minted identity")

        let late = plan(.connected(minted, at: Date()), &state)
        XCTAssertEqual(late.actions, [.discardConnection],
                       "the pre-restore attempt's callback was adopted as current")
    }

    /// AXIS: restoring a copied State cannot REAUTHORIZE a cancelled attempt.
    ///
    /// The reviewer's public-API probe, now the regression: mint A, copy State
    /// while A is current, networkChanged (cancels A, mints B), restore the
    /// copy, deliver connected(A) — and A was adopted, resync and subscriptions
    /// emitted for a transport the policy had cancelled. Fresh-UUID minting
    /// could not stop it because the AUTHORITY itself lived in replayable value
    /// contents. It now lives in a reference shared by every copy of the
    /// lineage: restoring the copy restores bookkeeping, but the shared
    /// authority still says B.
    func testRestoringACopiedStateCannotReauthorizeACancelledAttempt() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        let saved = state                      // A is current in this copy
        // MARK THE LIVE STATE so the restore below is observable. Deleting
        // `state = saved` left these tests green: the authority is shared by
        // reference, so the assertions held whether or not the value copy was
        // ever restored — they pinned the reference behaviour and said nothing
        // about replay, which is the entire subject. knownPanes is
        // value-stored, so it travels with the copy and distinguishes them.
        state.knownPanes.insert("live-marker-2")

        let changed = plan(.networkChanged(at: Date()), &state)   // cancels A, mints B
        let attemptB = changed.reconnectAttempt!

        state = saved                          // the replay
        XCTAssertFalse(state.knownPanes.contains("live-marker-2"),
                       "the saved copy was never restored; this test is not about replay")
        let lateA = plan(.connected(attemptA, at: Date()), &state)
        XCTAssertEqual(lateA.actions, [.discardConnection],
                       "a cancelled attempt was reauthorized by value restoration")

        let adoptedB = plan(.connected(attemptB, at: Date()), &state)
        XCTAssertEqual(adoptedB.actions, [.resyncAllPanes(attemptB)],
                       "the lineage's real current attempt must still adopt")
    }

    /// AXIS: a copy saved AFTER A connected cannot poison B's lifecycle.
    ///
    /// The reviewer's fifth replay probe, now the regression. Their previous
    /// probe copied State before A connected, so its bookkeeping was empty and
    /// could not expose this: a copy saved WHILE CONNECTED replayed
    /// connectedSince, so paneCreated subscribed onto the cancelled transport
    /// (isConnected read the replayed date) and connected(B) was classified as
    /// an already-adopted repeat and suppressed entirely. Connection and
    /// subscription state now live in the shared authority, and every
    /// attempt-changing transition clears them in the same critical section —
    /// that clearing, not a tag, is the mechanism (an earlier tag was an
    /// unreachable twin guard and was removed).
    func testACopySavedWhileConnectedCannotPoisonTheReplacementAttempt() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptA, at: Date()), &state)
        let saved = state                       // connected bookkeeping aboard
        // MARK THE LIVE STATE so the restore below is observable. Deleting
        // `state = saved` left these tests green: the authority is shared by
        // reference, so the assertions held whether or not the value copy was
        // ever restored — they pinned the reference behaviour and said nothing
        // about replay, which is the entire subject. knownPanes is
        // value-stored, so it travels with the copy and distinguishes them.
        state.knownPanes.insert("live-marker-3")

        let changed = plan(.networkChanged(at: Date()), &state)   // cancels A, mints B
        let attemptB = changed.reconnectAttempt!

        state = saved                           // the replay
        XCTAssertFalse(state.knownPanes.contains("live-marker-3"),
                       "the saved copy was never restored; this test is not about replay")

        // NOT the cancelled transport — B, which is current but NOT YET ADOPTED.
        // connectedSince is not value-stored (State.connectedSince forwards to
        // authority.connectedSince), so `state = saved` cannot replay it into
        // the gate at all, and currentAttempt likewise resolves to B, not A.
        // The old message here claimed a replayed connectedSince subscribing
        // onto a cancelled transport: neither half is reachable by this route.
        XCTAssertEqual(state.currentAttempt, attemptB,
                       "the restore retargeted currentAttempt; the event below is not from B")
        XCTAssertTrue(plan(.paneCreated("p9", from: attemptB), &state).isEmpty,
                      "an event from B before B's adoption is processed admits nothing")
        // MEASURED LIMITATION, stated rather than implied: substituting a
        // stranger AttemptID for `attemptB` here leaves this assertion true
        // (SURVIVED), because provenance rejects a stranger to the same
        // observable. So this line pins "nothing leaks before adoption" and
        // does NOT discriminate which attempt was refused. A positive control
        // of the kind used in
        // testBeginInitialAttemptWhileConnectedCancelsAndClearsAdoption does
        // not fit here without consuming p9's freshness and gutting the
        // mid-replay-learning assertion at the end of this test, which is the
        // stronger check. Attempt discrimination is pinned by
        // testALatePaneEventFromAnAbandonedAttemptActsOnNothing.

        // And B's adoption must not be suppressed as a repeat.
        let adoptedB = plan(.connected(attemptB, at: Date()), &state)
        XCTAssertEqual(adoptedB.actions, [.resyncAllPanes(attemptB)],
                       "the replayed connectedSince classified B's adoption as a repeat and suppressed it")
        let subscribed = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p9"])), from: attemptB, state: &state)
        XCTAssertEqual(subscribed.subscribes, ["p1", "p9"],
                       "B subscribes what the authoritative snapshot says, including the pane learned mid-replay")
    }

    /// AXIS: a pane forgotten by a snapshot shrink and later rediscovered is
    /// NOT subscribed a second time on the same transport.
    ///
    /// There is no unsubscribe verb on the wire — a subscription ends when its
    /// connection does — so the shrink leaves the first subscription open, and
    /// the rediscovery previously stacked a second one on top of it.
    func testAPaneReappearingAfterASnapshotShrinkIsNotDoubleSubscribed() throws {
        var state = try seeded(["p1", "p2"])
        let opened = connect(&state)   // subscribes {p1, p2}

        // The snapshot forgets p2; its subscription on this transport stays open.
        XCTAssertTrue(recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: opened, state: &state).isEmpty)

        // THE SHRINK MUST HAVE HAPPENED. Without this the test passed with the
        // shrink deleted entirely: p2 begins subscribed, so both rediscovery
        // operations below return empty whether or not it ever left. The
        // divergence between the two sets IS the state under test — forgotten
        // in knowledge, still subscribed on the wire — and asserting it is what
        // makes the emptiness below mean "not re-subscribed" rather than
        // "nothing changed".
        XCTAssertFalse(state.knownPanes.contains("p2"), "the snapshot did not shrink")
        XCTAssertTrue(state.subscribedPanes.contains("p2"),
                      "the shrink dropped the subscription; there is no unsubscribe verb")

        // p2 reappears — via event and via snapshot. Neither may re-subscribe.
        XCTAssertTrue(plan(.paneCreated("p2", from: opened), &state).isEmpty,
                      "paneCreated re-subscribed a pane this transport already watches")
        XCTAssertTrue(recovery.observe(PaneSnapshot(agents: try panes(["p1", "p2"])), from: opened, state: &state).isEmpty,
                      "observe re-subscribed a pane this transport already watches")

        // A NEW transport starts from nothing: the snapshot re-subscribes the set.
        _ = plan(.networkChanged(at: Date()), &state)
        let readopted = recovery.beginInitialAttempt(state: &state).reconnectAttempt
            ?? state.currentAttempt!
        XCTAssertEqual(plan(.connected(readopted, at: Date()), &state).actions, [.resyncAllPanes(readopted)])
        let resub = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p2"])), from: readopted, state: &state)
        XCTAssertEqual(resub.subscribes, ["p1", "p2"],
                       "the replacement transport subscribes the authoritative set")
    }

    /// AXIS: replayed pane knowledge can never subscribe a replacement
    /// transport to a closed pane.
    ///
    /// The reviewer's sixth probe, and the one that finished the decision-input
    /// inventory: start with p1/p2, save State, paneClosed(p2), networkChanged
    /// to B, restore the copy, connected(B). Adoption used to subscribe the
    /// REMEMBERED set — {p1, p2} — seeding the ledger with a pane the server
    /// had closed, and no later snapshot could retract it (the wire has no
    /// unsubscribe). Adoption now emits resync only; subscriptions derive from
    /// the post-adoption authoritative snapshot, so nothing after adoption may
    /// target p2.
    func testReplayedKnowledgeCannotSubscribeAClosedPane() throws {
        var state = try seeded(["p1", "p2"])
        let opened = connect(&state)
        // p2 MUST BE IN THE SAVED COPY, or "replayed knowledge cannot subscribe
        // it" is true because there was nothing to replay. The test passed both
        // with the close deleted AND with p2 never present: the authoritative
        // ["p1"] snapshot at the end supplies the closed-pane state on its own.
        XCTAssertTrue(state.knownPanes.contains("p2"),
                      "p2 is not in the state being saved; the replay has nothing to carry")
        let saved = state
        // MARK THE LIVE STATE so the restore below is observable. Deleting
        // `state = saved` left these tests green: the authority is shared by
        // reference, so the assertions held whether or not the value copy was
        // ever restored — they pinned the reference behaviour and said nothing
        // about replay, which is the entire subject. knownPanes is
        // value-stored, so it travels with the copy and distinguishes them.
        state.knownPanes.insert("live-marker-4")

        _ = plan(.paneClosed("p2", from: opened), &state)
        XCTAssertFalse(state.knownPanes.contains("p2"),
                       "the close did not take effect; the replay below carries a pane the "
                       + "live state never dropped, so nothing distinguishes replay from truth")
        let changed = plan(.networkChanged(at: Date()), &state)
        let attemptB = changed.reconnectAttempt!

        state = saved                           // the replay: memory says p2 exists
        XCTAssertFalse(state.knownPanes.contains("live-marker-4"),
                       "the saved copy was never restored; this test is not about replay")

        let adopted = plan(.connected(attemptB, at: Date()), &state)
        XCTAssertEqual(adopted.actions, [.resyncAllPanes(attemptB)],
                       "adoption must not convert remembered panes into subscriptions")

        // The authoritative snapshot — the server knows p2 is gone.
        let subscribed = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptB, state: &state)
        XCTAssertEqual(subscribed.subscribes, ["p1"])

        // Nothing anywhere targeted p2, and the ledger never held it.
        for action in adopted.actions + subscribed.actions {
            if case .subscribe(let panes, _) = action {
                XCTAssertFalse(panes.contains("p2"), "a closed pane was subscribed onto the fresh transport")
            }
        }
        XCTAssertFalse(state.subscribedPanes.contains("p2"),
                       "the ledger recorded a subscription to a closed pane — irretractable on this wire")
    }

    /// AXIS: a single pane's stream dying re-subscribes exactly that pane,
    /// exactly once — and only for the attempt that lost it.
    ///
    /// Requirement one of task 6: the wire is N independent per-pane
    /// connections, and one dying was previously inexpressible — the pane went
    /// silent while the client believed itself connected.
    func testAStreamFailureResubscribesThatPaneExactlyOnce() throws {
        var state = try seeded(["p1", "p2"])
        let opened = connect(&state)

        let replaced = plan(.streamFailed(pane: "p2", from: opened), &state)
        XCTAssertEqual(replaced.subscribes, ["p2"], "exactly the dead pane")
        XCTAssertEqual(replaced.subscribesOn, opened, "bound to the attempt that lost it")
        XCTAssertTrue(state.subscribedPanes.contains("p2"), "the ledger reflects the replacement")

        // The semantics are once PER DEATH, not once per pane: the ledger
        // entry now represents the REPLACEMENT stream, so a second failure
        // event legitimately replaces the replacement. Deduplicating spurious
        // duplicates for one death is the EXECUTOR's contract — it mints one
        // streamFailed per stream termination — and the policy must not absorb
        // that job, or a real second death would be swallowed.
        let second = plan(.streamFailed(pane: "p2", from: opened), &state)
        XCTAssertEqual(second.subscribes, ["p2"],
                       "a second death is a real death; the policy must replace again")
    }

    /// AXIS: stream-failure events that cannot be acted on emit nothing and
    /// touch nothing — a stale attempt's, an unsubscribed pane's, and a
    /// closed pane's.
    func testStreamFailuresThatCannotBeActedOnAreInert() throws {
        var state = try seeded(["p1"])
        let opened = connect(&state)

        // INERT MEANS "NOTHING ACTED ON", NOT "NOTHING RETURNED". These three
        // asserted `.isEmpty`, which is an outcome-shaped claim: it could not
        // distinguish an inert plan from an event that never reached the
        // policy. The plan now carries a `noteIgnoredDeath` marker precisely so
        // that difference is observable, so each case asserts BOTH — no acting
        // action, and the path ran.
        func inert(_ plan: RecoveryPlan, _ what: String) {
            XCTAssertFalse(plan.actions.contains { action in
                if case .noteIgnoredDeath = action { return false }
                return true
            }, "\(what): the plan acted")
            XCTAssertTrue(plan.actions.contains { action in
                if case .noteIgnoredDeath = action { return true }
                return false
            }, "\(what): the death was never processed; inertness proves nothing")
        }

        // Stale attempt: not even a drop.
        let foreign = AttemptID(uuid: UUID())
        inert(plan(.streamFailed(pane: "p1", from: foreign), &state), "stale attempt")
        XCTAssertTrue(state.subscribedPanes.contains("p1"), "a stale failure must not drop a live entry")

        // A pane with no ledger entry: no stream existed to die.
        inert(plan(.streamFailed(pane: "never-subscribed", from: opened), &state), "unknown pane")

        // A pane closed before its stream death arrives: dropped, not replaced.
        _ = plan(.paneClosed("p1", from: opened), &state)
        let afterClose = plan(.streamFailed(pane: "p1", from: opened), &state)
        inert(afterClose, "closed pane")
        XCTAssertFalse(state.subscribedPanes.contains("p1"), "the dead entry is dropped")
    }

    /// AXIS: a subscription action is bound to the attempt that admitted it —
    /// A's delayed plan can never be mistaken for B's.
    ///
    /// The reviewer's eighth probe closed the OUTPUT side of the asynchronous
    /// boundary: input data carried provenance, but the emitted subscribe
    /// discarded it after admission, so A's subscribe({p1}) compared EQUAL to
    /// B's and an executor holding A's delayed plan could apply it to B.
    func testASubscriptionActionIsBoundToItsAttempt() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptA, at: Date()), &state)
        let plansA = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptA, state: &state)
        XCTAssertEqual(plansA.subscribesOn, attemptA)

        _ = plan(.networkChanged(at: Date()), &state)   // retires A
        let attemptB = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptB, at: Date()), &state)
        let plansB = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptB, state: &state)
        XCTAssertEqual(plansB.subscribes, ["p1"], "B's own subscription executes once")
        XCTAssertEqual(plansB.subscribesOn, attemptB)

        // The two plans name the same panes and MUST NOT compare equal: the
        // binding is what lets an executor reject A's delayed action.
        XCTAssertNotEqual(plansA, plansB,
                          "identical pane sets from different attempts compared equal; a delayed plan could target the replacement")
        XCTAssertNotEqual(plansA.subscribesOn, plansB.subscribesOn)
    }

    /// AXIS: retirement INSIDE the admission-to-emission window cannot relabel
    /// the action — it stays bound to the attempt that admitted it.
    ///
    /// The reviewer's ninth probe, which also refuted my equivalence claim: I
    /// argued binding to `authority.current ?? attempt` was equivalent because
    /// admission guarantees the two coincide — but admission's lock releases
    /// before emission constructs the action, and a concurrent retirement in
    /// that gap makes them diverge. The action is now constructed exclusively
    /// from the admission VERDICT (which carries its attempt out of the
    /// critical section), and this test drives the exact interleaving through
    /// the seam: pause A after admission, retire A and adopt B, resume.
    func testRetirementInsideTheEmissionWindowCannotRelabelTheAction() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptA, at: Date()), &state)

        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var instrumented = recovery
        instrumented.afterAdmissionHook = {
            paused.signal()
            _ = resume.wait(timeout: .now() + 5.0)
        }

        let box = PlanBox()
        let lane = state                       // shares the lineage's authority
        let worker = Thread { [instrumented, lane] in
            var laneState = lane
            let plan = instrumented.observe(
                PaneSnapshot(agents: try! Self.decodePanes(["p1", "pnew"])), from: attemptA, state: &laneState)
            box.set(plan)
        }
        worker.start()
        XCTAssertEqual(paused.wait(timeout: .now() + 5.0), .success, "never reached the window")

        // Inside A's window: retire A, adopt B.
        _ = plan(.networkChanged(at: Date()), &state)
        let attemptB = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptB, at: Date()), &state)

        resume.signal()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, box.snapshot() == nil { usleep(10_000) }

        let boundTo = try XCTUnwrap(box.snapshot()).subscribesOn
        XCTAssertEqual(boundTo, attemptA,
                       "the action admitted under A was relabeled \(boundTo == attemptB ? "as B" : "unexpectedly") inside the emission window")
    }

    /// AXIS: a delayed snapshot from an abandoned attempt admits nothing onto
    /// its replacement.
    ///
    /// The reviewer's seventh probe: adopt A and start its resync,
    /// networkChanged to B, adopt B, then A's slow snapshot finally arrives.
    /// Without provenance it was indistinguishable from B's data — its pane
    /// was subscribed and recorded on B's ledger, and B's own later snapshot
    /// could not retract it. Snapshots now carry the attempt whose transport
    /// produced them, and admission verifies it in the same critical section.
    func testADelayedSnapshotFromAnAbandonedAttemptAdmitsNothing() throws {
        var state = try seeded(["p1"])
        let attemptA = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptA, at: Date()), &state)   // A's resync is now in flight

        let changed = plan(.networkChanged(at: Date()), &state)
        let attemptB = changed.reconnectAttempt!
        _ = plan(.connected(attemptB, at: Date()), &state)

        // A's delayed snapshot lands — it saw a pane B's world does not have.
        let stale = recovery.observe(
            PaneSnapshot(agents: try panes(["p1", "ghost"])), from: attemptA, state: &state)
        XCTAssertTrue(stale.isEmpty, "an abandoned attempt's snapshot subscribed panes onto its replacement")
        XCTAssertFalse(state.subscribedPanes.contains("ghost"), "B's ledger recorded A's pane")
        XCTAssertFalse(state.knownPanes.contains("ghost"), "A's stale knowledge overwrote B's")

        // B's own snapshot works exactly as before.
        let current = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptB, state: &state)
        XCTAssertEqual(current.subscribes, ["p1"])
    }

    /// AXIS: a late pane event from an abandoned attempt neither subscribes nor
    /// mutates knowledge on its replacement.
    func testALatePaneEventFromAnAbandonedAttemptActsOnNothing() throws {
        var state = try seeded(["p1"])
        let attemptA = connect(&state)
        _ = plan(.networkChanged(at: Date()), &state)
        let attemptB = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        _ = plan(.connected(attemptB, at: Date()), &state)
        _ = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptB, state: &state)

        XCTAssertTrue(plan(.paneCreated("late", from: attemptA), &state).isEmpty)
        XCTAssertFalse(state.knownPanes.contains("late"), "a dead transport's event became knowledge")
        XCTAssertTrue(plan(.paneClosed("p1", from: attemptA), &state).isEmpty)
        XCTAssertTrue(state.knownPanes.contains("p1"), "a dead transport's event removed live knowledge")
    }

    /// AXIS: a saved foregrounded copy cannot dial after backgrounding.
    ///
    /// The reviewer's replay probe: isForeground was value-stored, so saving a
    /// foregrounded State, processing backgrounded, restoring the copy and
    /// calling beginInitialAttempt emitted cancel+reconnect — dialing while
    /// suspended, against the explicit rule. Foreground is a decision input and
    /// lives in the shared authority now.
    func testASavedForegroundedCopyCannotDialAfterBackgrounding() throws {
        var state = try seeded(["p1"])
        let saved = state                       // foregrounded copy
        // MARK THE LIVE STATE so the restore below is observable. Deleting
        // `state = saved` left these tests green: the authority is shared by
        // reference, so the assertions held whether or not the value copy was
        // ever restored — they pinned the reference behaviour and said nothing
        // about replay, which is the entire subject. knownPanes is
        // value-stored, so it travels with the copy and distinguishes them.
        state.knownPanes.insert("live-marker-5")

        _ = plan(.backgrounded(at: Date()), &state)
        state = saved                           // the replay
        XCTAssertFalse(state.knownPanes.contains("live-marker-5"),
                       "the saved copy was never restored; this test is not about replay")

        XCTAssertTrue(recovery.beginInitialAttempt(state: &state).isEmpty,
                      "a replayed foreground bit let a backgrounded client dial")
        XCTAssertFalse(state.isForeground, "the restored copy must read the lineage's foreground state")

        let resumed = plan(.foregrounded(at: Date()), &state)
        XCTAssertNotNil(resumed.reconnectAttempt, "a real foregrounding must still dial")
    }

    /// AXIS: retirement and replacement are one fact — duplicate failures earn
    /// ONE reconnect, and the failed attempt is never current once its failure
    /// begins processing.
    ///
    /// The reviewer's gated probes: the split fail-then-mint left the failed
    /// attempt current in the backoff window, where connected(A) re-adopted the
    /// failed transport, and eight concurrent transportFailed(A) each passed
    /// the current-attempt check and earned eight reconnects.
    func testDuplicateFailuresEarnOneReconnectAndNoReadoption() throws {
        var state = try seeded(["p1"])
        let attemptA = connect(&state)

        // Sequential half: after ONE failure is processed, the failed attempt
        // is already retired — its own late connected must be stale.
        let first = plan(.transportFailed(attemptA, at: Date()), &state)
        XCTAssertNotNil(first.reconnectDelay, "the real failure schedules the retry")
        XCTAssertEqual(plan(.connected(attemptA, at: Date()), &state).actions, [.discardConnection],
                       "the failed attempt was re-adopted inside the backoff window")

        // Concurrent half: eight duplicate failure callbacks, one reconnect.
        var fresh = try seeded(["p1"])
        let attemptB = connect(&fresh)
        let counted = NSLock()
        var reconnects = 0
        DispatchQueue.concurrentPerform(iterations: 8) { lane in
            var copy = fresh
            var generator = SeededGenerator(seed: UInt64(lane) + 40)
            let outcome = recovery.plan(for: .transportFailed(attemptB, at: Date()), state: &copy, using: &generator)
            if outcome.reconnectAttempt != nil {
                counted.lock(); reconnects += 1; counted.unlock()
            }
        }
        XCTAssertEqual(reconnects, 1,
                       "\(reconnects) of 8 duplicate failure callbacks earned a reconnect; retirement must be one fact")
    }

    /// AXIS: concurrent discoveries neither lose ledger entries nor emit a
    /// pane's subscription twice.
    ///
    /// The reviewer's probe: 10,000 concurrent paneCreated calls against
    /// separately-locked get/set accessors retained ~1,400 ledger entries,
    /// and every lost pane could be subscribed AGAIN on rediscovery. State
    /// copies share the authority and both types are Sendable, so this is the
    /// advertised surface. Admission is now one critical section; this drives
    /// eight State copies of one lineage concurrently and requires exactly-once
    /// admission with nothing lost.
    func testConcurrentDiscoveriesAreAdmittedExactlyOnce() throws {
        var seed = try seeded(["p0"])
        let attempt = connect(&seed)

        let paneCount = 1_000
        let lanes = 8
        let collected = NSLock()
        var emitted: [String] = []

        // EVERY lane attempts EVERY pane, deliberately. A first version strided
        // the panes so each was owned by one lane — under which a mutation that
        // split the check from the record SURVIVED, because a stale check can
        // only double-admit when two threads race the SAME pane, and no two
        // ever did. Contention on the same keys is the property under test.
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            var copy = seed          // copies share the lineage's authority
            var generator = SeededGenerator(seed: UInt64(lane) + 1)
            for index in 0..<paneCount {
                let plan = recovery.plan(
                    for: .paneCreated("pane-\(index)", from: attempt), state: &copy, using: &generator)
                if let fresh = plan.subscribes, !fresh.isEmpty {
                    collected.lock(); emitted.append(contentsOf: fresh); collected.unlock()
                }
            }
        }

        XCTAssertEqual(seed.subscribedPanes.count, paneCount + 1,
                       "the ledger lost entries under concurrency")
        XCTAssertEqual(emitted.count, paneCount,
                       "every pane must be subscribed exactly once; \(emitted.count - paneCount) duplicates or losses")
        XCTAssertEqual(Set(emitted).count, paneCount, "a pane was emitted twice")
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
        XCTAssertFalse(resumed.actions.contains { if case .resyncAllPanes = $0 { return true }; return false },
                       "no transport yet to resync on")
        XCTAssertNil(resumed.subscribes, "no transport yet to subscribe on")

        let attempt = resumed.reconnectAttempt!
        let connected = plan(.connected(attempt, at: Date().addingTimeInterval(0.3)), &state)
        XCTAssertEqual(connected.actions, [.resyncAllPanes(attempt)],
                       "adoption emits resync ONLY; subscriptions derive from the snapshot it fetches")

        // The executor's next step: the resync's authoritative snapshot.
        let snapshot = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p2"])), from: attempt, state: &state)
        XCTAssertEqual(snapshot.subscribes, ["p1", "p2"],
                       "the fresh transport subscribes what the server says exists")

        let everything = backgrounded.actions + resumed.actions + connected.actions + snapshot.actions
        XCTAssertEqual(everything.filter { if case .resyncAllPanes = $0 { return true }; return false }.count, 1,
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

        let late = plan(.connected(AttemptID(uuid: UUID()), at: Date().addingTimeInterval(0.1)), &state)
        XCTAssertEqual(late.actions, [.discardConnection])
        XCTAssertFalse(late.actions.contains { if case .resyncAllPanes = $0 { return true }; return false },
                       "no work may start on an unwanted connection")
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
        XCTAssertEqual(adoptedB.actions, [.resyncAllPanes(attemptB)],
                       "adoption resyncs only; subscriptions come from the snapshot")
        let subscribed = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: attemptB, state: &state)
        XCTAssertEqual(subscribed.subscribes, ["p1"])

        // ...and then A reports its failure, after B is already in use.
        let failedA = plan(.transportFailed(attemptA, at: Date()), &state)
        XCTAssertTrue(failedA.isEmpty, "a stale failure must not schedule a reconnect")
        XCTAssertEqual(state.consecutiveFailures, 0, "a stale failure must not count against the backoff")
        XCTAssertNotNil(state.connectedSince, "a stale failure must not tear down the adopted connection")

        let everything = lateA.actions + adoptedB.actions + subscribed.actions + failedA.actions
        XCTAssertEqual(everything.filter { if case .resyncAllPanes = $0 { return true }; return false }.count, 1,
                       "exactly one adoption may resync")
        XCTAssertEqual(everything.filter { if case .subscribe = $0 { return true }; return false }.count, 1,
                       "exactly one snapshot-derived subscribe per recovery")
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
        // subscribedPanes: pane identity only (which panes THIS transport
        // watches), no ordering, no position. attemptEpoch: random identity
        // salt, never on the wire. Judged here out loud, which is this guard's
        // whole job.
        // `authority` is a reference to the lineage's live attempt record —
        // it holds one AttemptID and nothing pane- or stream-shaped; it exists
        // precisely so authority is NOT replayable value contents. Judged out
        // loud, as this guard requires. (`currentAttempt` left the list: it is
        // computed through the authority now, and Mirror sees stored fields.)
        // connectedSince and subscribedPanes left the stored list: both are
        // computed through the shared authority now, precisely so a value copy
        // cannot replay them. Mirror sees stored fields only.
        // isForeground moved INTO the authority: it is a decision input
        // (whether to dial), and value-stored it was replayable — a saved
        // foregrounded copy dialed while backgrounded. Stored value fields are
        // down to accounting (streak) and knowledge (panes), both documented as
        // replayable with bounded consequence.
        XCTAssertEqual(
            fields,
            ["authority", "consecutiveFailures", "knownPanes"],
            "SessionRecovery.State grew a field; if it can hold a stream position, resumption just became expressible"
        )
        // One level down too: State stores AttemptID, so a position smuggled
        // into AttemptID's fields would be invisible to the check above.
        let attemptFields = Mirror(reflecting: AttemptID(uuid: UUID()))
            .children.compactMap(\.label).sorted()
        XCTAssertEqual(attemptFields, ["uuid"],
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

    /// AXIS: pane events act only when their provenance is the current,
    /// connected attempt — a non-current event neither subscribes NOR is
    /// remembered, since an abandoned transport's events are not knowledge.
    func testPaneCreatedActsOnlyWithCurrentProvenance() throws {
        var state = try seeded([])
        let foreign = AttemptID(uuid: UUID())   // never minted by this lineage
        XCTAssertTrue(plan(.paneCreated("p9", from: foreign), &state).isEmpty)
        XCTAssertFalse(state.knownPanes.contains("p9"),
                       "an event from a non-current attempt must not mutate knowledge")

        let opened = connect(&state)
        XCTAssertEqual(plan(.paneCreated("p8", from: opened), &state).subscribes, ["p8"])
        XCTAssertTrue(plan(.paneCreated("p8", from: opened), &state).isEmpty,
                      "a repeat must not re-subscribe")
    }

    /// AXIS: a pane learned about mid-session survives into the next resync.
    ///
    /// Without this it becomes unwatched after the next reconnect, and its
    /// silence is indistinguishable from having no output.
    func testPanesLearnedDuringASessionAreResubscribedAfterReconnect() throws {
        var state = try seeded(["p1"])
        let first = connect(&state)
        _ = plan(.paneCreated("p2", from: first), &state)   // learned mid-session

        // THE LEARNING MUST HAVE HAPPENED, and it is the whole subject of this
        // test's name. Without it the test passed with the paneCreated deleted:
        // the authoritative snapshot after reconnect supplies p2 independently,
        // so the final assertion held for a reason unrelated to learning
        // anything mid-session.
        XCTAssertTrue(state.knownPanes.contains("p2"), "the mid-session pane was never learned")
        XCTAssertTrue(state.subscribedPanes.contains("p2"),
                      "the mid-session pane was learned but never subscribed")

        _ = plan(.networkChanged(at: Date()), &state)
        let second = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertEqual(plan(.connected(second, at: Date()), &state).actions, [.resyncAllPanes(second)])
        // The server still has p2, so the authoritative snapshot carries it.
        let resub = recovery.observe(PaneSnapshot(agents: try panes(["p1", "p2"])), from: second, state: &state)
        XCTAssertEqual(resub.subscribes, ["p1", "p2"],
                       "a pane discovered mid-session comes back via the snapshot, not memory")
    }

    /// AXIS: a closed pane stops being re-subscribed, WITHOUT needing a wholesale
    /// replacement of the set.
    ///
    /// Removal used to require passing a fresh full listing, which is what made
    /// partial listings dangerous — there was no other way to drop one.
    func testClosedPanesAreDroppedIncrementally() throws {
        // CONNECT FIRST, so paneClosed arrives from the CURRENT attempt.
        //
        // This seeded knownPanes with no current attempt and sent paneClosed
        // with a fresh random AttemptID, which production correctly REJECTS at
        // the provenance gate. The drop never happened — the authoritative
        // snapshot below removed p2 wholesale, producing the same final state,
        // and the assertion could not tell the two apart. Replacing the
        // paneClosed call with `_ = state` left the test green.
        //
        // Ninth instance today of an assertion expecting an absence with
        // nothing establishing the presence was reachable. Found by applying
        // the rule from the previous round to a test this PR never touched.
        var state = try seeded(["p1", "p2"])
        let opened = recovery.beginInitialAttempt(state: &state).reconnectAttempt!
        XCTAssertEqual(plan(.connected(opened, at: Date()), &state).actions, [.resyncAllPanes(opened)])
        XCTAssertTrue(state.knownPanes.contains("p2"), "p2 was never present; the drop is vacuous")

        _ = plan(.paneClosed("p2", from: opened), &state)

        // Asserted BEFORE any snapshot, which would otherwise mask the result by
        // producing the same absence for an unrelated reason.
        XCTAssertFalse(state.knownPanes.contains("p2"),
                       "the incremental close did not drop the pane")

        let resub = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: opened, state: &state)
        XCTAssertEqual(resub.subscribes, ["p1"])
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
        let opened = connect(&state)
        _ = recovery.observe(PaneSnapshot(agents: try panes(["p1"])), from: opened, state: &state)
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
    /// The SDK path, on Apple platforms only.
    ///
    /// Without it symbolgraph-extract cannot find the standard library at all —
    /// "missing required modules: 'Swift', '_Concurrency', ..." — because on
    /// Darwin the stdlib lives inside the SDK rather than beside the compiler.
    /// Linux needs nothing here, which is why the invocation worked for months
    /// without it.
    static func sdkFlags() -> [String] {
        #if canImport(Darwin)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--show-sdk-path"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let path = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? [] : ["-sdk", path]
        #else
        return []
        #endif
    }

    /// libssh2's header search path, from pkg-config.
    ///
    /// SwiftPM hands the CSSH target these flags automatically — but this test
    /// spawns symbolgraph-extract ITSELF, so it inherits nothing. On Debian that
    /// was invisible because /usr/include is a default search path; on macOS,
    /// Homebrew's prefix is not, so the shim's `#include <libssh2.h>` failed and
    /// the whole module could not be built for extraction.
    ///
    /// That is a defect the pkg-config fix CREATED: moving from a hardcoded path
    /// to a resolved one fixed the build and broke every hand-rolled tool
    /// invocation that had been relying on the hardcoded assumption.
    static func libssh2ClangFlags() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["pkg-config", "--cflags-only-I", "libssh2"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let text = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: " ").compactMap { flag -> [String]? in
            let f = flag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard f.hasPrefix("-I"), f.count > 2 else { return nil }
            return ["-Xcc", f]
        }.flatMap { $0 }
    }

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
        let buildTriple = moduleDir.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        // APPLE TRIPLES NEED THE DEPLOYMENT VERSION. SwiftPM names the build
        // directory with an UNVERSIONED triple ("arm64-apple-macosx"), and
        // symbolgraph-extract then defaults to macOS 10.4 — older than the
        // module's floor, so it refuses to load it and the invariant goes
        // unchecked. Invisible on Linux, which has no deployment-target concept.
        //
        // The running OS version is used rather than mirroring Package.swift's
        // floor: it is >= the floor by construction (the module could not have
        // been built otherwise), so it cannot drift out of step with the
        // manifest the way a duplicated constant would.
        let triple: String = {
            guard buildTriple.contains("apple"),
                  buildTriple.last.map({ !$0.isNumber }) ?? true else { return buildTriple }
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(buildTriple)\(v.majorVersion).\(v.minorVersion)"
        }()

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
            // Without this, @_spi(Anything) public symbols are OMITTED from the
            // graph — and an SPI initializer is callable outside the module by
            // any @_spi import, so its absence made the audit's "outside the
            // module" claim quietly narrower than stated. Verified both ways by
            // compiler probe before adding.
            "-include-spi-symbols",
            "-I", moduleDir.path,
            "-I", root.appendingPathComponent("Sources/CSSH").path,
        ] + Self.libssh2ClangFlags() + Self.sdkFlags() + [
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

        // Every symbol whose DECLARATION mentions the type, not just function
        // returns. Two narrower versions each let a construction path through:
        // member-only missed a free function, and returns-only missed a public
        // computed property (`public var empty: PaneSnapshot` yields instances
        // without having a functionSignature at all). Closures, subscripts and
        // variables would slip the same net, so the check is: any visible
        // symbol that mentions PaneSnapshot in its declaration is judged here,
        // out loud, against an exact whitelist — producers AND consumers,
        // because telling them apart per-kind is precisely the fragile part.
        let mentioners = symbols.compactMap { symbol -> String? in
            guard let path = symbol["pathComponents"] as? [String] else { return nil }
            if path.first == "PaneSnapshot" { return nil }   // members audited above
            let fragments = ((symbol["declarationFragments"] as? [[String: Any]]) ?? [])
                + (((symbol["functionSignature"] as? [String: Any])?["returns"] as? [[String: Any]]) ?? [])
            guard fragments.contains(where: {
                ($0["spelling"] as? String)?.contains("PaneSnapshot") == true
            }) else { return nil }
            return path.joined(separator: ".")
        }.sorted()
        // ExecutorTransport.fetchSnapshot RETURNS a snapshot but cannot MINT
        // one: an outside conformer must obtain the value it returns, and the
        // only source is HerdrClient.paneSnapshot() — the internal init still
        // gates construction. RecoveryExecutor.apply consumes. Judged here,
        // out loud, as this audit requires.
        XCTAssertEqual(
            mentioners,
            ["ExecutorTransport.fetchSnapshot(for:)", "HerdrClient.paneSnapshot()",
             "RecoveryExecutor.apply(snapshot:from:)", "SessionRecovery.observe(_:from:state:)"],
            "a new package-visible symbol mentions PaneSnapshot; if it can yield one from caller data it is a construction path, and only HerdrClient.paneSnapshot() may produce"
        )
    }
}
