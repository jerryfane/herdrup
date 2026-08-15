import XCTest
@testable import HerdrKit

/// The classification table for `ScrollPolicy.decide`.
///
/// Each case names the pane shape it protects and, where it locks a specific defect, the
/// mutation that must make it fail. `decide` is pure, so this suite runs on Linux without
/// a simulator — which matters because the XCUITest receipts need a Mac and therefore
/// cannot gate a pure-logic regression.
final class ScrollPolicyTests: XCTestCase {

    // MARK: the three shapes that already worked

    /// A plain shell with retained scrollback stays on SwiftTerm's own scroll view.
    /// Taking this path away is what dead-locked scrolling across ~7 TestFlight builds.
    func testPlainShellWithHistoryPansNatively() {
        let c = ScrollContext(nativeRangePoints: 800, hostsAgent: false, serverScrollbackRows: 1200)
        XCTAssertEqual(ScrollPolicy.decide(c), .nativePan)
    }

    /// A full-screen TUI without mouse reporting (vim, less) keeps no scrollback of its
    /// own, so the program has to be driven — with cursor keys, which it reads as scroll.
    func testAlternateScreenWithoutMouseDrivesArrows() {
        let c = ScrollContext(isAlternateBuffer: true, mouseReporting: false)
        XCTAssertEqual(ScrollPolicy.decide(c), .driveArrows)
    }

    /// The same TUI once it asks for the mouse (htop) takes wheel events instead.
    func testAlternateScreenWithMouseDrivesWheel() {
        let c = ScrollContext(isAlternateBuffer: true, mouseReporting: true)
        XCTAssertEqual(ScrollPolicy.decide(c), .driveWheel)
    }

    /// Claude Code's full-screen renderer sits on the NORMAL buffer with mouse reporting
    /// on, and captures the wheel to move its own viewport.
    func testMouseOnNormalBufferDrivesWheel() {
        let c = ScrollContext(mouseReporting: true, hostsAgent: true, agentKind: "claude")
        XCTAssertEqual(ScrollPolicy.decide(c), .driveWheel)
    }

    /// ORDERING TEST. Such a pane usually ALSO has real scrollback, so a native range is
    /// present too — but panning it locally would move the wrong thing while the program
    /// owns the wheel. Mouse reporting must be checked before the native-range branch.
    ///
    /// Mutation: moving the `nativeRangePoints` check above the `mouseReporting` check
    /// must fail here.
    func testMouseReportingBeatsAnAvailableNativeRange() {
        let c = ScrollContext(mouseReporting: true, nativeRangePoints: 900,
                              hostsAgent: true, agentKind: "claude", serverScrollbackRows: 2639)
        XCTAssertEqual(ScrollPolicy.decide(c), .driveWheel)
    }

    // MARK: the invariant

