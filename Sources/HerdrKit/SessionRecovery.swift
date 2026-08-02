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
    /// Open subscriptions for these panes. herdr's subscriptions are pane-scoped
    /// with **no wildcard**, so a pane absent here is a pane nothing is watching.
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
/// Resync and subscription now happen in exactly one place: on `connected`,
/// while in the foreground. Nothing else emits them.
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
/// An earlier version of this comment said the client sees sequence numbers
/// "perfectly continuous with the ones it remembers". **That was invented.** The
/// client sees no sequence numbers at all, and checking the wire types is what
/// established it:
///
/// - `Subscription` (`Wire.swift`) encodes exactly `type` and `pane_id`. There is
///   **no cursor field**, so there is no way to ask for "everything since X".
/// - Event envelopes carry no sequence, so a client cannot record a position even
///   if it wanted one.
/// - herdr's 512-entry ring is server-private. A subscription silently starts
///   from whatever history the server chooses to replay, with no signal about
///   what was skipped.
///
/// So resumption is not *unwise* here, it is **unexpressible** — and the real
/// consequence is stronger than the invented one. After any gap the only way to
/// learn the current state is to ask again: `agent.list` plus fresh reads. Not
/// because a remembered position would mislead, but because there is none to
/// remember.
///
/// The one thing worth persisting across a gap is which pane the reader had
/// selected. Everything else is re-established by asking.
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
    /// Fields are read-only to callers: every transition goes through `plan`, so
    /// there is no second way to reach this state that the policy does not see.
    public struct State: Equatable, Sendable {
        public internal(set) var consecutiveFailures: Int = 0
        public internal(set) var connectedSince: Date?
        public internal(set) var isForeground: Bool = true
        /// The only attempt whose callbacks are still wanted. Cleared by
        /// cancellation, backgrounding and network changes, so anything that
        /// completes afterwards is recognisably stale.
        public internal(set) var currentAttempt: AttemptID?
        /// Monotonic, so an identifier is never reused and a late callback can
        /// never be mistaken for a current one.
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

    /// Starts the first attempt of a cold launch, where no event triggered it.
    public func beginInitialAttempt(state: inout State) -> RecoveryPlan {
        RecoveryPlan([.reconnect(nextAttempt(&state), after: 0)])
    }

    public func plan(
        for event: ClientEvent,
        state: inout State,
        using generator: inout some RandomNumberGenerator
    ) -> RecoveryPlan {
        switch event {
        case .connected(let attempt, let at):
            // Stale completions are the reason attempts are identified at all: a
            // cancelled attempt still finishes, and adopting it opens persistent
            // subscriptions on a transport the client already replaced.
            guard attempt == state.currentAttempt else {
                return RecoveryPlan([.discardConnection])
            }
            // A connection completing after the client backgrounded is not wanted
            // either — iOS is about to suspend the process.
            guard state.isForeground else { return RecoveryPlan([.discardConnection]) }
            state.connectedSince = at
            // THE ONLY PLACE resync and subscription are emitted. Every
            // reconnection is a gap of unknown length, and doing it here rather
            // than also on `foregrounded` is what makes it exactly once.
            return RecoveryPlan([.resyncAllPanes, .subscribe(state.knownPanes)])

        case .transportFailed(let attempt, let at):
            // A stale failure must not tear down the attempt that replaced it,
            // nor count against the backoff — it is news about a connection
            // nobody is using.
            guard attempt == state.currentAttempt else { return RecoveryPlan() }
            // A connection that lasted counts as healthy, so the next failure
            // starts from a short delay rather than inheriting an old streak.
            if let since = state.connectedSince, at.timeIntervalSince(since) >= stabilityInterval {
                state.consecutiveFailures = 0
            }
            state.connectedSince = nil
            state.consecutiveFailures += 1
            guard state.isForeground else {
                state.currentAttempt = nil
                return RecoveryPlan()
            }
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
            // Reconnect ONLY. The resync and subscriptions follow on `connected`,
            // because there is no transport yet to run them on — emitting them
            // here as well is what produced duplicate subscriptions.
            return RecoveryPlan([.reconnect(nextAttempt(&state), after: 0)])

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
    public func observe(_ snapshot: PaneSnapshot, state: inout State) {
        state.knownPanes = snapshot.paneIDs
    }
}

/// The complete pane set as the server reported it.
///
/// Only `HerdrClient` can make one, so "this is the whole set" is enforced by
/// where the value came from rather than by asking callers to be careful.
public struct PaneSnapshot: Equatable, Sendable {
    public let paneIDs: Set<String>

    /// Internal on purpose: a caller outside the module cannot mint one from a
    /// filtered list, which is the entire guarantee.
    init(agents: [AgentInfo]) {
        self.paneIDs = Set(agents.map(\.paneID))
    }
}
