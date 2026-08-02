import Foundation

/// Identifies one connection attempt.
///
/// Without this, recovery cannot tell a completion it asked for from one it
/// cancelled. A network change that abandons attempt A and starts B does not
/// stop A from finishing: `connected(A)` would be adopted, emit a resync and
/// subscriptions, and then `connected(B)` would do it all again — and a late
/// `transportFailed(A)` would tear down the B that had already been adopted.
///
/// Ordering the actions did not fix that, and could not: order is about the
/// steps inside one plan, and this is about which *attempt* a callback belongs
/// to.
public struct AttemptID: Equatable, Hashable, Sendable {
    let value: UInt64
}

/// Something that happened to the connection or the app.
public enum ClientEvent: Equatable, Sendable {
    /// The attempt with this identifier finished establishing.
    case connected(AttemptID, at: Date)
    /// The attempt with this identifier dropped or failed.
    case transportFailed(AttemptID, at: Date)
    /// The interface changed — Wi-Fi to cellular, a VPN came up, the address moved.
    case networkChanged(at: Date)
    case backgrounded(at: Date)
    case foregrounded(at: Date)
    /// The event stream reported a pane that did not exist before.
    case paneCreated(String)
    /// A pane went away. Without this, the only way to remove one is a wholesale
    /// replacement, which is what made partial listings dangerous.
    case paneClosed(String)
}

/// One step of recovery, in the order it must happen.
public enum RecoveryAction: Equatable, Sendable {
    /// Tear down the current or in-flight transport before anything else.
    ///
    /// A half-open socket on an interface that no longer exists fails by timing
    /// out rather than erroring, so leaving it in place makes the most
    /// recoverable case the slowest one to notice.
    case cancelTransport
    /// A connection that completed when the client no longer wants one. Close it
    /// rather than adopting it: adopting means opening subscriptions on a
    /// transport nobody is going to read.
    case discardConnection
    /// Open a new transport, tagging it with this identifier. Every later
    /// `connected` or `transportFailed` must carry it back.
    case reconnect(AttemptID, after: TimeInterval)
    /// Drop every cached pane generation and refetch.
    case resyncAllPanes
    /// Open subscriptions for these panes. The pane-scoped subscription kinds
    /// have **no wildcard**, so a pane absent here is a pane nothing is
    /// watching. (`Wire.swift` also models non-pane-scoped subscription kinds;
    /// this plan carries pane identity only and does not express those.)
    case subscribe(Set<String>)
}

/// An ordered list of steps. Order is the point.
///
/// The previous version was three independent fields, which could not say
/// whether to cancel before reconnecting, and had `foregrounded` requesting a
/// resync and subscriptions that `connected` then requested again — so a client
/// following both plans literally opened every persistent subscription twice and
/// could start work on a transport that was already stale.
///
/// `.resyncAllPanes` and the FULL-SET subscribe are emitted in exactly one
/// place: on adoption of a current attempt. `paneCreated` and `observe` emit
/// incremental subscribes for newly discovered panes while connected — so the
/// invariant is not "one emission site" but **no pane's persistent
/// subscription is opened twice within one recovery**.
public struct RecoveryPlan: Equatable, Sendable {
    public var actions: [RecoveryAction]

    public init(_ actions: [RecoveryAction] = []) { self.actions = actions }

    public var isEmpty: Bool { actions.isEmpty }

    /// Convenience for callers and tests that only care whether a step is present.
    public func contains(_ action: RecoveryAction) -> Bool { actions.contains(action) }

    public var reconnectDelay: TimeInterval? {
        for case .reconnect(_, let after) in actions { return after }
        return nil
    }

    /// The attempt this plan opens, if it opens one.
    public var reconnectAttempt: AttemptID? {
        for case .reconnect(let attempt, _) in actions { return attempt }
        return nil
    }

    public var subscribes: Set<String>? {
        for case .subscribe(let panes) in actions { return panes }
        return nil
    }
}

