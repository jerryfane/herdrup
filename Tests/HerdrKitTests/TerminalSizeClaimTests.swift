import XCTest
@testable import HerdrKit

final class TerminalSizeClaimTests: XCTestCase {

    /// A TTL outside the daemon's range is silently clamped, so the renewal arithmetic below
    /// would be reasoning about a lease the daemon never granted.
    func testTTLIsInsideTheDaemonsAcceptedRange() {
        XCTAssertTrue(TerminalSizeClaim.daemonTTLRangeMillis.contains(TerminalSizeClaim.leaseTTLMillis))
    }

    /// Two renewals may be missed in a row (a slow link, a busy main actor) and the third
    /// must still land with time to spare before the claim expires, or another device's width
    /// takes over mid-read. Equal to the TTL is not enough: it departs AT expiry.
    func testRenewalLeavesRoomForTwoMissedBeats() {
        let renewalMillis = TerminalSizeClaim.renewalNanos / 1_000_000
        XCTAssertGreaterThan(renewalMillis, 0)
        XCTAssertLessThanOrEqual(renewalMillis * 3 + TerminalSizeClaim.renewalMarginMillis,
                                 TerminalSizeClaim.leaseTTLMillis)
    }

    /// A claim that could not be released (crash, kill, network gone) must stop pinning the
    /// other devices well before the daemon default's 5 min 20 s.
    func testAnUnreleasedClaimStopsPinningWithinTwoMinutes() {
        let worstCase = TerminalSizeClaim.leaseTTLMillis + TerminalSizeClaim.daemonShrinkDebounceMillis
        XCTAssertLessThanOrEqual(worstCase, 120_000)
    }

    /// The hidden-pane release is the point of the grace period: a grace at or beyond the TTL
    /// means a hidden pane just lapses (it is not renewed), and a zero grace makes every quick
    /// agent switch release and re-claim, two redraws for nothing.
    func testHiddenGraceIsShortButNotZero() {
        let graceMillis = TerminalSizeClaim.hiddenGraceNanos / 1_000_000
        XCTAssertGreaterThanOrEqual(graceMillis, 10_000)
        XCTAssertLessThan(graceMillis, TerminalSizeClaim.leaseTTLMillis)
    }

    func testGraceOverrideTakesWholeMilliseconds() {
        XCTAssertEqual(TerminalSizeClaim.hiddenGraceNanos(overrideMillis: "1500"), 1_500_000_000)
        XCTAssertEqual(TerminalSizeClaim.hiddenGraceNanos(overrideMillis: " 2000 "), 2_000_000_000)
        XCTAssertEqual(TerminalSizeClaim.hiddenGraceNanos(overrideMillis: "0"), 0)
    }

    func testGraceOverrideIgnoresAnythingElse() {
        let standard = TerminalSizeClaim.hiddenGraceNanos
        for raw in [nil, "", "soon", "-5", "1.5", "99999999999999999999"] {
            XCTAssertEqual(TerminalSizeClaim.hiddenGraceNanos(overrideMillis: raw), standard, "\(raw ?? "nil")")
        }
    }
}
