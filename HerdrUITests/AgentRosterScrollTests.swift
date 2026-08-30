import XCTest

/// Regression receipt for the macOS/iPad agent-list freeze.
///
/// The mock replaces the roster every 50 ms, moving rows between sections and changing
/// the row count. A fixed top/bottom marker pair proves that swipes really displaced
/// content in both directions while that refresh workload continued. The pure
/// AgentRosterRefreshState tests separately pin deferred-snapshot promotion exactly.
final class AgentRosterScrollTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRosterStaysResponsiveWhileRefreshesReorderRows() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "rosterstress"
        app.launch()

        let scroll = app.scrollViews["agent-roster-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "agent roster scroll view did not appear")
        let topMarker = app.staticTexts["scroll-top-marker"]
        let bottomMarker = app.staticTexts["scroll-bottom-marker"]
        XCTAssertTrue(topMarker.waitForExistence(timeout: 5), "stress roster did not load")
        XCTAssertTrue(topMarker.isHittable, "top marker did not begin in the visible viewport")

        for _ in 0..<18 {
            scroll.swipeUp()
        }
        XCTAssertFalse(topMarker.isHittable, "upward swipes did not move the initial row off-screen")
        XCTAssertTrue(bottomMarker.waitForExistence(timeout: 3), "bottom marker was absent from the roster")
        XCTAssertTrue(bottomMarker.isHittable, "upward swipes did not reach different visible content")

        // Return to the top without involving the software keyboard. A tap made while
        // momentum is still settling can be consumed only to stop deceleration, leaving
        // a text field visible but unfocused and making `typeText` fail for the wrong
        // reason. The final snapshot pins its sentinel first, so reaching that row is a
        // direct receipt for both continued gesture handling and deferred-state catch-up.
        for _ in 0..<18 {
            scroll.swipeDown()
        }

        XCTAssertTrue(topMarker.isHittable,
                      "downward swipes did not return to the original visible content")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "roster-responsive-after-refresh-stress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
