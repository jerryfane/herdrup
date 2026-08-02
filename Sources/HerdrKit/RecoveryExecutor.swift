import Foundation

/// What the executor needs from a transport, and nothing more.
///
/// A protocol seam so the executor's behaviour — ordering, binding enforcement,
/// stale rejection — is testable against a scripted fake, which is where every
/// interesting case lives: the live network cannot be told to deliver a delayed
/// callback from a retired attempt on cue.
///
/// Each call carries the `AttemptID` it serves. The transport does not
/// interpret it; it hands it back on outcomes so the executor can route them
/// into the policy with provenance intact.
public protocol ExecutorTransport: Sendable {
    /// Establish a connection for this attempt. Throws on failure.
    func connect(for attempt: AttemptID) async throws
    /// The complete pane set, from the transport this attempt owns.
    func fetchSnapshot(for attempt: AttemptID) async throws -> PaneSnapshot
    /// Open one pane's persistent event stream. `onTermination` fires EXACTLY
    /// once when the stream dies — this is the executor's contract with the
    /// policy, which deliberately treats every termination as a real death.
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
    private var generator = SystemRandomNumberGenerator()
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
        self.recovery = recovery
        self.transport = transport
        self.state = SessionRecovery.State()
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
                    resourcedAttempt = nil
                }

            case .discardConnection:
                // The completing attempt is by definition not current (that is
                // why it is being discarded), so the transport is told which
                // one to drop by the event that got us here — but the action
                // itself carries nothing. The executor closes NOTHING here
                // beyond what the transport already associates with the stale
                // completion; see handleConnected for the routing.
                break

            case .reconnect(let attempt, let after):
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

    private func dial(_ attempt: AttemptID, after delay: TimeInterval) {
        pendingDial?.cancel()
        resourcedAttempt = attempt
        pendingDial = Task { [transport] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            do {
                try await transport.connect(for: attempt)
                await self.handleConnected(attempt)
            } catch {
                await self.handle(.transportFailed(attempt, at: Date()))
            }
        }
    }

    /// Resync THEN subscribe, and only through `apply` — the ordering the
    /// policy documents as load-bearing. Subscriptions on a fresh transport
    /// exist only downstream of this snapshot; there is no other path that
    /// opens one, which is what makes the order enforceable by a test that
    /// fails when it is swapped.
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
                try await transport.openStream(pane: pane, for: attempt) { [weak self] in
                    // One termination, one death event — the exactly-once
                    // contract the policy's per-death semantics rely on.
                    Task { await self?.handle(.streamFailed(pane: pane, from: attempt)) }
                }
            } catch {
                // A stream that cannot OPEN is a death the same as one that
                // dies later; the policy decides whether to replace it.
                await handle(.streamFailed(pane: pane, from: attempt))
            }
        }
    }

    // MARK: - Read-only state, for tests and the UI layer

    public var currentAttempt: AttemptID? { state.currentAttempt }
    public var isConnected: Bool { state.isConnected }
    public var knownPanes: Set<String> { state.knownPanes }
    public var subscribedPanes: Set<String> { state.subscribedPanes }
}
