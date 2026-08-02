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
    /// Open one pane's persistent event stream. `onTermination` SHOULD fire
    /// exactly once when the stream dies; the executor enforces the once with a
    /// latch regardless, because a double-fire would otherwise become a
    /// permanent double-subscription — the policy deliberately treats every
    /// admitted termination as a real death and cannot dedup without
    /// swallowing real second deaths. A conformer whose stream is torn down by
    /// `closeAll` should NOT fire termination for that teardown.
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

/// One-shot claim for a stream's termination callback.
final class TerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// True exactly once.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
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

    /// Retained for tests and diagnostics: every action this executor REFUSED,
    /// with the reason. Rejections are the point of the bindings, so they are
    /// observable rather than silent.
    public private(set) var rejections: [(action: String, reason: String)] = []

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
                    rejections.append((action: "reconnect", reason: "bound to a retired attempt"))
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
                    rejections.append((
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
        resourcedAttempt = attempt
        pendingDial = Task { [transport] in
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

    private func open(panes: Set<String>, for attempt: AttemptID) async {
        for pane in panes.sorted() {
            // Re-checked PER PANE, because every openStream await is an actor
            // suspension point: a retirement can interleave mid-loop, and a
            // door-only check let the remaining panes open for the retired
            // attempt AFTER its closeAll had run — orphan streams nothing would
            // ever close. Reproduced by test before this guard existed.
            guard attempt == state.currentAttempt else {
                rejections.append((
                    action: "openStream(\(pane))",
                    reason: "attempt retired mid-subscribe"
                ))
                return
            }
            do {
                // The exactly-once termination contract is ENFORCED here, not
                // merely asked of conformers: a transport double-firing one
                // stream's termination produced a permanent double-subscription
                // (the ledger legitimately re-admits per death, so the policy
                // cannot dedup this without swallowing real second deaths).
                // The latch drops duplicates and records them observably.
                let once = TerminationLatch()
                try await transport.openStream(pane: pane, for: attempt) { [weak self] in
                    guard once.claim() else {
                        Task { await self?.recordDuplicateTermination(pane: pane) }
                        return
                    }
                    Task { await self?.handle(.streamFailed(pane: pane, from: attempt)) }
                }
            } catch {
                // A stream that cannot OPEN is a death the same as one that
                // dies later; the policy decides whether to replace it.
                await handle(.streamFailed(pane: pane, from: attempt))
            }
        }
    }

    private func recordDuplicateTermination(pane: String) {
        rejections.append((
            action: "termination(\(pane))",
            reason: "duplicate termination dropped by the once-latch"
        ))
    }

    // MARK: - Read-only state, for tests and the UI layer

    public var currentAttempt: AttemptID? { state.currentAttempt }
    public var isConnected: Bool { state.isConnected }
    public var knownPanes: Set<String> { state.knownPanes }
    public var subscribedPanes: Set<String> { state.subscribedPanes }
}
