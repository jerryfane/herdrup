import Foundation

/// Decides when to fetch a pane's screen.
///
/// ## Why this is not simply revision-gated
///
/// The obvious design — poll `agent.list`, fetch only when `state_change_seq`
/// moves — is WRONG, and was shipped wrong before being caught in review.
///
/// `state_change_seq` counts *agent lifecycle* transitions, not terminal output.
/// Measured on a live server: a pane held `seq = 1092` across **13 distinct
/// screens** over ~26 seconds while `agent_status` stayed `working`. A policy
/// keyed solely to that counter returns `.skip` for every frame, and the reader
/// watches a frozen screen believing it is live. That is worse than over-fetching:
/// over-fetching costs bytes, this costs trust.
///
/// So the counter is treated as a *positive* signal only — when it moves,
/// something definitely changed and we fetch. It is never treated as proof that
/// nothing changed. A staleness floor guarantees a fetch regardless.
///
/// Fetching is expensive off-box: an 80-line ANSI screen is 4-6 KB, above the
/// delayed-ACK threshold on a forwarded connection (~40 ms), and herdr#29 adds
/// ~100 ms per request until fixed. The staleness floor is therefore tuned by
/// role rather than set globally aggressive.
public enum RefreshAction: Equatable, Sendable {
    /// Fetch a fresh screen for this pane.
    case fetch
    /// Nothing to do right now. Callers must keep planning — `skip` is not a
    /// terminal state, and a pane that skips now may be due a fetch shortly.
    case skip
    /// Content may have changed but the reader has scrolled away from the live
    /// edge. Hold the frozen view and surface a "new output" affordance rather
    /// than replacing the screen under their finger.
    case deferToReader
}

/// Whether a pane's byte stream is actually ALIVE, as opposed to whether the app
/// happens to be in front.
///
/// ## Why scene phase cannot answer this
///
/// The live terminal reseeds itself when the app returns to the foreground, because
/// output produced while away would otherwise be missing (herdr#62). That reseed was
/// keyed on the scene going `.background` and back, which is a PROXY — and it is only
/// true on one platform.
///
/// On iOS the app is suspended: the stream really did stop, output really was lost, and
/// a reseed repairs a genuine gap. On a Mac the process keeps running while another
/// Space or app is front. Frames keep arriving, nothing is lost, and reseeding then
/// destroys a perfectly live terminal — the remount discards the reader's selection and
/// scroll position, which is precisely what a reader switched apps to use.
///
/// So this records the FACT the decision actually needs: when a frame last arrived. The
/// server pings every 20s, so a still-connected stream is never more than about that
/// stale, while the reader's own view of "dead" is the terminal's stuck-stream timeout.
/// Callers pass that timeout in rather than this type inventing a second one, so the
/// host and the reconnect watchdog cannot drift apart on what "dead" means.
///
/// Deliberately a plain reference type and NOT observable: the terminal writes to it on
/// every frame, and publishing at the firehose's rate would re-render the UI constantly.
/// The host reads it once, at the moment it has a decision to make.
public final class StreamLiveness {
    /// When a frame (data, ping, resize, reset) last arrived, or nil if none ever has.
    public private(set) var lastFrameAt: Date?

    public init(lastFrameAt: Date? = nil) { self.lastFrameAt = lastFrameAt }

    public func noteFrame(at moment: Date = Date()) { lastFrameAt = moment }

    /// True when the stream shows no sign of life within `timeout`.
    ///
    /// Never having received a frame counts as stale. That is the conservative answer
    /// and it is the right one here: a stream that has delivered nothing has no screen
    /// state worth preserving, so reseeding it costs the reader nothing.
    public func isStale(now: Date = Date(), timeout: TimeInterval) -> Bool {
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) > timeout
    }
}

/// Server-assigned generation for a pane.
///
/// Pairs the lifecycle counter with `turn_epoch`, which changes across server
/// boot, respawn and restore. Comparing the pair catches a restart that resets
/// `state_change_seq` to a value coincidentally equal to the cached one — which
/// a bare `!=` on the counter alone would silently skip.
///
/// Both are `UInt64` to match the server's own types; decoding them as `Int64`
/// would fail the whole payload once a value exceeds `Int64.max`.
public struct PaneGeneration: Equatable, Sendable {
    public var stateChangeSeq: UInt64?
    public var turnEpoch: UInt64?

    public init(stateChangeSeq: UInt64? = nil, turnEpoch: UInt64? = nil) {
        self.stateChangeSeq = stateChangeSeq
        self.turnEpoch = turnEpoch
    }

    public init(_ agent: AgentInfo) {
        self.stateChangeSeq = agent.stateChangeSeq
        self.turnEpoch = agent.turnEpoch
    }
}

public struct PaneRefreshState: Equatable, Sendable {
    public var lastSeen: PaneGeneration
    public var lastFetch: Date?
    public var readerScrolledAway: Bool
    /// Set when a change was observed but not acted on — rate-limited, or held
    /// back for a scrolled reader. Without this, a change seen inside the rate
    /// floor is lost the moment the counter stops moving.
    public var pendingChange: Bool

