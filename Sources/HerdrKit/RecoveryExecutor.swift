import Foundation

/// What the executor needs from a transport, and nothing more.
///
/// A protocol seam so the executor's behaviour — ordering, binding enforcement,
/// stale rejection — is testable against a scripted fake, which is where every
/// interesting case lives: the live network cannot be told to deliver a delayed
/// callback from a retired attempt on cue.
///
/// Each call carries the `AttemptID` it serves. The transport does not
/// interpret it — and does not hand it back: the executor binds outcomes to
/// their attempt by closure capture, so a conformer only needs the ID to key
/// its own resources per attempt (closeAll/discard MUST be attempt-scoped).
public protocol ExecutorTransport: Sendable {
    /// Establish a connection for this attempt. Throws on failure.
    func connect(for attempt: AttemptID) async throws
    /// The complete pane set, from the transport this attempt owns.
    func fetchSnapshot(for attempt: AttemptID) async throws -> PaneSnapshot
    /// Open one pane's persistent event stream.
    ///
    /// **Throwing MUST leave no live registration and no future callback.** A
    /// conformer that installs a callback and then throws creates a resource
    /// the executor does not know it owns: the catch path starts a replacement
    /// with its own latch, and a later first fire of the FAILED registration's
    /// callback retires the replacement's ledger entry and opens a third
    /// stream. The executor cannot detect that from outside, so it is a
    /// requirement here rather than a defence there.
    ///
    /// `onTermination` MUST fire for every terminal stream end that is not a
    /// deliberate `closeAll`/`discard` teardown — at-least-once is the
    /// conformer's binding obligation, because a missed notification IS the
    /// silent pane this event exists to remove. The executor's latch supplies
    /// at-most-once (a double-fire would otherwise become a permanent
    /// double-subscription, since the policy treats every admitted termination
    /// as a real death); together they make exactly-once. A stream torn down by
    /// `closeAll` must NOT fire — that is the executor's own teardown, not a
    /// death.
    func openStream(
        pane: String, for attempt: AttemptID,
        onTermination: @escaping @Sendable () -> Void
    ) async throws
    /// Tear down everything belonging to this attempt: streams and in-flight
    /// commands. Idempotent.
    func closeAll(for attempt: AttemptID) async
    /// Close a connection that completed but was never wanted (stale or
    /// backgrounded completion). Must not touch any other attempt's resources.
    func discard(attempt: AttemptID) async
}

/// Lifecycle latch for one stream registration: coordinates the termination
/// callback with the openStream return, atomically.
///
/// Two states short of this were two lies: a termination firing WHILE
/// openStream was suspended still saw the success path publish the pane as
/// open afterwards (falsely `.open` after exhaustion), and nothing tied a
/// termination to the registration it belonged to.
final class TerminationLatch: @unchecked Sendable {
    private enum Lifecycle {
        case fresh
        case published
        case terminated
    }

    private let lock = NSLock()
    private var lifecycle: Lifecycle = .fresh

    /// Termination side: true exactly once, whether or not the open ever
    /// published — at-most-once is unconditional.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .terminated = lifecycle { return false }
        lifecycle = .terminated
        return true
    }

    /// Open-return side: true iff the stream is still alive to publish. A
    /// registration whose termination already fired must NOT surface as open.
    func publishIfUnterminated() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .fresh = lifecycle else { return false }
        lifecycle = .published
        return true
    }
}

