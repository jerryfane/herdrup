import Foundation

/// Converts finger travel into scroll ticks for a program that owns its own viewport.
///
/// ## Why pacing is by TIME and not by callback
///
/// The old inline version capped emission at one tick per gesture callback for a stated
/// and correct reason: Claude Code derives its wheel ACCELERATION from the gap between
/// wheel events, so several events arriving together trip its fast cap (~36 lines/tick)
/// and produce jumpy leaps, while well-spaced events stay in a gentle ~3-line regime.
///
/// But a per-callback cap is the wrong control variable. What the program actually reads
/// is the inter-arrival gap at the far end of an SSH round trip, and the send queue
/// deliberately coalesces everything accrued during an in-flight `send_text` into the next
/// batch. So under latency `L` at drag rate `r` the program receives `ceil(r·L)` events
/// with ~zero gap between them — exactly the condition the cap existed to prevent, and
/// worse precisely when the link is slow. That is why the jumpiness was intermittent
/// rather than constant: it tracked the network, not the finger.
///
/// This type makes the gap the explicit, enforced quantity. Emission is refused inside
/// `minGap` regardless of how fast the callbacks arrive, so spacing no longer depends on
/// gesture frequency or link speed.
///
/// ## What must not regress
///
/// Two shipped fixes are preserved verbatim, and their tests are the regression locks:
///
/// - **consume-only-what-was-emitted** — a fast drag must not be truncated, so ticks that
///   the cap withheld stay in the carry rather than being discarded.
/// - **bounded carry** — the carry is clamped to `maxCarryLines`, so a direction reversal
///   inside a single touch cannot keep firing the old direction for many frames, and a
///   flick cannot bank an unbounded backlog that keeps scrolling after lift-off.
///
/// The `.arrows` profile reproduces the previous arithmetic exactly (cap 4, no gap), so
/// alt-screen TUIs driven by cursor keys are numerically unchanged.
public struct ScrollPacer: Equatable, Sendable {

    /// Pacing constants for one emission channel.
    public struct Profile: Equatable, Sendable {
        /// Minimum wall-clock spacing between emissions. Zero disables time pacing.
        public let minGap: TimeInterval
        /// Most ticks a single emission may carry.
        public let maxTicksPerEmission: Int
        /// Carry bound, in lines.
        public let maxCarryLines: Double

        public init(minGap: TimeInterval, maxTicksPerEmission: Int, maxCarryLines: Double) {
            self.minGap = minGap
            self.maxTicksPerEmission = max(1, maxTicksPerEmission)
            self.maxCarryLines = max(1, maxCarryLines)
        }

        /// SGR wheel into a program that accelerates off event spacing.
        ///
        /// One tick per emission with an enforced gap, so the program sees a genuine
        /// interval on every event and stays in its gentle regime deterministically
        /// instead of accidentally. 30 ms is roughly two display frames — fast enough to
        /// feel continuous, slow enough to stay well clear of the fast-cap threshold.
        ///
        /// Worth re-measuring against a real agent if the feel is still off: send single
        /// wheel events at 16/33/50/100 ms spacings and record lines moved per event, then
        /// take the largest spacing that stays gentle.
        public static let wheel = Profile(minGap: 0.030, maxTicksPerEmission: 1, maxCarryLines: 1)

        /// Cursor keys into a program that does NOT accelerate (vim, less). Unpaced, four
        /// per emission — the previous behaviour, preserved exactly.
        public static let arrows = Profile(minGap: 0, maxTicksPerEmission: 4, maxCarryLines: 4)
    }

    /// One batch of ticks to send.
    public struct Emission: Equatable, Sendable {
        /// `true` scrolls toward OLDER content (drag down / wheel-up).
        public let up: Bool
        /// How many ticks, always >= 1.
        public let count: Int
    }

    public private(set) var profile: Profile
    /// Un-emitted finger travel, in points.
    public private(set) var carry: Double = 0
    /// When the last emission went out; `nil` until the first one.
    public private(set) var lastEmission: Date?

    public init(profile: Profile) {
        self.profile = profile
    }

    /// Switch channels mid-life (the emulator's mode can change under a live pane),
    /// dropping any carry so travel accumulated for one channel cannot leak into another.
    public mutating func setProfile(_ profile: Profile) {
        guard profile != self.profile else { return }
        self.profile = profile
        carry = 0
    }

    /// Forget all pending travel — on gesture end, teardown, or a pane leaving the
    /// foreground, so a resumed drag never replays stale distance.
    public mutating func reset() {
        carry = 0
        lastEmission = nil
    }

    /// Feed one gesture callback's vertical travel and get back what to send, if anything.
    ///
    /// - Parameters:
    ///   - dy: vertical translation since the last call, in points. Positive is a downward
    ///     drag, which reveals OLDER content.
    ///   - lineHeight: height of one terminal row, in points.
    ///   - now: current time; injected so pacing is testable without sleeping.
    public mutating func drag(dy: Double, lineHeight: Double, now: Date) -> Emission? {
        // A zero or negative line height would divide by zero and synthesise an unbounded
        // tick count. Geometry this broken means layout has not settled; refuse to guess.
        let line = max(1, lineHeight)

        carry += dy
        let ticks = Int(carry / line)
        guard ticks != 0 else {
            clampCarry(line: line)
            return nil
        }

        // Time gate. The carry is kept — and clamped — so a stall neither loses the
        // reader's travel nor lets it accumulate into a burst that replays on resume.
        if let last = lastEmission, profile.minGap > 0, now.timeIntervalSince(last) < profile.minGap {
            clampCarry(line: line)
            return nil
        }

        let up = ticks > 0
        let count = min(abs(ticks), profile.maxTicksPerEmission)
        // Consume ONLY what is emitted; the rest carries so a fast drag is not truncated.
        carry -= Double(up ? 1 : -1) * Double(count) * line
        clampCarry(line: line)
        lastEmission = now
        return Emission(up: up, count: count)
    }

    /// Bound the carry to one profile's worth of lines. Without this, a direction reversal
    /// inside one touch keeps firing the old direction for many frames (it scrolls
    /// backwards under the finger), and a flick banks a backlog that keeps scrolling long
    /// after lift-off.
    private mutating func clampCarry(line: Double) {
        let maxCarry = profile.maxCarryLines * line
        carry = min(max(carry, -maxCarry), maxCarry)
    }
}