/// Decides how a client recovers from disconnection, network change and
/// backgrounding.
///
/// ## Why there is no "resume from sequence" here
///
/// **Scoped precisely, after two wrong versions.** The first invented a wire
/// fact ("the client sees perfectly continuous sequence numbers" — it sees
/// none on the stream). The second overcorrected into "a client cannot record
/// a position even if it wanted one" — also false, and false in the dangerous
/// direction: `AgentInfo` carries monotonic per-pane counters
/// (`stateChangeSeq`, `turnEpoch`, `revision`), `RefreshCoordinator` records
/// exactly such a position, and `invalidateAll()` exists because that
/// remembered position WOULD mislead across a gap.
///
/// What is actually true, checked against the wire types:
///
/// - **Stream resumption is unexpressible.** `Subscription` (`Wire.swift`)
///   encodes exactly `type` and `pane_id` — no cursor, so there is no way to
///   ask for "everything since X". Event envelopes carry no sequence. herdr's
///   512-entry ring is server-private, and a subscription silently starts from
///   whatever the server chooses, with no signal about what was skipped.
/// - **Positions a client CAN remember must not be trusted across a gap.**
///   That is `RefreshCoordinator`'s job, and it is why every adoption here
///   emits `.resyncAllPanes` — the action that drives `invalidateAll()` —
///   rather than letting cached generations stand.
///
/// So after any gap the only way to learn current state is to ask again:
/// `agent.list` plus fresh reads. This type persists pane identity and
/// connection bookkeeping, nothing stream-positional.
public struct SessionRecovery: Sendable {
    /// First retry delay.
    public var baseDelay: TimeInterval
    /// Ceiling on the backoff, before jitter.
    public var maximumDelay: TimeInterval
    /// How long a connection must survive before it counts as healthy.
    ///
    /// Resetting the backoff the moment a connection is *established* is the
    /// classic form of this bug: a server that accepts and immediately drops
    /// produces an unbounded stream of fast reconnects, because every attempt
    /// "succeeded" long enough to reset the counter. A connection has to *last*
    /// to prove anything.
    public var stabilityInterval: TimeInterval

