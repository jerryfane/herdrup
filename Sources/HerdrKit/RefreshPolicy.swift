import Foundation

/// Decides when to fetch a pane's screen.
///
/// This exists because herdr offers no per-output event. `pane.output_changed`
/// is internal to the server and absent from its `Subscription` enum, so an
/// event channel cannot drive per-frame refresh (verified against a live
/// server). What it *can* do is coarse invalidation — status changes, turn
/// completion — while `agent.list`'s `state_change_seq` acts as the output tick.
///
/// Fetching is expensive over SSH: an 80-line ANSI screen is 4-6 KB, which sits
/// above the delayed-ACK threshold on a forwarded connection (~40 ms), and
/// herdr#29 adds ~100 ms per request until it is fixed. So the policy's job is
/// to fetch as rarely as it can get away with.
public enum RefreshAction: Equatable, Sendable {
    /// Fetch a fresh screen for this pane.
    case fetch
    /// Nothing changed; leave the rendered screen alone.
    case skip
    /// Content changed but the reader has scrolled away from the live edge.
    /// Replacing the screen under their finger is the readability failure the
    /// app exists to avoid, so hold the frozen view and surface a "new output"
    /// affordance instead.
    case deferToReader
}

/// Per-pane refresh state. Value type so it is trivially testable.
public struct PaneRefreshState: Equatable, Sendable {
    public var lastSeenSeq: Int64?
    public var lastFetch: Date?
    public var readerScrolledAway: Bool

    public init(lastSeenSeq: Int64? = nil, lastFetch: Date? = nil, readerScrolledAway: Bool = false) {
        self.lastSeenSeq = lastSeenSeq
        self.lastFetch = lastFetch
        self.readerScrolledAway = readerScrolledAway
    }
}

public struct RefreshPolicy: Sendable {
    /// Shortest gap between fetches for the pane the reader is looking at.
    public var focusedMinInterval: TimeInterval
    /// Shortest gap for panes that are visible but not focused.
    public var backgroundMinInterval: TimeInterval

    public init(focusedMinInterval: TimeInterval = 0.1, backgroundMinInterval: TimeInterval = 1.0) {
        self.focusedMinInterval = focusedMinInterval
        self.backgroundMinInterval = backgroundMinInterval
    }

    /// Decide what to do for one pane at one instant.
    ///
    /// - Parameters:
    ///   - agent: the agent as most recently reported by `agent.list`.
    ///   - state: what this client last saw for that pane.
    ///   - focused: whether the reader is currently looking at this pane.
    ///   - now: current time, injected so tests need no clock.
    public func decide(
        agent: AgentInfo,
        state: PaneRefreshState,
        focused: Bool,
        now: Date
    ) -> RefreshAction {
        // A pane whose sequence we have never seen must be fetched once, so a
        // freshly opened pane renders immediately rather than after its next change.
        guard let seq = agent.stateChangeSeq else {
            return state.lastSeenSeq == nil && state.lastFetch == nil ? .fetch : .skip
        }
        guard let seen = state.lastSeenSeq else { return .fetch }

        // No change means no work, regardless of cadence. This is the whole point
        // of revision gating: idle panes cost one cheap agent.list entry, not a read.
        guard seq != seen else { return .skip }

        // Content moved, but replacing it now would yank the view out from under
        // someone mid-read.
        if state.readerScrolledAway { return .deferToReader }

        // Rate-limit by role. A background pane changing rapidly must not spend
        // the connection that the focused pane needs.
        let minInterval = focused ? focusedMinInterval : backgroundMinInterval
        if let last = state.lastFetch, now.timeIntervalSince(last) < minInterval {
            return .skip
        }
        return .fetch
    }
}

/// Tracks refresh state across panes and applies the policy to an `agent.list`
/// snapshot. Kept free of I/O so it can be tested without a server.
public struct RefreshCoordinator: Sendable {
    public private(set) var states: [String: PaneRefreshState] = [:]
    public var policy: RefreshPolicy

    public init(policy: RefreshPolicy = RefreshPolicy()) {
        self.policy = policy
    }

    /// Panes that should be fetched now, given a fresh `agent.list` result.
    public mutating func plan(
        agents: [AgentInfo],
        focusedPane: String?,
        now: Date
    ) -> [String: RefreshAction] {
        var plan: [String: RefreshAction] = [:]
        for agent in agents {
            let state = states[agent.paneID] ?? PaneRefreshState()
            let action = policy.decide(
                agent: agent,
                state: state,
                focused: agent.paneID == focusedPane,
                now: now
            )
            plan[agent.paneID] = action
        }
        // Panes that vanished should not keep state around forever.
        let live = Set(agents.map(\.paneID))
        states = states.filter { live.contains($0.key) }
        return plan
    }

    /// Record that a fetch completed, so the pane is not fetched again for the
    /// same sequence.
    public mutating func recordFetch(pane: String, seq: Int64?, at now: Date) {
        var state = states[pane] ?? PaneRefreshState()
        state.lastSeenSeq = seq
        state.lastFetch = now
        states[pane] = state
    }

    /// Update whether the reader has scrolled away from the live edge.
    public mutating func setReaderScrolledAway(pane: String, _ away: Bool) {
        var state = states[pane] ?? PaneRefreshState()
        state.readerScrolledAway = away
        states[pane] = state
    }

    public func state(for pane: String) -> PaneRefreshState? { states[pane] }
}
