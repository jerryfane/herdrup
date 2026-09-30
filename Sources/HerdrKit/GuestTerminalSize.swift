import Foundation

/// A guest's terminal text size, and the terms on which a guest's terminal sizes the shared
/// PTY. A guest proposes the grid that fits their screen at their own text size, exactly as
/// the owner's app does; the host accepts `pane.set_pty_size` from a guest for the granted
/// pane only while the grant is live.
public enum GuestTerminalSize {
    /// The guest's own setting, persisted on the device and separate from the owner's
    /// `terminal.fontSize`: a phone can be both an owner and a guest.
    public static let storageKey = "guest.terminal.fontSize"
    public static let defaultPoints: Double = 12.5
    public static let range: ClosedRange<Double> = 9...24
    /// One tap of A− / A+.
    public static let step: Double = 1

    public static func clamped(_ points: Double) -> Double {
        min(max(points, range.lowerBound), range.upperBound)
    }

    /// The size after `taps` presses of A+ (positive) or A− (negative), within `range`.
    public static func stepped(_ points: Double, by taps: Int) -> Double {
        clamped(points + Double(taps) * step)
    }

    /// The lease each guest resize asks for. The host clamps a guest's `ttl_ms` to 1–60 s,
    /// so the owner's 5-minute lease would silently become 60 s.
    public static let leaseTTLMillis: UInt64 = 30_000
    /// How often a guest re-asserts its committed size: a third of the lease, so one
    /// missed renewal cannot let it lapse.
    public static let leaseRenewalNanos: UInt64 = 10_000_000_000
}

/// Whether a terminal may keep proposing PTY sizes.
///
/// A host older than guest resizing refuses a guest's `pane.set_pty_size` with
/// `guest_forbidden`, and it will refuse every later one the same way. The first such answer
/// closes the gate for the rest of the session, so the terminal falls back to fitting the
/// stream's grid to its width instead of re-proposing on every layout, font change and lease
/// renewal. Any other failure (a paused agent, a dropped connection) leaves it open.
public struct PTYResizeGate: Equatable, Sendable {
    public private(set) var isClosed = false

    public init() {}

    /// Records a failed `pane.set_pty_size`. Returns true only for the failure that closed
    /// the gate, so the caller reacts to the refusal exactly once.
    @discardableResult
    public mutating func noteFailure(_ error: Error) -> Bool {
        guard !isClosed, GuestError.classify(error) == .forbidden else { return false }
        isClosed = true
        return true
    }
}
