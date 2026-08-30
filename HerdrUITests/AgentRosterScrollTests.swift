import XCTest

/// Regression receipt for the macOS/iPad agent-list freeze.
///
/// The mock replaces the roster every 50 ms, moving rows between sections and changing
/// the row count. A fixed top/bottom marker pair proves that swipes really displaced
/// content in both directions while that refresh workload continued. The pure
/// AgentRosterRefreshState tests separately pin deferred-snapshot promotion exactly.
final class AgentRosterScrollTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// How long a hittability change may take, DERIVED FROM THE REORDER CADENCE rather
    /// than from whatever makes CI green.
    ///
    /// The stress mock republishes the roster every 50 ms, so a settle costs a small
    /// number of poll cycles. One second is twenty of them — ample headroom on a loaded
    /// runner, and still tight in absolute terms: a roster that cannot bring a row it
    /// has already published into the viewport within a second is exactly the
    /// unresponsiveness this test exists to catch.
    ///
    /// A more generous bound would be safer against flakes and WORSE as a test: five
    /// seconds would pass a roster that is visibly janky to a human.
    private let rosterSettleTimeout: TimeInterval = 1.0

    func testRosterStaysResponsiveWhileRefreshesReorderRows() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "rosterstress"
        app.launch()

        let scroll = app.scrollViews["agent-roster-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "agent roster scroll view did not appear")
        // Query the actual row Buttons. Their Text children exist in the accessibility
        // tree but are not independently hittable because the parent owns the gesture.
        let topMarker = app.buttons["agent-row-stress:top"]
        let bottomMarker = app.buttons["agent-row-stress:bottom"]
        XCTAssertTrue(topMarker.waitForExistence(timeout: 5), "stress roster did not load")
        // WAIT for it, do not assert it instantly. This roster re-sorts every 50ms by
        // design: the driver's phase alternates each poll and all 80-odd rows change
        // section, which is the scenario the test exists to exercise. An instant
        // `isHittable` here races that loop.
        //
        // It used not to. Before the roster-refresh fix, `RosterStressDriver()` was
        // constructed inside `body`, so SwiftUI rebuilt it on every evaluation and its
        // call counter reset to 1 each time — the phase never advanced and the roster
        // never actually reordered. The test passed because nothing moved. Making the
        // driver stable is what turned this into a real stress, and this precondition
        // is what it exposed.
        //
        // Only the ASSUMPTION that the roster holds still is relaxed. The three
        // receipts below — top leaves, bottom arrives, top returns — are unchanged.
        // DIAGNOSTIC, DELIBERATELY WIDE. 1.0s — twenty of the mock's 50ms poll cycles —
        // was not enough on the runner, and that is the interesting result: either the
        // settle is merely slower than the cadence suggests, or the top row never
        // becomes reachable at all, which would mean the roster is genuinely
        // unresponsive under a load that rewrites every row twenty times a second.
        //
        // Those need different answers — a larger bound versus a real finding about the
        // fix — and raising the number to get green would destroy the evidence that
        // tells them apart. So this measures instead of asserting: it reports WHEN
        // hittability arrived, or that it never did within a bound far past any
        // plausible settle, and names what else was reachable at that moment.
        let topSettle = topMarker.timeToHittable(timeout: 10.0)
        let bottomReachable = bottomMarker.waitForHittable(timeout: 0.5)
        XCTAssertNotNil(
            topSettle,
            "top marker NEVER became hittable within 10s. bottom marker hittable at that "
                + "point: \(bottomReachable). scroll view exists: \(scroll.exists). "
                + "If bottom is reachable and top is not, the roster is scrolled away "
                + "from the top rather than frozen; if neither is reachable, the roster "
                + "is not responding to layout at all."
        )
        if let topSettle {
            XCTAssertLessThan(
                topSettle,
                rosterSettleTimeout,
                "top marker became hittable only after \(topSettle)s, beyond the \(rosterSettleTimeout)s "
                    + "budget derived from the 50ms reorder cadence. The roster settles, "
                    + "but far slower than the cadence implies — the bound is wrong, or "
                    + "the settle is."
            )
        }

        for _ in 0..<18 {
            scroll.swipeUp()
        }
        XCTAssertTrue(
            topMarker.waitForNotHittable(timeout: rosterSettleTimeout),
            "upward swipes did not move the initial row off-screen within \(rosterSettleTimeout)s"
        )
        XCTAssertTrue(bottomMarker.waitForExistence(timeout: 3), "bottom marker was absent from the roster")
        XCTAssertTrue(
            bottomMarker.waitForHittable(timeout: rosterSettleTimeout),
            "upward swipes did not reach different visible content within \(rosterSettleTimeout)s"
        )

        // Return to the top without involving the software keyboard. A tap made while
        // momentum is still settling can be consumed only to stop deceleration, leaving
        // a text field visible but unfocused and making `typeText` fail for the wrong
        // reason. The final snapshot pins its sentinel first, so reaching that row is a
        // direct receipt for both continued gesture handling and deferred-state catch-up.
        for _ in 0..<18 {
            scroll.swipeDown()
        }

        XCTAssertTrue(
            topMarker.waitForHittable(timeout: rosterSettleTimeout),
            "downward swipes did not return to the original visible content within \(rosterSettleTimeout)s"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "roster-responsive-after-refresh-stress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Hittability under a continuously re-sorting roster is a state to WAIT for, not to
/// sample. XCTest has `waitForExistence` but no hittable equivalent, so these poll it
/// the same way — bounded, and failing by returning false so the caller's message,
/// which names the bound, is the one that shows up.
///
/// THEY POLL HITTABILITY, NOT EXISTENCE, and the distinction is the whole point.
/// Existence is satisfied by an element that is in the hierarchy but scrolled
/// off-screen or occluded — precisely the state the original assertion was written to
/// rule out. A bounded wait on existence would be green against a roster that never
/// becomes reachable at all.
extension XCUIElement {

    /// How long until this element became hittable, or nil if it never did.
    ///
    /// Returns the measurement rather than a verdict, so a failure can say WHICH of
    /// "slower than expected" and "never" happened. Those need different fixes and an
    /// assertion collapses them into the same red.
    func timeToHittable(timeout: TimeInterval) -> TimeInterval? {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        repeat {
            if isHittable { return Date().timeIntervalSince(started) }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.1)
        } while Date() < deadline
        return isHittable ? Date().timeIntervalSince(started) : nil
    }

    func waitForHittable(timeout: TimeInterval) -> Bool {
        waitForHittability(timeout: timeout, expected: true)
    }

    func waitForNotHittable(timeout: TimeInterval) -> Bool {
        waitForHittability(timeout: timeout, expected: false)
    }

    private func waitForHittability(timeout: TimeInterval, expected: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isHittable == expected { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.1)
        } while Date() < deadline
        return isHittable == expected
    }
}