/// Drives `SessionRecovery`'s plans against a real transport, and turns the
/// transport's outcomes back into `ClientEvent`s.
///
/// This is the integration the policy's sixteen review rounds were preparing
/// for: every element crossing the boundary carries an `AttemptID`, and this
/// type is where the carried identity is finally ENFORCED — a subscribe bound
/// to a retired attempt is rejected here, at execution time, which is the whole
/// reason the binding exists.
///
/// An actor: plan execution mutates one `State` lineage and one set of live
/// stream registrations, and interleaving those across threads is precisely the
/// class of bug the policy's authority just spent five rounds closing.
public actor RecoveryExecutor {
    private let recovery: SessionRecovery
    private let transport: ExecutorTransport
    private var state: SessionRecovery.State
    private var generator: any RandomNumberGenerator
    /// Internal seam replacing Task.sleep in dial, so tests pin the backoff
    /// deterministically: a mutation deleting the delay SURVIVED 5/5 against
    /// wall-clock assertions — real time cannot pin "waited long enough"
    /// without flakes, so the seam records instead.
    var sleeper: @Sendable (TimeInterval) async -> Void = { delay in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    /// The pending dial, so a cancelTransport can stop an attempt that has not
    /// completed yet rather than letting it land and be discarded later.
    private var pendingDial: Task<Void, Never>?
    /// The attempt whose transport resources exist — dialed or connected.
    ///
    /// The EXECUTOR tracks this; the policy cannot say it. A cancel-and-
    /// reconnect plan mints the replacement BEFORE execution, so at execution
    /// time `state.currentAttempt` is already the new attempt — the first
    /// version of cancelTransport consulted it and closed the attempt that had
    /// not dialed yet, while the one actually holding sockets was never closed.
    /// Caught by the ordering test's operation log on its first run.
    private var resourcedAttempt: AttemptID?

    struct FailureKey: Hashable {
        let attempt: AttemptID
        let pane: String
    }
    /// LOAD-BEARING, NOT INCIDENTAL — read this before changing when it clears.
    ///
    /// It bounds retries, and since task 7 it is also the ONLY thing that
    /// distinguishes a never-wanted pane from a wanted-but-unreachable one.
    /// Exhaustion RETRACTS the ledger admission, so `paneStatus` can no longer
    /// learn that from ledger membership; at cap this counter is what makes an
    /// absent pane report `.admittedNotOpen` instead of `.notAdmitted`.
    ///
    /// Two properties are therefore contractual rather than convenient:
    ///   - NO LEDGER OPERATION MAY TOUCH IT. It has to survive the retraction
    ///     that removes the entry, or the distinction dies with the entry.
    ///   - IT IS KEYED BY (attempt, pane) AND RETIRES WITH ITS ATTEMPT, so a
    ///     pane exhausted on one connection gets a genuine fresh chance on the
    ///     next and does not report unreachable before it has been tried.
    /// Clearing it earlier, or keying it by pane alone, silently breaks a
    /// reported status rather than a retry bound.
    private var openFailures: [FailureKey: Int] = [:]
    private var lastOpenErrors: [FailureKey: String] = [:]
    /// Streams ACTUALLY open, keyed by pane and carrying the REGISTRATION that
    /// opened them — the executor's observation, distinct from the policy's
    /// admission ledger. Provenance here for the same reason as everywhere
    /// else in this file: an unprovenanced Set let a retired attempt's delayed
    /// termination flip a LIVE pane's status to admitted-not-open.
    private struct OpenRegistration {
        let attempt: AttemptID
        let registration: ObjectIdentifier
    }
    private var openStreams: [String: OpenRegistration] = [:]
    private var openPanes: Set<String> { Set(openStreams.keys) }

    /// What a caller asking "is this pane watched?" can actually know.
    ///
    /// **The answer is about WATCHING, not about ledger membership**, and since
    /// task 7 those are genuinely different questions. #11 introduced this
    /// surface as an observation that explicitly did NOT redefine admission —
    /// that sentence stood here and is now wrong, because task 7's policy round
    /// made exhaustion RETRACT the admission. A caller can no longer infer
    /// ledger membership from a case, and should not try to: ask
    /// `subscribedPanes` for membership and this for whether anything is
    /// actually watching.
    ///
    /// The three answers partition WATCHED / WANTED-BUT-UNWATCHED /
    /// NOT-WANTED, which is what a caller needs and what ledger membership
    /// alone can no longer express.
    public enum PaneWatchStatus: Equatable, Sendable {
        /// A live stream exists. Necessarily admitted.
        case open

        /// The pane is WANTED and NOT WATCHED — no stream exists.
        ///
        /// Two situations reach it and callers are not expected to
        /// distinguish them, because the actionable fact is the same:
        ///   - still in the ledger, opening or between retries;
        ///   - RETRACTED after exhausting its attempts on this connection —
        ///     absent from the ledger, but retained here because the intent
        ///     survives the retraction and a new connection will retry it.
        /// `attempts` at `openFailureCap` identifies the second.
        case admittedNotOpen(attempts: Int, lastError: String?)

        /// Not wanted: no admission and no exhausted attempt on this
        /// connection. NOT the same as "absent from the ledger" — an exhausted
        /// pane is also absent and reports `admittedNotOpen`.
        case notAdmitted
    }

    /// The same query path as `subscribedPanes`, answering per pane.
    public func paneStatus(_ pane: String) -> PaneWatchStatus {
        let key = state.currentAttempt.map { FailureKey(attempt: $0, pane: pane) }
        let failures = key.flatMap { openFailures[$0] } ?? 0
        guard state.subscribedPanes.contains(pane) else {
            // ABSENCE IS NOT ONE FACT. Since exhaustion RETRACTS the admission,
            // an absent pane is either never-wanted or wanted-but-unreachable,
            // and reporting `.notAdmitted` for both would delete the very
            // distinction this accessor exists to make.
            //
            // The failure counter is the discriminator, and no second store was
            // needed for it: it is keyed by (attempt, pane) and NO ledger
            // operation touches it, so it survives the retraction that removed
            // the ledger entry. At cap it means "admitted, could not be opened,
            // and will be retried on the next attempt".
            //
            // A pane exhausted on attempt N has NO failures on attempt N+1, so
            // after a reconnect it reports `.notAdmitted` until resync
            // re-admits it. That is correct — a new connection is a genuine
            // fresh chance and the pane has not failed on it — and it is
            // correct BY THE KEYING, which is why it is tested explicitly.
            guard failures >= Self.openFailureCap else { return .notAdmitted }
            return .admittedNotOpen(attempts: failures, lastError: key.flatMap { lastOpenErrors[$0] })
        }
        if openPanes.contains(pane) { return .open }
        return .admittedNotOpen(
            attempts: failures,
            lastError: key.flatMap { lastOpenErrors[$0] }
        )
    }

    /// Bounded diagnostics: the most recent refusals, plus how many were
    /// dropped. Append-only was a slow leak on a long-running client — stale
    /// plans and duplicate callbacks are rare but unbounded over days.
    public private(set) var rejections: [(action: String, reason: String)] = []
    public private(set) var droppedRejections = 0
    static let rejectionCapacity = 128

    private func record(rejection: (action: String, reason: String)) {
        rejections.append(rejection)
        if rejections.count > Self.rejectionCapacity {
            rejections.removeFirst(rejections.count - Self.rejectionCapacity)
            droppedRejections += 1
        }
    }

    /// Takes and clears the buffer, for a caller that ships diagnostics.
    public func drainRejections() -> (entries: [(action: String, reason: String)], dropped: Int) {
        let taken = (entries: rejections, dropped: droppedRejections)
        rejections = []
        droppedRejections = 0
        return taken
    }

    public init(recovery: SessionRecovery = SessionRecovery(), transport: ExecutorTransport) {
        self.init(recovery: recovery, transport: transport, generator: SystemRandomNumberGenerator())
    }

    /// Internal: a seeded generator makes the policy's jittered delay a known
    /// number, which is what lets a test assert the executor HONOURED it.
    init(
        recovery: SessionRecovery, transport: ExecutorTransport,
        generator: any RandomNumberGenerator
    ) {
        self.recovery = recovery
        self.transport = transport
        self.state = SessionRecovery.State()
        self.generator = generator
    }

    /// Cold start: mints the first attempt and dials.
    public func start() async {
        await execute(recovery.beginInitialAttempt(state: &state))
    }

    /// Entry point for every transport- or app-originated event.
    ///
    /// `.connected` is routed through the discard-aware path whichever door it
    /// arrives by — the dial callback and this public entry MUST behave
    /// identically, or a stale completion delivered as an event would be
    /// policy-discarded but left open at the transport.
    public func handle(_ event: ClientEvent) async {
        if case .connected(let attempt, _) = event {
            await handleConnected(attempt, at: eventDate(of: event) ?? Date())
            return
        }
        await execute(recovery.plan(for: event, state: &state, using: &generator))
    }

    private func eventDate(of event: ClientEvent) -> Date? {
        if case .connected(_, let at) = event { return at }
        return nil
    }

    /// Post-resync entry: the authoritative snapshot, with the attempt whose
    /// transport produced it.
    public func apply(snapshot: PaneSnapshot, from attempt: AttemptID) async {
        await execute(recovery.observe(snapshot, from: attempt, state: &state))
    }

    /// Internal, not private: a delayed plan arriving at execution is exactly
    /// the case the binding rejection exists for, and the test that proves the
    /// rejection must be able to hand one in.
    func execute(_ plan: RecoveryPlan) async {
        for action in plan.actions {
            switch action {
            case .cancelTransport:
                pendingDial?.cancel()
                pendingDial = nil
                openStreams = [:]
                retireCounters(keeping: nil)
                if let owned = resourcedAttempt {
                    await transport.closeAll(for: owned)
                    // Conditional, because the closeAll await is a suspension
                    // point: an interleaved plan may have dialed a replacement
                    // and installed ITS claim, and the unconditional nil
                    // destroyed it — after which every later cancelTransport
                    // closed a resource-less attempt while the current one's
                    // streams leaked past teardown forever. Reproduced 4/4.
                    if resourcedAttempt == owned { resourcedAttempt = nil }
                }

            case .discardConnection:
                // Routed where the completing attempt is KNOWN: both production
                // doors (the dial callback and the public .connected event) go
                // through handleConnected, which awaits transport.discard for
                // the stale attempt before executing this plan. Through the
                // internal execute() door the action is inert by construction —
                // it carries no attempt, deliberately, so a stale plan replay
                // cannot aim a discard at anything.
                break

            case .reconnect(let attempt, let after):
                // The same execution-time binding .subscribe has, and for a
                // sharper reason: a stale plan's continuation resuming after an
                // interleaved replacement would not merely dial a retired
                // attempt — its dial() would CANCEL the current attempt's
                // pending dial, and the silent cancellation return leaves no
                // reconnect scheduled at all: a wedged executor. Reproduced 4/4
                // by the sweep before this guard existed.
                guard attempt == state.currentAttempt else {
                    record(rejection: (action: "reconnect", reason: "bound to a retired attempt"))
                    continue
                }
                dial(attempt, after: after)

            case .resyncAllPanes(let attempt):
                await resync(for: attempt)

            case .subscribe(let panes, let on):
                // THE binding check. A plan can sit queued while the world
                // moves; an action bound to a retired attempt must be refused
                // however it arrives. This is enforcement of the invariant the
                // policy can only declare.
                guard on == state.currentAttempt else {
                    record(rejection: (
                        action: "subscribe(\(panes.sorted().joined(separator: ",")))",
                        reason: "bound to a retired attempt"
                    ))
                    continue
                }
                await open(panes: panes, for: on)
            }
        }
    }

    /// Connection outcomes route back through the policy with provenance; a
    /// completion the policy discards is then discarded AT the transport too.
    private func handleConnected(_ attempt: AttemptID, at: Date = Date()) async {
        let plan = recovery.plan(
            for: .connected(attempt, at: at), state: &state, using: &generator)
        if plan.actions.contains(.discardConnection) {
            await transport.discard(attempt: attempt)
        }
        await execute(plan)
    }

    func currentSleeper() -> @Sendable (TimeInterval) async -> Void { sleeper }

    func setSleeper(_ replacement: @escaping @Sendable (TimeInterval) async -> Void) {
        sleeper = replacement
    }

    private func dial(_ attempt: AttemptID, after delay: TimeInterval) {
        pendingDial?.cancel()
        // Close the PREVIOUS holder's resources before the claim moves. The
        // failure paths (connect throw, snapshot throw, external
        // transportFailed) route through the policy, whose plan is reconnect
        // ONLY — no cancelTransport — so without this, dialing the replacement
        // overwrote the claim and the failed attempt's connection and any
        // opened streams became unreachable forever. Reproduced by a
        // snapshot-failure probe: B connected with no closeAll(A) anywhere.
        let previous = resourcedAttempt
        resourcedAttempt = attempt
        retireCounters(keeping: attempt)
        openStreams = [:]
        pendingDial = Task { [transport] in
            if let previous, previous != attempt {
                await transport.closeAll(for: previous)
            }
            if delay > 0 { await self.currentSleeper()(delay) }
            guard !Task.isCancelled else { return }
            do {
                try await transport.connect(for: attempt)
                await self.handleConnected(attempt)
            } catch {
                await self.handle(.transportFailed(attempt, at: Date()))
            }
        }
    }

    /// Resync THEN subscribe, through `apply` — the ordering the policy
    /// documents as load-bearing. Subscriptions on a FRESH transport exist only
    /// downstream of this snapshot; the incremental paths (`paneCreated`,
    /// `streamFailed` re-admission) also open streams, but only for panes the
    /// atomic gate admits on an ALREADY-adopted transport — an earlier comment
    /// claimed no other path existed, which a probe refuted.
    private func resync(for attempt: AttemptID) async {
        do {
            let snapshot = try await transport.fetchSnapshot(for: attempt)
            await apply(snapshot: snapshot, from: attempt)
        } catch {
            await handle(.transportFailed(attempt, at: Date()))
        }
    }

    /// Bound on consecutive open failures for one pane on one attempt.
    ///
    /// Not a niceness: an open that throws becomes `.streamFailed`, the policy
    /// re-admits the pane, and the re-admission opens again — a persistently
    /// failing conformer is an unbounded, delay-free retry loop that saturates
    /// the actor. The delay grows per consecutive failure and resets when a
    /// pane opens successfully; past the cap the pane is left unsubscribed with
    /// the refusal recorded, which is a visibly degraded pane rather than a
    /// spinning client.
    static let openFailureCap = 5

    private func open(panes: Set<String>, for attempt: AttemptID) async {
        for pane in panes.sorted() {
            // NO pre-await binding check at the top of the iteration. The
            // invariant this loop keeps is stated once and held per site:
            // EVERY SUSPENSION POINT THAT CAN REACH THE TOP OF THE NEXT
            // ITERATION IS FOLLOWED BY ITS OWN ATTEMPT RECHECK.
            //
            // The qualifier is load-bearing. The body contains FOUR awaits; the
            // fourth is `transport.closeAll` inside the reap below, which is
            // followed unconditionally by `return`, so its resumption cannot
            // reach the loop head and it needs no check. Three can, and each has
            // a distinct correction because each leaves the world in a
            // different state:
            //   1. the backoff `sleeper` below       -> plain return, nothing built yet
            //   2. `transport.openStream` succeeding  -> RECHECK-AND-REAP; a
            //      registration now exists past the teardown that would have
            //      closed it, so returning without reaping leaks it
            //   3. `handle(.streamFailed)` in the catch -> plain return; the
            //      throwing open left no registration to reap
            //
            // A top-of-iteration guard was tried and removed as unreachable,
            // and that removal was WRONG — round seven built a probe that
            // walked straight through the hole. The reasoning failed by
            // enumerating only the success path: the catch path also suspends,
            // and it did not pass through the reap on its way back to here. The
            // per-site rule is what makes that enumerable at all; a single
            // top-of-loop check invites exactly the mistake I made, because it
            // reads as covering suspensions it never sees.
            let failures = openFailures[FailureKey(attempt: attempt, pane: pane)] ?? 0
            guard failures < Self.openFailureCap else {
                record(rejection: (
                    action: "openStream(\(pane))",
                    reason: "open failed \(failures) times; pane left unsubscribed"
                ))
                // RETRACT THE ADMISSION. Before this, the pane stayed in the
                // ledger with nothing watching it — subscribed in name, silent
                // in fact. The policy owns the ledger, so exhaustion is an
                // EVENT, not a reach-in.
                //
                // Suspension point: `handle` re-enters the policy. It is
                // followed by its own attempt recheck, per this loop's
                // invariant — see the enumeration at the top of the body.
                await handle(.streamExhausted(pane: pane, from: attempt))
                guard attempt == state.currentAttempt else {
                    record(rejection: (
                        action: "openStream(\(pane))",
                        reason: "attempt retired while retracting an exhausted pane; remaining panes abandoned"
                    ))
                    return
                }
                continue
            }
            if failures > 0 {
                // Back off between consecutive failures for THIS pane on THIS
                // attempt, through the same seam the dial uses so tests pin it.
                await sleeper(Double(failures) * 0.25)
                guard attempt == state.currentAttempt else {
                    record(rejection: (
                        action: "openStream(\(pane))",
                        reason: "attempt retired during retry backoff; retry abandoned"
                    ))
                    return
                }
            }
            do {
                // The exactly-once termination contract is ENFORCED here, not
                // merely asked of conformers: a transport double-firing one
                // stream's termination produced a permanent double-subscription
                // (the ledger legitimately re-admits per death, so the policy
                // cannot dedup this without swallowing real second deaths).
                // The latch drops duplicates and records them observably.
                let once = TerminationLatch()
                let registration = ObjectIdentifier(once)
                try await transport.openStream(pane: pane, for: attempt) { [weak self] in
                    guard once.claim() else {
                        Task { await self?.recordDuplicateTermination(pane: pane) }
                        return
                    }
                    Task {
                        await self?.streamDied(pane: pane, from: attempt, registration: registration)
                    }
                }
                // RECHECK-AND-REAP after the await. The pre-await guard cannot
                // cover the suspension itself: a teardown completing while
                // openStream was in flight leaves a stream registered for a
                // retired attempt — published after its closeAll, so nothing
                // would ever close it. Reaping is the only correction available
                // once the registration exists.
                if attempt != state.currentAttempt {
                    record(rejection: (
                        action: "openStream(\(pane))",
                        reason: "attempt retired during open; stream reaped"
                    ))
                    await transport.closeAll(for: attempt)
                    return
                }
                // Published only if the stream is still alive: a termination
                // firing while openStream was suspended already processed the
                // death, and publishing here anyway reported a dead stream as
                // .open — after exhaustion, permanently.
                //
                // The bookkeeping clears INSIDE the successful branch, not
                // before the decision: clearing first erased exhausted retry
                // state, so a pane that had burned every attempt reported
                // admittedNotOpen(attempts: 0, lastError: nil) — the status
                // surface telling the truth about openness while lying about
                // WHY — and a retained orphan callback could then restart
                // registration past the supposedly exhausted cap.
                if once.publishIfUnterminated() {
                    openStreams[pane] = OpenRegistration(attempt: attempt, registration: registration)
                    openFailures[FailureKey(attempt: attempt, pane: pane)] = nil
                    lastOpenErrors[FailureKey(attempt: attempt, pane: pane)] = nil
                }
            } catch {
                // A stream that cannot OPEN is a death the same as one that
                // dies later; the policy decides whether to replace it, and the
                // counter above bounds how often that replacement is attempted.
                // Guarded: a late catch for a RETIRED attempt must not insert a
                // key the retirement sweep already ran past.
                if attempt == state.currentAttempt {
                    openFailures[FailureKey(attempt: attempt, pane: pane), default: 0] += 1
                    lastOpenErrors[FailureKey(attempt: attempt, pane: pane)] = String(describing: error)
                }
                await handle(.streamFailed(pane: pane, from: attempt))
                // Suspension point 3. `handle` re-enters the policy, which
                // typically dials a REPLACEMENT stream for this pane and
                // suspends again inside it — a long, reliably-hit window with
                // this loop parked in the middle of it. A retirement delivered
                // there is invisible to every other check: the reap above is on
                // the success path, and the next iteration's backoff guard only
                // runs for a pane that has already failed once.
                //
                // Nothing to reap: `openStream` threw, and the seam's contract
                // is that a throwing open leaves no live registration. Streams
                // this attempt opened for EARLIER panes were closed by the
                // teardown's own closeAll while this await was suspended.
                guard attempt == state.currentAttempt else {
                    record(rejection: (
                        action: "openStream(\(pane))",
                        reason: "attempt retired while handling an open failure; remaining panes abandoned"
                    ))
                    return
                }
            }
        }
    }

    /// Drops failure bookkeeping for every attempt except the one kept: the
    /// counters were retained forever, one more unbounded structure — and a
    /// late catch after retirement could insert a key for a dead attempt.
    private func retireCounters(keeping attempt: AttemptID?) {
        openFailures = openFailures.filter { $0.key.attempt == attempt }
        lastOpenErrors = lastOpenErrors.filter { $0.key.attempt == attempt }
    }

    /// A stream's exactly-once death: the pane is no longer open — IF this
    /// death belongs to the registration currently published. A retired
    /// attempt's delayed termination must not flip a live replacement's status;
    /// the policy's own provenance gate then decides about the ledger and any
    /// replacement stream.
    private func streamDied(
        pane: String, from attempt: AttemptID, registration: ObjectIdentifier
    ) async {
        if let published = openStreams[pane], published.registration == registration {
            openStreams[pane] = nil
        }
        await handle(.streamFailed(pane: pane, from: attempt))
    }

    private func recordDuplicateTermination(pane: String) {
        record(rejection: (
            action: "termination(\(pane))",
            reason: "duplicate termination dropped by the once-latch"
        ))
    }

    // Internal observability for the retirement invariant — the mutation
    // removing retirement survived the whole suite because nothing counted.
    var openFailureEntryCount: Int { openFailures.count }
    var openFailureEntryCountForRetiredAttempts: Int {
        openFailures.keys.filter { $0.attempt != state.currentAttempt }.count
    }

    // MARK: - Read-only state, for tests and the UI layer

    public var currentAttempt: AttemptID? { state.currentAttempt }
    public var isConnected: Bool { state.isConnected }
    public var knownPanes: Set<String> { state.knownPanes }
    public var subscribedPanes: Set<String> { state.subscribedPanes }
}