    /// THE SAFETY INVARIANT. A historyless plain SHELL must never be driven: it reads
    /// Up/Down as command-history navigation, so a stray arrow rewrites the user's command
    /// line. Before this type existed the property was emergent — an early return in the
    /// gesture handler plus an if/else 50 lines away, with the shell case never named.
    ///
    /// Mutation: dropping `hostsAgent` from the final condition must fail here.
    func testHistorylessPlainShellIsInertNeverDriven() {
        let c = ScrollContext(nativeRangePoints: 0, hostsAgent: false, serverScrollbackRows: 0)
        XCTAssertEqual(ScrollPolicy.decide(c), .inert)
        // ...and stays inert even if the arrows question is ever answered "safe",
        // because that answer is about AGENT panes only.
        XCTAssertEqual(ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: true), .inert)
    }

    /// Fail-safe on absent evidence: a pane we know nothing about never receives bytes.
    /// `serverScrollbackRows == nil` means an older server, a failed probe, or simply a
    /// value that has not arrived yet.
    ///
    /// Mutation: `serverScrollbackRows ?? 0` must fail here.
    func testUnknownServerHistoryIsInertNotDriven() {
        let c = ScrollContext(nativeRangePoints: 0, hostsAgent: true,
                              agentKind: "claude", serverScrollbackRows: nil)
        XCTAssertEqual(ScrollPolicy.decide(c), .inert)
    }

    /// THE TRAP. The connect-time backfill is raced against a SIX-SECOND timeout and only
    /// lands at the first reset. For up to six seconds after every connect an INTERACTIVE
    /// Claude pane holding 2639 rows of real history has `contentSize <= bounds` locally
    /// and is indistinguishable from a historyless one by local state alone. A policy
    /// keyed on local range would fire input into that pane's composer exactly when it
    /// looks emptiest.
    ///
    /// Mutation: deleting the `serverRows > 0 -> .nativePan` branch must fail here.
    func testInteractivePaneAwaitingBackfillIsNotDriven() {
        let c = ScrollContext(nativeRangePoints: 0, hostsAgent: true,
                              agentKind: "claude", serverScrollbackRows: 2639)
        XCTAssertEqual(ScrollPolicy.decide(c), .nativePan)
        XCTAssertEqual(ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: true), .nativePan)
    }

    // MARK: the background pane — the case this type was added for

    /// THE MEASURED CASE. A background-spawned Claude session: repaints in place, so no
    /// scrollback exists locally OR on the server (`max_offset_from_bottom == 0`,
    /// `recent --lines 400` returns exactly the 34-row viewport), and no mouse reporting
    /// (its stream carries only `?2026` and `?25`; the binary reaches `?1000h`/`?1006h`
    /// only from `enterAlternateScreen()`, which a bg session never enters).
    ///
    /// Nothing to reveal, nothing safe to send: `.inert`, and the UI owes the reader an
    /// explanation rather than a frozen slab.
    func testBackgroundAgentPaneIsInert() {
        let c = ScrollContext(isAlternateBuffer: false, mouseReporting: false,
                              nativeRangePoints: 0, hostsAgent: true,
                              agentKind: "claude", serverScrollbackRows: 0)
        XCTAssertEqual(ScrollPolicy.decide(c), .inert)
    }

    /// The escape hatch stays reachable: if some agent kind is ever PROVEN to scroll on
    /// cursor keys, one constant flips and this is what it buys. Kept tested so the branch
    /// cannot rot into dead code.
    func testBackgroundAgentPaneDrivesArrowsOnceProvenSafe() {
        let c = ScrollContext(nativeRangePoints: 0, hostsAgent: true,
                              agentKind: "claude", serverScrollbackRows: 0)
        XCTAssertEqual(ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: true), .driveArrows)
    }

    /// Were a background pane ever to enable mouse reporting, it is already handled
    /// upstream and never reaches the arrows question.
    func testHistorylessAgentWithMouseDrivesWheelRegardlessOfArrowSafety() {
        let c = ScrollContext(mouseReporting: true, nativeRangePoints: 0, hostsAgent: true,
                              agentKind: "claude", serverScrollbackRows: 0)
        XCTAssertEqual(ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: false), .driveWheel)
    }

    // MARK: whole-table properties

    /// `.unknown` must classify as it did before this type existed: never driving. This is
    /// what lets the Coordinator adopt the policy as a pure refactor, before any real
    /// traits are threaded through.
    func testUnknownContextNeverDrives() {
        XCTAssertEqual(ScrollPolicy.decide(.unknown), .inert)
        var withRange = ScrollContext.unknown
        withRange.nativeRangePoints = 500
        XCTAssertEqual(ScrollPolicy.decide(withRange), .nativePan)
    }

    /// A negative range is meaningless geometry; the initialiser clamps it so layout
    /// rounding can never make a pane look scrollable.
    func testNegativeNativeRangeIsClampedNotTrusted() {
        let c = ScrollContext(nativeRangePoints: -40, hostsAgent: false, serverScrollbackRows: 0)
        XCTAssertEqual(c.nativeRangePoints, 0)
        XCTAssertEqual(ScrollPolicy.decide(c), .inert)
    }

    /// Sub-pixel range is not a scrollable pane. Without the epsilon, layout rounding
    /// decides policy.
    func testSubPixelRangeDoesNotCountAsScrollable() {
        let c = ScrollContext(nativeRangePoints: 0.25, hostsAgent: false, serverScrollbackRows: 0)
        XCTAssertEqual(ScrollPolicy.decide(c), .inert)
    }

    /// TOTALITY. Every boolean corner classifies, deterministically, and the two driving
    /// verdicts are never reached without a justification:
    ///  - `.driveWheel` requires mouse reporting (it emits SGR the program must have asked for)
    ///  - `.driveArrows` requires the alternate screen, or a proven-safe agent pane
    func testDecideIsTotalAndNeverDrivesWithoutJustification() {
        for alt in [false, true] {
            for mouse in [false, true] {
                for agent in [false, true] {
                    for safe in [false, true] {
                        for rows in [nil, 0, 2639] as [Int?] {
                            for range in [0.0, 900.0] {
                                let c = ScrollContext(
                                    isAlternateBuffer: alt, mouseReporting: mouse,
                                    nativeRangePoints: range, hostsAgent: agent,
                                    agentKind: agent ? "claude" : nil, serverScrollbackRows: rows)
                                let p = ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: safe)
                                XCTAssertEqual(p, ScrollPolicy.decide(c, arrowsAreSafeForHistorylessAgent: safe),
                                               "decide must be pure for \(c)")
                                if p == .driveWheel {
                                    XCTAssertTrue(mouse, "wheel emitted to a program that never asked for the mouse: \(c)")
                                }
                                if p == .driveArrows {
                                    XCTAssertTrue(alt || (agent && safe),
                                                  "arrows emitted without alt-screen or a proven-safe agent: \(c)")
                                    XCTAssertTrue(alt || agent,
                                                  "arrows emitted to a plain shell: \(c)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