    public init(
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 30,
        stabilityInterval: TimeInterval = 10
    ) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.stabilityInterval = stabilityInterval
    }

    /// Mutable recovery state. Kept separate from the policy so the policy stays
    /// a value with no hidden history.
    /// Field WRITES are closed to callers — `internal(set)` — so state changes
    /// go through this type's methods: `plan`, `beginInitialAttempt`, `observe`.
    ///
    /// Stated at that strength and no more, after a sweep refuted the stronger
    /// claim ("every transition goes through plan()"): two other methods mutate
    /// state, and value semantics plus the public initialiser mean a caller can
    /// still REPLACE the whole value — `state = SessionRecovery.State()` resets
    /// the attempt counter, after which a pre-reset attempt's identifier can be
    /// re-minted and a late callback mistaken for current. Wholesale
    /// replacement is the caller destroying their own session tracking, and no
    /// access level on fields prevents it; hold one `State` per client and
    /// never rebuild it mid-session.
    public struct State: Equatable, Sendable {
        public internal(set) var consecutiveFailures: Int = 0
        public internal(set) var connectedSince: Date?
        public internal(set) var isForeground: Bool = true
        /// The only attempt whose callbacks are still wanted. Cleared by
        /// cancellation, backgrounding and network changes, so anything that
        /// completes afterwards is recognisably stale.
        public internal(set) var currentAttempt: AttemptID?
        /// Monotonic within one `State` value's lifetime, so an identifier is
        /// not reused and a late callback is not mistaken for a current one —
        /// see the type doc for the wholesale-replacement caveat that bounds
        /// this claim.
        internal var nextAttemptValue: UInt64 = 0
        /// Every pane the client believes exists. Subscriptions are pane-scoped,
        /// so this is also the re-subscribe list.
        public internal(set) var knownPanes: Set<String> = []

        public init() {}

        var isConnected: Bool { connectedSince != nil }
    }

    /// Full-jitter backoff: a delay drawn uniformly from `0 ..< capped`.
    ///
    /// Jittered because a fleet of clients dropped by one network event would
    /// otherwise return in lockstep, and the reconnect storm arrives exactly when
    /// the server is least able to absorb it. Full jitter rather than a fixed
    /// fraction: it is the variant that actually decorrelates clients.
    public func backoff(
        failures: Int, using generator: inout some RandomNumberGenerator
    ) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponential = baseDelay * pow(2, Double(failures - 1))
        let capped = min(exponential, maximumDelay)
        return TimeInterval.random(in: 0..<capped, using: &generator)
    }

    /// Issues the next attempt identifier and makes it the only current one.
    ///
    /// Every prior attempt becomes stale at this point, which is what makes a
    /// late callback recognisable rather than plausible.
    private func nextAttempt(_ state: inout State) -> AttemptID {
        state.nextAttemptValue += 1
        let id = AttemptID(value: state.nextAttemptValue)
        state.currentAttempt = id
        return id
    }

    /// Starts an attempt no event triggered — a cold launch, or a caller-driven
    /// restart.
    ///
    /// Three properties earned by adversarial sweep, each from an observed
    /// failure: it **cancels first**, because calling it while a connection was
    /// live abandoned that transport with its subscriptions open, forever; it
    /// **clears `connectedSince`**, because the stale date made `paneCreated`
    /// emit subscribes for a transport the policy had just walked away from; and
    /// it is **foreground-guarded**, because it was the one mint that ignored
    /// backgrounding — which also made it the only path by which the redundant
    /// background guards elsewhere were reachable at all.
    public func beginInitialAttempt(state: inout State) -> RecoveryPlan {
        guard state.isForeground else { return RecoveryPlan() }
        state.connectedSince = nil
        return RecoveryPlan([.cancelTransport, .reconnect(nextAttempt(&state), after: 0)])
    }

    public func plan(
        for event: ClientEvent,
        state: inout State,
        using generator: inout some RandomNumberGenerator
    ) -> RecoveryPlan {
        switch event {
        case .connected(let attempt, let at):
            // Staleness is the ONE mechanism here, deliberately. A cancelled
            // attempt still finishes, and adopting it opens persistent
            // subscriptions on a transport the client already replaced — and
            // because backgrounding, network changes and cancellation all clear
            // `currentAttempt`, this same guard is what discards a connection
            // completing while backgrounded. An earlier version also kept a
            // separate `isForeground` guard for that case; it was unreachable
            // (nothing mints an attempt while backgrounded), and an unreachable
            // twin guard is the two-guards-one-property trap this project has
            // now hit twice: neither copy is individually pinnable.
            guard attempt == state.currentAttempt else {
                return RecoveryPlan([.discardConnection])
            }
            // A REPEAT connected for the already-adopted attempt is news, not a
            // new adoption. Platforms deliver it: a connection can go
            // ready -> waiting -> ready across a viability blip without failing,
            // so nothing guarantees one connected per attempt. Re-adopting
            // re-emitted resync and the full subscribe set — the duplicate this
            // type exists to prevent — and overwrote `connectedSince`, silently
            // restarting the stability clock.
            guard state.connectedSince == nil else { return RecoveryPlan() }
            state.connectedSince = at
            // The only emitter of `.resyncAllPanes`, and the only emitter of the
            // FULL-SET subscribe. Not the only `.subscribe` site: `paneCreated`
            // and `observe` emit incremental single-pane/added-pane subscribes
            // while connected. The invariant actually held is narrower than an
            // earlier comment claimed: no pane's persistent subscription is
            // opened twice within one recovery.
            return RecoveryPlan([.resyncAllPanes, .subscribe(state.knownPanes)])

        case .transportFailed(let attempt, let at):
            // A stale failure must not tear down the attempt that replaced it,
            // nor count against the backoff — it is news about a connection
            // nobody is using.
            // The staleness guard is also the background protection: backgrounding
            // clears `currentAttempt`, so a failure arriving while backgrounded
            // can never match it. An earlier version kept a second
            // `isForeground` branch below this guard; every mint requires the
            // foreground, so the branch was unreachable — dead defense that no
            // test could pin.
            guard attempt == state.currentAttempt else { return RecoveryPlan() }
            // A connection that lasted counts as healthy, so the next failure
            // starts from a short delay rather than inheriting an old streak.
            if let since = state.connectedSince, at.timeIntervalSince(since) >= stabilityInterval {
                state.consecutiveFailures = 0
            }
            state.connectedSince = nil
            state.consecutiveFailures += 1
            let delay = backoff(failures: state.consecutiveFailures, using: &generator)
            return RecoveryPlan([.reconnect(nextAttempt(&state), after: delay)])

        case .networkChanged:
            // Reconnect, not migrate. Cancel first: the old socket is bound to an
            // address that may no longer exist, and a half-open connection on a
            // dead interface fails by timing out rather than by erroring.
            state.connectedSince = nil
            state.consecutiveFailures = 0
            state.currentAttempt = nil
            guard state.isForeground else { return RecoveryPlan([.cancelTransport]) }
            return RecoveryPlan([.cancelTransport, .reconnect(nextAttempt(&state), after: 0)])

        case .backgrounded:
            state.isForeground = false
            state.connectedSince = nil
            state.currentAttempt = nil
            // Cancel rather than leave it open. A suspended process cannot read
            // the socket, and the server reaps it anyway — so the choice is
            // between closing it deliberately and discovering it dead later.
            return RecoveryPlan([.cancelTransport])

        case .foregrounded:
            state.isForeground = true
            state.consecutiveFailures = 0
            state.connectedSince = nil
            // Cancel FIRST. Foregrounding is not guaranteed to find a dead
            // transport: a foregrounded event with a connection still live (the
            // OS never suspended us, or a lifecycle bug delivered no
            // backgrounded) previously minted a replacement while the old
            // transport stayed open and subscribed — two sockets reading the
            // same panes, double-applied events, and nothing in any later plan
            // would ever close the first one. Then reconnect; resync and
            // subscriptions follow on `connected`, since there is no transport
            // yet to run them on.
            return RecoveryPlan([.cancelTransport, .reconnect(nextAttempt(&state), after: 0)])

        case .paneCreated(let pane):
            let isNew = state.knownPanes.insert(pane).inserted
            // Only worth subscribing now if there is a connection to subscribe
            // on; otherwise the next `connected` picks it up in the full set.
            guard isNew, state.isConnected else { return RecoveryPlan() }
            return RecoveryPlan([.subscribe([pane])])

        case .paneClosed(let pane):
            state.knownPanes.remove(pane)
            return RecoveryPlan()
        }
    }

    /// Replaces the known-pane set from an authoritative snapshot.
    ///
    /// Takes `PaneSnapshot`, which callers outside this module **cannot
    /// construct**, rather than an array they can filter. The previous signature
    /// took `[AgentInfo]` and was described as making a partial listing hard to
    /// pass — it did not: `result.filter { … }` is exactly as easy to write as
    /// `result`, and the test written to defend it in fact demonstrated a
    /// one-element array silently deleting two known panes.
    ///
    /// Incremental discovery goes through `.paneCreated` / `.paneClosed`.
    ///
    /// Returns a plan, because the previous `Void` signature had a hole the
    /// sweep reproduced: a pane created during a disconnection gap arrives via
    /// the post-reconnect snapshot, not via `paneCreated` — and the snapshot
    /// merely recorded it. The pane was then on the "re-subscribe list" and
    /// unsubscribed until the NEXT reconnect, silent the whole session, with
    /// even the app-layer workaround closed: `paneCreated` for it returned
    /// nothing, since the pane was already known. Subscriptions are pane-scoped
    /// with no wildcard, so nothing else would ever cover it.
    public func observe(_ snapshot: PaneSnapshot, state: inout State) -> RecoveryPlan {
        let added = snapshot.paneIDs.subtracting(state.knownPanes)
        state.knownPanes = snapshot.paneIDs
        guard state.isConnected, !added.isEmpty else { return RecoveryPlan() }
        return RecoveryPlan([.subscribe(added)])
    }
}

