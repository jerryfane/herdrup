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
/// The authoritative record of which attempt is current, REFERENCE-backed.
///
/// This exists because State is a public copyable value, and three identity
/// designs in a row fell to some form of replay — the last through ordinary
/// value restoration: save a copy while attempt A is current, cancel A and
/// mint B, restore the copy, and A was current again, reauthorized through the
/// sole staleness guard. No identity scheme fixes that while the authority
/// itself lives in replayable contents. So it does not: every copy of a State
/// lineage shares this one object, and restoring an old copy restores
/// bookkeeping but NOT authority — the shared reference still says B.
final class AttemptAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: AttemptID?
    private var _connectedSince: Date?
    private var _subscribedPanes: Set<String> = []

    var current: AttemptID? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }

    /// When the CURRENT attempt's connection was adopted, or nil.
    ///
    /// Lives here — not in the value State — because a value copy saved while A
    /// was connected replayed its date: `paneCreated` subscribed onto the
    /// cancelled transport, and the real replacement's `connected(B)` was
    /// classified as an already-adopted repeat and suppressed. Sharing is the
    /// fix; the INVARIANT that keeps this honest is that every transition which
    /// mints or clears `current` clears this first, so it can never describe a
    /// non-current attempt's transport. A first draft also carried an attempt
    /// tag as a second guard on the same property; the tag was unreachable
    /// (mutation-verified: removing it changed nothing), and an unpinnable
    /// twin guard is the trap this project has now hit three times.
    var connectedSince: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _connectedSince }
        set { lock.lock(); _connectedSince = newValue; lock.unlock() }
    }

    /// The subscription ledger, transport-scoped state like the connection —
    /// a replayed copy's ledger described the CANCELLED transport's
    /// subscriptions, which is the same poison one field over.
    var subscribedPanes: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _subscribedPanes }
        set { lock.lock(); _subscribedPanes = newValue; lock.unlock() }
    }
}

public struct AttemptID: Equatable, Hashable, Sendable {
    /// A fresh UUID per mint, derived from NOTHING the State stores.
    ///
    /// Two prior identities each fell to state replay. A bare counter restarted
    /// at 1 when a caller rebuilt the State, so a discarded state's callback
    /// matched the rebuild's first attempt. A per-State random epoch fixed the
    /// rebuild and fell to the copy: State is a value, so save-copy → mint →
    /// restore-copy → mint reproduced the identical (epoch, counter). The only
    /// identity replay cannot reproduce is one that never derives from
    /// replayable contents — so nothing about an AttemptID comes from State.
    ///
    /// Minting is replay-proof (nothing here derives from State), and since the
    /// authority moved into a shared reference, so is the record of WHICH
    /// attempt is current and connected: restoring an old State copy restores
    /// pane knowledge and streak bookkeeping, while attempt authority, the
    /// connection and the subscription ledger all read through the lineage's
    /// shared `AttemptAuthority` and cannot be replayed.
    let uuid: UUID
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
    /// still REPLACE the whole value. What survives replay: attempt minting
    /// (fresh UUIDs), attempt authority, the connection record and the
    /// subscription ledger — all read through the lineage's shared
    /// `AttemptAuthority`, so a restored copy cannot reauthorize a cancelled
    /// attempt, present its transport as connected, or replay its ledger. What
    /// replay DOES restore: pane knowledge (refreshed by the next snapshot)
    /// and the failure streak (worst case, a wrong backoff delay — degradation,
    /// not misdirection). A WHOLESALE `State()` rebuild is a fresh lineage:
    /// everything before it goes stale, which is the safe direction.
    public struct State: Equatable, Sendable {
        public static func == (lhs: State, rhs: State) -> Bool {
            lhs.authority === rhs.authority
                && lhs.consecutiveFailures == rhs.consecutiveFailures
                && lhs.isForeground == rhs.isForeground
                && lhs.knownPanes == rhs.knownPanes
        }

        public internal(set) var consecutiveFailures: Int = 0
        /// Bound to the current attempt: a connection only counts while it
        /// belongs to the attempt the authority says is current, so no replayed
        /// copy can present a cancelled transport as connected.
        public var connectedSince: Date? { authority.connectedSince }
        public internal(set) var isForeground: Bool = true
        /// Shared by every copy of this State lineage — see `AttemptAuthority`
        /// for why authority must not live in replayable value contents.
        internal let authority = AttemptAuthority()

