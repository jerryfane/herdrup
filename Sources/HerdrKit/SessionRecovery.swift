import Foundation

/// Something that happened to the connection or the app, which the client must
/// react to.
public enum ClientEvent: Equatable, Sendable {
    /// A transport finished establishing and is usable.
    case connected(at: Date)
    /// The transport dropped, or a request failed in a way that ends the session.
    case transportFailed(at: Date)
    /// The interface changed — Wi-Fi to cellular, a VPN came up, the address moved.
    case networkChanged(at: Date)
    case backgrounded(at: Date)
    case foregrounded(at: Date)
    /// The event stream reported a pane that did not exist before.
    case paneCreated(String)
}

/// What the client should do next.
public struct RecoveryPlan: Equatable, Sendable {
    /// Drop every cached pane generation and refetch from scratch.
    public var resyncAllPanes: Bool
    /// Panes that need a subscription opened. herdr's subscriptions are
    /// pane-scoped with **no wildcard**, so a pane absent from this set is a
    /// pane nothing is watching.
    public var subscribe: Set<String>
    /// Delay before the next connection attempt, or `nil` for "do not attempt".
    public var reconnectAfter: TimeInterval?

    public init(
        resyncAllPanes: Bool = false,
        subscribe: Set<String> = [],
        reconnectAfter: TimeInterval? = nil
    ) {
        self.resyncAllPanes = resyncAllPanes
        self.subscribe = subscribe
        self.reconnectAfter = reconnectAfter
    }
}

/// Decides how a client recovers from disconnection, network change and
/// backgrounding.
///
/// ## Why there is no "resume from sequence" here
///
/// herdr's EventHub is a **512-entry ring with no gap signal**. A client that
/// was away long enough falls off the back of it and **cannot detect that it
/// did** — the sequence numbers it sees afterwards are perfectly continuous with
/// the ones it remembers, and simply describe a different stretch of history.
///
/// So this type does not offer a way to resume from a remembered position, and
/// that absence is the design. An API that accepted a last-seen sequence would
/// be used, would look correct in every test written against a server that had
/// not wrapped, and would silently show stale panes in exactly the case it was
/// added for: a phone that was in someone's pocket.
///
/// Only two things are worth persisting across a gap: which pane the reader had
/// selected, and nothing else. Revisions are re-established by asking.
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
    public struct State: Equatable, Sendable {
        public var consecutiveFailures: Int = 0
        public var connectedSince: Date?
        public var isForeground: Bool = true
        /// Every pane the client believes exists. Subscriptions are pane-scoped,
        /// so this is also the re-subscribe list.
        public var knownPanes: Set<String> = []

        public init() {}
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

    public func plan(
        for event: ClientEvent,
        state: inout State,
        using generator: inout some RandomNumberGenerator
    ) -> RecoveryPlan {
        switch event {
        case .connected(let at):
            state.connectedSince = at
            // Every reconnection is a gap of unknown length, so it resyncs and
            // re-subscribes. There is no cheaper path on purpose.
            return RecoveryPlan(
                resyncAllPanes: true,
                subscribe: state.knownPanes,
                reconnectAfter: nil
            )

        case .transportFailed(let at):
            // A connection that lasted counts as healthy, so the next failure
            // starts from a short delay rather than inheriting an old streak.
            if let since = state.connectedSince, at.timeIntervalSince(since) >= stabilityInterval {
                state.consecutiveFailures = 0
            }
            state.connectedSince = nil
            state.consecutiveFailures += 1
            guard state.isForeground else { return RecoveryPlan() }
            return RecoveryPlan(
                reconnectAfter: backoff(failures: state.consecutiveFailures, using: &generator)
            )

        case .networkChanged:
            // Reconnect, not migrate. The old socket is bound to an address that
            // may no longer exist, and a half-open connection on a dead interface
            // fails by timing out rather than by erroring — which is the slowest
            // possible way to discover it.
            state.connectedSince = nil
            state.consecutiveFailures = 0
            guard state.isForeground else { return RecoveryPlan() }
            return RecoveryPlan(reconnectAfter: 0)

        case .backgrounded:
            state.isForeground = false
            // No reconnect scheduling while suspended: the attempt would not run,
            // and on return it would look like a fresh failure streak.
            return RecoveryPlan()

        case .foregrounded:
            state.isForeground = true
            state.consecutiveFailures = 0
            // Unconditional resync. The client cannot tell how long it was away,
            // and cannot tell whether it fell off the ring — so it must not try.
            return RecoveryPlan(
                resyncAllPanes: true,
                subscribe: state.knownPanes,
                reconnectAfter: 0
            )

        case .paneCreated(let pane):
            let isNew = state.knownPanes.insert(pane).inserted
            // Subscriptions are pane-scoped with no wildcard, so a new pane is
            // unwatched until something subscribes to it specifically.
            return RecoveryPlan(subscribe: isNew ? [pane] : [])
        }
    }

    /// Seeds the pane set from a listing, so a resync re-subscribes to panes the
    /// client learned about by asking rather than by event.
    public func observe(panes: [String], state: inout State) {
        state.knownPanes = Set(panes)
    }
}