/// The complete pane set as the server reported it.
///
/// The guarantee is exactly what `internal` provides and no more: **code outside
/// this module cannot construct one**, so an app cannot hand `observe` a
/// filtered list. Inside the module any code can use the initializer, and
/// `HerdrClient.paneSnapshot()` is the intended source by convention rather than
/// by enforcement.
///
/// This guards ONE of the two routes to a shrunken pane set, and that is the
/// intended shape: the other route, `.paneClosed`, removes panes one at a time
/// on server-reported events — per-event removal driven by the wire, not a
/// caller-supplied list, which is the failure mode snapshots had.
///
/// An earlier comment here said "only `HerdrClient` can make one". That was
/// wrong, and wrong in the direction that makes a weak guarantee sound like a
/// strong one — which matters because the whole point of this type is that its
/// provenance is enforced rather than trusted.
public struct PaneSnapshot: Equatable, Sendable {
    public let paneIDs: Set<String>

    /// Deliberately not `public`. `PaneSnapshotAccessTests` checks the module's
    /// compiler-derived surface, so it fails on **any** widening — this
    /// initialiser or another one, `public` or `package`, however it is
    /// formatted. An earlier textual version of that guard recognised exactly
    /// one spelling and let three equivalent widenings through.
    init(agents: [AgentInfo]) {
        self.paneIDs = Set(agents.map(\.paneID))
    }
}
