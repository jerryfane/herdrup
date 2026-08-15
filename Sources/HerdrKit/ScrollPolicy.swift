import Foundation

/// Decides what a finger-drag on a terminal pane should DO.
///
/// ## Why this is a type and not a `guard`
///
/// The app used to decide this inline at the gesture site with one expression:
///
/// ```swift
/// guard term.isCurrentBufferAlternate || term.mouseMode != .off else { return }
/// ```
///
/// That line is not wrong because it is terse. It is wrong because it is evaluated in
/// the one place that structurally cannot see half of the inputs. The four facts needed
/// to classify a pane live in four different layers:
///
/// | fact | only knowable from |
/// |---|---|
/// | alternate buffer, mouse reporting | the SwiftTerm emulator, on the phone |
/// | whether a native scroll range exists right now | the terminal view's content size |
/// | whether history exists AT THE SOURCE | `pane.get` → `scroll.max_offset_from_bottom` |
/// | whether the pane hosts an agent | `AgentInfo`, in SwiftUI |
///
/// The daemon cannot supply the first pair — the API schema contains no `mouse`,
/// `alternate` or `alt_screen` key anywhere — and the emulator cannot supply the second
/// pair. So classification has to be a function of a value assembled from both sides,
/// which is what this file is.
///
/// The old expression also silently encoded THREE different policies (hands-off for a
/// shell, drive-the-program for a TUI, suppress-and-drive for a mouse-mode agent) while
/// naming none of them — and a fourth case fell into the "shell" bucket by accident.
///
/// ## The fourth case
///
/// Measured on a live box: a Claude Code session spawned as a BACKGROUND session
/// (`CLAUDE_CODE_SESSION_KIND=bg`) redraws in place and never scrolls anything out, so
/// **no history is ever retained** — not by the terminal, not by the daemon:
///
/// ```text
/// bg-spawned pane          revision 3373   max_offset_from_bottom 0      recent(400) -> 34 lines (= the viewport)
/// interactive pane         revision 2267   max_offset_from_bottom 2639   recent(400) -> 399 lines
/// ```
///
/// Both had identical 34x49 PTY geometry, so geometry is not the cause. Such a pane has
/// no scrollback for the native pan to move AND fell through the old guard's early
/// return, so the drag did precisely nothing. `.inert` finally names that state.
public enum ScrollPolicy: Equatable, Sendable {
    /// Hand off to the terminal view's own scroll view. This is a DEFENDED hands-off
    /// state, not an absence of behavior: overriding `contentOffset` or claiming the
    /// scroll delegate is exactly what dead-locked scrolling across ~7 TestFlight builds
    /// on SwiftTerm 1.11.2. Naming it is half the point of this enum.
    case nativePan
    /// Suppress the native pan for the drag and emit SGR wheel events to the program,
    /// which owns its own viewport.
    case driveWheel
    /// Emit Up/Down to the program. Only ever correct where a cursor-key reader is
    /// expected — never for a plain shell, which reads them as history navigation.
    case driveArrows
    /// Nothing exists to scroll and nothing is safe to send. The honest state for a pane
    /// that redraws in place: a dead gesture that can be EXPLAINED beats a fake one.
    case inert
}