    public init(
        lastSeen: PaneGeneration = PaneGeneration(),
        lastFetch: Date? = nil,
        readerScrolledAway: Bool = false,
        pendingChange: Bool = false
    ) {
        self.lastSeen = lastSeen
        self.lastFetch = lastFetch
        self.readerScrolledAway = readerScrolledAway
        self.pendingChange = pendingChange
    }
}

public struct RefreshPolicy: Sendable {
    /// Shortest gap between fetches for the pane the reader is looking at.
    public var focusedMinInterval: TimeInterval
    /// Shortest gap for panes that are visible but not focused.
    public var backgroundMinInterval: TimeInterval
    /// Longest a focused pane may go without a fetch, whatever the counters say.
    /// This is the guarantee that a streaming pane cannot freeze.
    public var focusedMaxStaleness: TimeInterval
    /// Longest a background pane may go without a fetch.
    public var backgroundMaxStaleness: TimeInterval

    public init(
        focusedMinInterval: TimeInterval = 0.1,
        backgroundMinInterval: TimeInterval = 1.0,
        focusedMaxStaleness: TimeInterval = 1.0,
        backgroundMaxStaleness: TimeInterval = 15.0
    ) {
        self.focusedMinInterval = focusedMinInterval
        self.backgroundMinInterval = backgroundMinInterval
        self.focusedMaxStaleness = focusedMaxStaleness
        self.backgroundMaxStaleness = backgroundMaxStaleness
    }

    public func decide(
        agent: AgentInfo,
        state: PaneRefreshState,
        focused: Bool,
        now: Date
    ) -> RefreshAction {
        let current = PaneGeneration(agent)
        let generationMoved = current != state.lastSeen
        // Never fetched at all — render once immediately.
        guard let lastFetch = state.lastFetch else { return .fetch }

        let elapsed = now.timeIntervalSince(lastFetch)
        let minInterval = focused ? focusedMinInterval : backgroundMinInterval
        let maxStaleness = focused ? focusedMaxStaleness : backgroundMaxStaleness

        // A reader who scrolled back is never yanked to the live edge, whether the
        // change is fresh or carried over from an earlier tick.
        if state.readerScrolledAway {
            return (generationMoved || state.pendingChange) ? .deferToReader : .skip
        }

        // Below the rate floor nothing is fetched, but a change seen here is
        // remembered via pendingChange so it cannot be lost.
        if elapsed < minInterval { return .skip }

        // Positive signal: something definitely changed.
        if generationMoved || state.pendingChange { return .fetch }

        // No signal — but absence of signal is NOT evidence of no output, because
        // state_change_seq does not move for terminal output. Fetch on staleness.
        return elapsed >= maxStaleness ? .fetch : .skip
    }
}

public struct RefreshCoordinator: Sendable {
    public private(set) var states: [String: PaneRefreshState] = [:]
    public var policy: RefreshPolicy

    public init(policy: RefreshPolicy = RefreshPolicy()) {
        self.policy = policy
    }

    public mutating func plan(
        agents: [AgentInfo],
        focusedPane: String?,
        now: Date
    ) -> [String: RefreshAction] {
        var plan: [String: RefreshAction] = [:]
        for agent in agents {
            var state = states[agent.paneID] ?? PaneRefreshState()
            let action = policy.decide(
                agent: agent,
                state: state,
                focused: agent.paneID == focusedPane,
                now: now
            )
            // Remember an observed change that we chose not to act on, so it is
            // still fetched once the floor clears or the reader returns.
            if PaneGeneration(agent) != state.lastSeen, action != .fetch {
                state.pendingChange = true
            }
            state.lastSeen = PaneGeneration(agent)
            states[agent.paneID] = state
            plan[agent.paneID] = action
        }
        let live = Set(agents.map(\.paneID))
        states = states.filter { live.contains($0.key) }
        return plan
    }

    /// Record that a fetch completed. Clears any pending-change marker, since the
    /// screen the reader is now looking at reflects that change.
    public mutating func recordFetch(pane: String, generation: PaneGeneration, at now: Date) {
        var state = states[pane] ?? PaneRefreshState()
        state.lastSeen = generation
        state.lastFetch = now
        state.pendingChange = false
        states[pane] = state
    }

    public mutating func setReaderScrolledAway(pane: String, _ away: Bool) {
        var state = states[pane] ?? PaneRefreshState()
        state.readerScrolledAway = away
        states[pane] = state
    }

    /// Drop all cached generations, forcing a full resync.
    ///
    /// Required on foreground: herdr's EventHub is a 512-entry ring with no gap
    /// signal, so a backgrounded client falls off the back and sequence
    /// continuity cannot be trusted afterwards.
    public mutating func invalidateAll() {
        for key in states.keys {
            states[key]?.lastSeen = PaneGeneration()
            states[key]?.lastFetch = nil
            states[key]?.pendingChange = false
        }
    }

    public func state(for pane: String) -> PaneRefreshState? { states[pane] }
}
