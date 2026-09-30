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

/// Whether a terminal may keep sending PTY sizes.
///
/// A host older than guest resizing refuses a guest's `pane.set_pty_size` with
/// `guest_forbidden`, and it will refuse every later one the same way. The first such answer
/// closes the gate for the rest of the session, so the terminal falls back to fitting the
/// stream's grid to its width instead of re-proposing on every layout, font change and lease
/// renewal. Any other failure (a paused agent, a resize that raced the guest's stream open, a
/// dropped connection) leaves it open, and the next proposal or renewal tries again.
///
/// A reference, shared by everything that sends for one view: a resize queued before the
/// refusal landed (the release on teardown, say) must see it at the moment it would send.
public final class PTYResizeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    public init() {}

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Records a failed `pane.set_pty_size`. Returns true only for the failure that closed
    /// the gate.
    @discardableResult
    public func noteFailure(_ error: Error) -> Bool {
        guard GuestError.classify(error) == .forbidden else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }

    /// Sends one resize unless the gate is closed, deciding at send time rather than when the
    /// resize was queued. Returns nil, sending nothing, once closed. A failure is recorded
    /// before it is rethrown, so a resize awaiting this one already sees the refusal: the
    /// host is asked, and refuses, exactly once.
    public func send(_ resize: () async throws -> PanePtySize) async throws -> PanePtySize? {
        guard !isClosed else { return nil }
        do {
            return try await resize()
        } catch {
            noteFailure(error)
            throw error
        }
    }
}