/// Everything needed to classify one pane, assembled from both sides of the
/// UIViewRepresentable boundary.
///
/// Deliberately plain scalars: this type lives in HerdrKit, which contains no UIKit and
/// no SwiftTerm so it builds and unit-tests on Linux. Passing `SwiftTerm.MouseMode` or a
/// `CGFloat` here would drag the whole emulator into a package that must stay portable.
public struct ScrollContext: Equatable, Sendable {
    /// The emulator is on the alternate screen (a full-screen TUI: vim, htop, less).
    ///
    /// LOWER BOUND, not ground truth — see `mouseReporting`.
    public var isAlternateBuffer: Bool
    /// The program enabled mouse reporting (DECSET 1000/1006) and therefore captures the
    /// wheel to scroll its own viewport.
    ///
    /// ## This is a LOWER BOUND on reality
    ///
    /// Measured: herdr's rendered screen — what both the connect-time backfill and the
    /// stream's `reset` keyframe carry — contains **no private-mode sequences at all**.
    /// A 1948-byte capture of a live pane held 65 `ESC[` sequences (SGR colour, cursor
    /// addressing) and zero `ESC[?…h/l`.
    ///
    /// So immediately after every connect this reads `false` for EVERY pane, whatever the
    /// program is actually doing, and only becomes true if the program re-emits DECSET
    /// while the app happens to be attached. A pane already sitting in a full-screen TUI
    /// when the reader opens it therefore looks like a plain shell.
    ///
    /// This is why `decide` does not rest on the mode bits: they are opportunistic
    /// positives, never proof of absence. `serverScrollbackRows` is the reliable signal,
    /// and the fix for the underlying gap belongs in herdr (carry the modes on the
    /// `stream_started` ack, or prepend mode-restoring bytes to the reset frame).
    public var mouseReporting: Bool
    /// `contentSize.height - bounds.height`, clamped at zero — how far the native scroll
    /// view could actually move right now.
    public var nativeRangePoints: Double
    /// Whether an agent (rather than a bare shell) is running in this pane.
    public var hostsAgent: Bool
    /// The agent kind, when known ("claude", "codex", ...). Carried for diagnostics and
    /// future per-kind rules; `decide` deliberately does not branch on it today, because
    /// a rule keyed to a kind STRING silently misclassifies every kind added later.
    public var agentKind: String?
    /// Rows of scrollback the SERVER holds for this pane, from
    /// `pane.get` → `scroll.max_offset_from_bottom`. `nil` means unknown — an older
    /// server, a failed probe, or simply not fetched yet.
    public var serverScrollbackRows: Int?

    public init(
        isAlternateBuffer: Bool = false,
        mouseReporting: Bool = false,
        nativeRangePoints: Double = 0,
        hostsAgent: Bool = false,
        agentKind: String? = nil,
        serverScrollbackRows: Int? = nil
    ) {
        self.isAlternateBuffer = isAlternateBuffer
        self.mouseReporting = mouseReporting
        self.nativeRangePoints = max(0, nativeRangePoints)
        self.hostsAgent = hostsAgent
        self.agentKind = agentKind
        self.serverScrollbackRows = serverScrollbackRows
    }

    /// The traits a pane is assumed to have before anything has been measured: no agent,
    /// no server evidence. Classifies as `.nativePan` or `.inert` and never drives, so a
    /// pane behaves exactly as it did before this type existed until real values arrive.
    public static let unknown = ScrollContext()
}

extension ScrollPolicy {
    /// Sub-pixel floor for "the native scroll view can actually move". A range of a
    /// fraction of a point is not a scrollable pane, and comparing a `Double` to an
    /// exact `0` would let layout rounding decide policy.
    static let nativeRangeEpsilon: Double = 0.5