        /// The only attempt whose callbacks are still wanted. Cleared by
        /// cancellation, backgrounding and network changes, so anything that
        /// completes afterwards is recognisably stale. Reads through the shared
        /// authority, so a restored copy reports the LINEAGE's current attempt,
        /// not the one it was carrying when saved.
        public var currentAttempt: AttemptID? { authority.current }
        /// Every pane the client believes exists. Subscriptions are pane-scoped,
        /// so this is also the re-subscribe list on the next adoption.
        public internal(set) var knownPanes: Set<String> = []
        /// Panes with an open subscription on the CURRENT transport. Distinct
        /// from `knownPanes`, and the distinction is load-bearing: a snapshot
        /// that shrinks removes a pane from knowledge while its subscription
        /// stays open (there is no unsubscribe verb on the wire — subscriptions
        /// end when their connection does). Without this ledger, that pane
        /// REAPPEARING got an incremental second subscription on top of its
        /// still-open first. Lives in the shared authority: it is
        /// transport-scoped exactly like the connection, and a replayed value
        /// copy of it described the cancelled transport's subscriptions.
        public var subscribedPanes: Set<String> { authority.subscribedPanes }

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
        // Never derived from State: see AttemptID's doc for the two identities
        // that were, and how each fell to replay.
        let id = AttemptID(uuid: UUID())
        state.authority.current = id
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
        state.authority.connectedSince = nil
        state.authority.subscribedPanes = []
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
            state.authority.connectedSince = at
            state.authority.subscribedPanes = state.knownPanes
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
            state.authority.connectedSince = nil
            state.authority.subscribedPanes = []
            state.consecutiveFailures += 1
            let delay = backoff(failures: state.consecutiveFailures, using: &generator)
            return RecoveryPlan([.reconnect(nextAttempt(&state), after: delay)])

        case .networkChanged:
            // Reconnect, not migrate. Cancel first: the old socket is bound to an
            // address that may no longer exist, and a half-open connection on a
            // dead interface fails by timing out rather than by erroring.
            state.authority.connectedSince = nil
            state.authority.subscribedPanes = []
            state.consecutiveFailures = 0
            state.authority.current = nil
            guard state.isForeground else { return RecoveryPlan([.cancelTransport]) }
            return RecoveryPlan([.cancelTransport, .reconnect(nextAttempt(&state), after: 0)])

        case .backgrounded:
            state.isForeground = false
            state.authority.connectedSince = nil
            state.authority.subscribedPanes = []
            state.authority.current = nil
            // Cancel rather than leave it open. A suspended process cannot read
            // the socket, and the server reaps it anyway — so the choice is
            // between closing it deliberately and discovering it dead later.
            return RecoveryPlan([.cancelTransport])

        case .foregrounded:
            state.isForeground = true
            state.consecutiveFailures = 0
            state.authority.connectedSince = nil
            state.authority.subscribedPanes = []
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
            state.knownPanes.insert(pane)
            // Subscribe only if there is a connection AND this transport does
            // not already hold a subscription for the pane. The second check is
            // the reappearing-pane case: a snapshot shrink forgets a pane while
            // its subscription stays open (no unsubscribe verb exists), so
            // "newly known" is not "unwatched".
            guard state.isConnected, !state.subscribedPanes.contains(pane) else {
                return RecoveryPlan()
            }
            state.authority.subscribedPanes.insert(pane)
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
        state.knownPanes = snapshot.paneIDs
        // Diffed against the SUBSCRIPTION ledger, not prior knowledge: a pane
        // this transport already watches must not be subscribed twice however
        // many times snapshots forget and rediscover it, and a shrink leaves
        // its open subscriptions in place because nothing on the wire can close
        // one short of the connection itself.
        let unwatched = snapshot.paneIDs.subtracting(state.subscribedPanes)
        guard state.isConnected, !unwatched.isEmpty else { return RecoveryPlan() }
        state.authority.subscribedPanes.formUnion(unwatched)
        return RecoveryPlan([.subscribe(unwatched)])
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
