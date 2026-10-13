import Foundation

/// The terms on which the owner's app claims a pane's PTY size.
///
/// herdr sizes a pane to the WIDEST live claim (`pane.set_pty_size` with `lock:true`, one per
/// viewer). A claim this device no longer needs keeps every other device viewing the same
/// agent at this device's width until it is released (`lock:false`) or expires on its TTL, plus
/// the daemon's 20 s shrink debounce. So the app releases when it goes to the background, a
/// hidden pane releases after `hiddenGraceNanos`, and the TTL only bounds a claim that could
/// not be released at all (a crash, a kill, a dropped network).
///
/// A guest's terms are separate: see `GuestTerminalSize`.
public enum TerminalSizeClaim {
    /// The daemon's accepted `ttl_ms` range (herdr `PTY_LEASE_TTL_MIN_MS` / `_MAX_MS`); a value
    /// outside it is clamped, not refused.
    public static let daemonTTLRangeMillis: ClosedRange<UInt64> = 1...86_400_000
    /// herdr's `PTY_SHRINK_DEBOUNCE`: an expired or released claim narrows the pane only after
    /// this long.
    public static let daemonShrinkDebounceMillis: UInt64 = 20_000

    /// The `ttl_ms` every `lock:true` asks for. Short, so a claim that could not be released
    /// stops pinning another device's width within about two minutes (TTL + shrink debounce)
    /// instead of the five minutes and twenty seconds the daemon's default allows.
    public static let leaseTTLMillis: UInt64 = 90_000
    /// How often the pane in front re-asserts its claim. Two renewals may be missed in a row
    /// and the third still lands 15 s before the claim expires (25 + 25 + 25 = 75 < 90), so
    /// timer drift or a busy main actor cannot let it lapse.
    public static let renewalNanos: UInt64 = 25_000_000_000
    /// The margin the third renewal must keep before expiry.
    public static let renewalMarginMillis: UInt64 = 10_000

    /// How long a hidden pane (another agent fronted, or the Gram or Settings tab) keeps its
    /// claim before releasing it. A quick switch away and back inside this window sends
    /// neither a release nor a changed size, so the agent is not made to redraw twice; a
    /// pane left hidden longer hands the width back to the other devices.
    public static let hiddenGraceNanos: UInt64 = 25_000_000_000

    /// The grace period, overridden by a test's `HERDR_CLAIM_GRACE_MS` when that is a whole
    /// number of milliseconds (`0` releases at once). Anything else keeps `hiddenGraceNanos`.
    public static func hiddenGraceNanos(overrideMillis raw: String?) -> UInt64 {
        guard let raw, let millis = UInt64(raw.trimmingCharacters(in: .whitespaces)),
              millis <= UInt64.max / 1_000_000 else { return hiddenGraceNanos }
        return millis * 1_000_000
    }
}