    /// Whether a historyless AGENT pane may be driven with ARROW KEYS.
    ///
    /// **`false`, and the measurement says keep it that way.**
    ///
    /// Arrows into an agent are not free. Claude Code reads Up/Down in its composer as
    /// prompt-history recall — a draft mutation, and together with the reply bar's Return
    /// keycap a path to submitting a recalled prompt. Driving a pane with them is only
    /// defensible if the pane demonstrably scrolls in response.
    ///
    /// It does not. Two independent measurements on a live background pane:
    ///
    /// 1. Fifteen seconds of its byte stream carried `ESC[?2026h/l` (synchronised output)
    ///    and `ESC[?25h/l` (cursor) and nothing else — no `?1000`, `?1002`, `?1003`,
    ///    `?1006`, `?1049`. It repaints cells in place with absolute cursor addressing and
    ///    never emits a line feed that would scroll, which is exactly why its
    ///    `max_offset_from_bottom` is 0.
    /// 2. In the Claude Code binary, `ESC[?1000h` and `ESC[?1006h` each occur once, and
    ///    the only path that reaches them is `enterAlternateScreen()`. Mouse tracking
    ///    exists solely on the full-screen path, which a background session never enters.
    ///
    /// So a background pane has no scrollback, no mouse reporting, and no internal
    /// viewport to move — while its stdin is a live agent input channel. There is nothing
    /// to reveal and nothing safe to send. The honest classification is `.inert`, and the
    /// product fix is to SAY so rather than to invent a gesture.
    ///
    /// Should some future agent kind turn out to scroll on cursor keys, prove it against a
    /// THROWAWAY pane — never a live seat — before flipping this:
    ///
    /// ```bash
    /// herdr pane read --source visible <scratch> > before.txt
    /// herdr pane send-text <scratch> $'\e[A'
    /// herdr pane read --source visible <scratch> > after.txt; diff before.txt after.txt
    /// herdr agent get <scratch>   # and confirm nothing landed in the composer
    /// ```
    ///
    /// Only ever consulted for a MOUSE-OFF pane: a pane that does report the mouse is
    /// already routed to `.driveWheel` above and never reaches this constant.
    public static let drivesHistorylessAgentWithArrows = false

    /// Classify a pane. Total, pure, and order-sensitive — the ordering IS the policy.
    ///
    /// - Parameter arrowsAreSafeForHistorylessAgent: overridable only so both branches
    ///   are reachable from tests. Production callers take the default.
    public static func decide(
        _ context: ScrollContext,
        arrowsAreSafeForHistorylessAgent: Bool = ScrollPolicy.drivesHistorylessAgentWithArrows
    ) -> ScrollPolicy {
        // A full-screen TUI keeps no scrollback of its own, so there is never anything to
        // pan natively — the program must be driven. Wheel if it asked for the mouse,
        // arrows otherwise (vim and less both scroll on cursor keys).
        if context.isAlternateBuffer {
            return context.mouseReporting ? .driveWheel : .driveArrows
        }

        // Mouse reporting on a NORMAL buffer means the program captures the wheel to move
        // its own viewport (Claude Code's fullscreen renderer does this). It must win over
        // the native-range check below: such a pane often ALSO has real scrollback, and
        // panning that locally would move the wrong thing.
        if context.mouseReporting {
            return .driveWheel
        }

        // A pane with somewhere to go scrolls itself. This is the common case — a shell
        // with history — and it must stay on the library's own path.
        if context.nativeRangePoints > nativeRangeEpsilon {
            return .nativePan
        }

        // From here the pane has no local range. Whether that means "there is no history"
        // or "the history has not arrived yet" is NOT knowable locally, and the difference
        // decides whether it is safe to send bytes.
        guard let serverRows = context.serverScrollbackRows else {
            // No evidence. Never drive a pane we know nothing about.
            return .inert
        }

        // THE TRAP THIS GUARD EXISTS FOR.
        //
        // The connect-time scrollback backfill is raced against a SIX-SECOND timeout and
        // only lands at the first reset. For up to six seconds after every connect, an
        // INTERACTIVE Claude pane holding 2639 rows of real history has
        // `contentSize <= bounds` locally and looks exactly like a historyless one. A
        // policy keyed on local range alone fires arrow keys into that pane's composer
        // precisely when it looks emptiest. The server's count is the only thing that
        // separates the two states.
        if serverRows > 0 {
            return .nativePan
        }

        // Genuinely no history anywhere: local range zero AND the server holds nothing.
        // A bare shell in this state must still be left alone — Up/Down would walk its
        // command history — so driving is gated on hosting an agent AND on the arrows
        // question having actually been measured.
        if context.hostsAgent && arrowsAreSafeForHistorylessAgent {
            return .driveArrows
        }
        return .inert
    }
}
