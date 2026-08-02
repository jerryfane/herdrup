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
    private var _isForeground = true

    var current: AttemptID? {
        lock.lock(); defer { lock.unlock() }; return _current
    }

    /// Foreground is a DECISION INPUT — whether to dial — so it lives here, not
    /// in the value State. Value-stored, a saved foregrounded copy restored
    /// after backgrounding read true and `beginInitialAttempt` dialed while
    /// suspended, defeating the no-dialing-while-backgrounded rule through
    /// ordinary replay.
    var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }; return _isForeground
    }

    /// When the CURRENT attempt's connection was adopted, or nil. Lives here —
    /// not in the value State — because a value copy saved while connected
    /// replayed its date, subscribing onto a cancelled transport and
    /// suppressing the real replacement's adoption as a "repeat".
    var connectedSince: Date? {
        lock.lock(); defer { lock.unlock() }; return _connectedSince
    }

    var subscribedPanes: Set<String> {
        lock.lock(); defer { lock.unlock() }; return _subscribedPanes
    }

    /// Every transition below is ONE critical section, deliberately. The first
    /// version exposed get/set accessors and let the policy compose them —
    /// which made every check-then-update a non-atomic read-modify-write across
    /// two lock acquisitions. A concurrent 10,000-pane probe retained ~1,400
    /// ledger entries, and each lost pane could then be subscribed AGAIN on
    /// rediscovery. State copies share this object and both types are Sendable,
    /// so concurrent use is the advertised surface, not an abuse of it.

    /// Every mint is foreground-gated INSIDE the section, because the
    /// foreground check and the mint were previously two operations — and a
    /// value-replayed foreground bit sat between them. There is deliberately no
    /// unconditional mint: no path may dial while backgrounded.

    private func unsafeMint() -> AttemptID {
        let id = AttemptID(uuid: UUID())
        _current = id
        _connectedSince = nil
        _subscribedPanes = []
        return id
    }

    /// Cold launch / caller restart: mints only if foregrounded, else nothing.
    func mintIfForeground() -> AttemptID? {
        lock.lock(); defer { lock.unlock() }
        guard _isForeground else { return nil }
        return unsafeMint()
    }

    /// Network change: the old transport is dead either way, so transport state
    /// tears down unconditionally; a replacement is minted only if foregrounded.
    func teardownAndMintIfForeground() -> AttemptID? {
        lock.lock(); defer { lock.unlock() }
        _current = nil
        _connectedSince = nil
        _subscribedPanes = []
        guard _isForeground else { return nil }
        return unsafeMint()
    }

    /// Backgrounding: no attempt survives it, nothing dials after it.
    func backgroundAndTeardown() {
        lock.lock(); defer { lock.unlock() }
        _isForeground = false
        _current = nil
        _connectedSince = nil
        _subscribedPanes = []
    }

    /// Foregrounding: becomes foreground and mints, one section, so no
    /// interleaved backgrounding can slip between the two.
    func foregroundAndMint() -> AttemptID {
        lock.lock(); defer { lock.unlock() }
        _isForeground = true
        return unsafeMint()
    }

    enum AdoptOutcome {
        case stale
        case repeated
        case adopted
    }

    /// Staleness check, repeat check and adoption in one section. The ledger
    /// seeds EMPTY, deliberately: it used to seed from the caller's remembered
    /// panes, and a replayed copy's memory could contain a pane the server had
    /// closed — adoption then subscribed the fresh transport to it, and no
    /// later snapshot could retract that (the wire has no unsubscribe).
    /// Subscriptions on a new transport derive only from post-adoption
    /// authoritative data, admitted through `admitWhileConnected`.
    func adopt(_ attempt: AttemptID, at: Date) -> AdoptOutcome {
        lock.lock(); defer { lock.unlock() }
        guard attempt == _current else { return .stale }
        guard _connectedSince == nil else { return .repeated }
        _connectedSince = at
        _subscribedPanes = []
        return .adopted
    }

    /// Validates the failed attempt, retires it, and mints its replacement in
    /// ONE section. The split version (fail-teardown, then a separate mint
    /// after backoff computation) left the FAILED attempt current in between:
    /// a gated probe re-adopted connected(A) for the failed transport inside
    /// that window, and eight concurrent transportFailed(A) callbacks each
    /// passed the same current-attempt check and earned eight reconnects.
    /// Retirement and replacement are one fact now — duplicates find A already
    /// retired and are stale.
    func retireAndReplace(_ attempt: AttemptID) -> (replacement: AttemptID, endedConnectionFrom: Date?)? {
        lock.lock(); defer { lock.unlock() }
        guard attempt == _current else { return nil }
        let since = _connectedSince
        // The failed attempt is retired and its replacement is current before
        // the lock releases; there is no observable in-between.
        return (replacement: unsafeMint(), endedConnectionFrom: since)
    }

    /// Admits the panes not already subscribed, records them, and returns ONLY
    /// the newly admitted — nil when there is no adopted connection to
    /// subscribe on. Check, record and connection gate share the section, so no
    /// interleaving can admit a pane twice or emit for a dead transport.
    func admitWhileConnected(_ panes: Set<String>) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        guard _connectedSince != nil else { return nil }
        let fresh = panes.subtracting(_subscribedPanes)
        _subscribedPanes.formUnion(fresh)
        return fresh
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
/// `.resyncAllPanes` is emitted in exactly one place: on adoption of a current
/// attempt — and adoption emits NOTHING else. Every subscription derives from
/// post-adoption authoritative data: the executor resyncs, then hands the
/// fresh `PaneSnapshot` to `observe`, whose atomic admission subscribes what
/// the server says exists; `paneCreated` admits event-driven discoveries the
/// same way. The invariants: **no pane's persistent subscription is opened
/// twice within one recovery**, and **no remembered pane is ever a
/// subscription target** — remembered knowledge subscribed a closed pane onto
/// a fresh transport once, irretractably, since the wire has no unsubscribe.
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
    /// still REPLACE the whole value. Every DECISION INPUT reads through the
    /// lineage's shared `AttemptAuthority` — attempt identity, the connection
    /// record, the subscription ledger, and the foreground bit (a value-stored
    /// foreground was the last replay: a saved foregrounded copy dialed while
    /// backgrounded) — so a restored copy cannot reauthorize a cancelled
    /// attempt, present a dead transport as connected, replay its ledger, or
    /// dial while suspended. What replay restores: pane knowledge (refreshed by
    /// the next snapshot) and the failure streak (worst case, a wrong backoff
    /// delay — degradation, not misdirection). A WHOLESALE `State()` rebuild is
    /// a fresh lineage: everything before it goes stale, the safe direction.
    public struct State: Equatable, Sendable {
        public static func == (lhs: State, rhs: State) -> Bool {
            lhs.authority === rhs.authority
                && lhs.consecutiveFailures == rhs.consecutiveFailures
                && lhs.knownPanes == rhs.knownPanes
        }

        public internal(set) var consecutiveFailures: Int = 0
        /// Bound to the current attempt: a connection only counts while it
        /// belongs to the attempt the authority says is current, so no replayed
        /// copy can present a cancelled transport as connected.
        public var connectedSince: Date? { authority.connectedSince }
        public var isForeground: Bool { authority.isForeground }
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
    /// Starts an attempt no event triggered — a cold launch, or a caller-driven
    /// restart. Cancels first, clears adoption state (via mint's teardown), and
    /// is foreground-guarded; each property was earned by an observed failure,
    /// recorded on the case bodies below.
    public func beginInitialAttempt(state: inout State) -> RecoveryPlan {
        guard let minted = state.authority.mintIfForeground() else { return RecoveryPlan() }
        return RecoveryPlan([.cancelTransport, .reconnect(minted, after: 0)])
    }

    public func plan(
        for event: ClientEvent,
        state: inout State,
        using generator: inout some RandomNumberGenerator
    ) -> RecoveryPlan {
        switch event {
        case .connected(let attempt, let at):
            // Staleness, repeat-detection and adoption are ONE atomic
            // transition on the shared authority. Staleness is the sole
            // background protection (backgrounding clears the authority, so a
            // late completion cannot match — the removed isForeground twin
            // guard was unreachable); a repeat ready for the adopted attempt is
            // news, not a new adoption, because platforms deliver
            // ready -> waiting -> ready without a failure between.
            switch state.authority.adopt(attempt, at: at) {
            case .stale:
                return RecoveryPlan([.discardConnection])
            case .repeated:
                return RecoveryPlan()
            case .adopted:
                // Resync ONLY — no subscribe. Adoption used to subscribe the
                // remembered pane set, which turned replayed knowledge into
                // transport misdirection: a copy saved before paneClosed(p2)
                // re-subscribed the NEW transport to the closed pane, the
                // ledger recorded it, and no snapshot could retract it. The
                // executor resyncs, then feeds the authoritative snapshot to
                // `observe`, whose atomic admission subscribes exactly what the
                // server says exists. Remembered panes are never subscription
                // targets — knowledge is not a decision input any more.
                return RecoveryPlan([.resyncAllPanes])
            }

        case .transportFailed(let attempt, let at):
            // Stale failures are news about a connection nobody is using; the
            // staleness check and the teardown share the authority's critical
            // section, and streak accounting runs only when the failure was
            // real.
            // Retirement and replacement are ONE authority transition: the split
            // version left the failed attempt current until a later mint, and
            // in that window connected(A) re-adopted the failed transport while
            // eight concurrent duplicate failures each earned a reconnect.
            // Duplicates now find A already retired and are stale; streak
            // accounting runs only for the one real retirement.
            guard let retired = state.authority.retireAndReplace(attempt) else { return RecoveryPlan() }
            // A connection that lasted counts as healthy, so the next failure
            // starts from a short delay rather than inheriting an old streak.
            if let since = retired.endedConnectionFrom,
               at.timeIntervalSince(since) >= stabilityInterval {
                state.consecutiveFailures = 0
            }
            state.consecutiveFailures += 1
            let delay = backoff(failures: state.consecutiveFailures, using: &generator)
            return RecoveryPlan([.reconnect(retired.replacement, after: delay)])

        case .networkChanged:
            // Reconnect, not migrate. Cancel first: the old socket is bound to
            // an address that may no longer exist, and a half-open connection on
            // a dead interface fails by timing out rather than by erroring.
            state.consecutiveFailures = 0
            guard let minted = state.authority.teardownAndMintIfForeground() else {
                return RecoveryPlan([.cancelTransport])
            }
            return RecoveryPlan([.cancelTransport, .reconnect(minted, after: 0)])

        case .backgrounded:
            state.authority.backgroundAndTeardown()
            // Cancel rather than leave it open. A suspended process cannot read
            // the socket, and the server reaps it anyway — so the choice is
            // between closing it deliberately and discovering it dead later.
            return RecoveryPlan([.cancelTransport])

        case .foregrounded:
            state.consecutiveFailures = 0
            // Cancel FIRST — foregrounding is not guaranteed to find a dead
            // transport, and dialing beside a live one previously leaked two
            // sockets reading the same panes forever. Resync and subscriptions
            // follow on `connected`; there is no transport yet to run them on.
            return RecoveryPlan([.cancelTransport, .reconnect(state.authority.foregroundAndMint(), after: 0)])

        case .paneCreated(let pane):
            state.knownPanes.insert(pane)
            // Admission is atomic on the authority: the connection gate, the
            // already-subscribed check and the record are one critical section,
            // so concurrent discoveries can neither drop a ledger entry nor
            // subscribe a pane twice. Not connected -> the next adoption's
            // full-set subscribe covers it.
            guard let fresh = state.authority.admitWhileConnected([pane]), !fresh.isEmpty else {
                return RecoveryPlan()
            }
            return RecoveryPlan([.subscribe(fresh)])

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
        // Atomic admission against the SUBSCRIPTION ledger, not prior
        // knowledge: a pane this transport already watches must not be
        // subscribed twice however many times snapshots forget and rediscover
        // it, and a shrink leaves its open subscriptions in place because
        // nothing on the wire can close one short of the connection itself.
        guard let fresh = state.authority.admitWhileConnected(snapshot.paneIDs),
              !fresh.isEmpty else { return RecoveryPlan() }
        return RecoveryPlan([.subscribe(fresh)])
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
