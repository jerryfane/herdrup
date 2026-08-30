import XCTest

/// Regression receipt for the macOS/iPad agent-list freeze.
///
/// The mock replaces the roster every 50 ms, moving rows between sections and changing
/// the row count. Repeated swipes therefore cross many refreshes. The test then searches
/// for a sentinel that exists only in the settled final snapshot. Reaching and rendering
/// that result proves both that the UI stayed responsive and that the newest deferred
/// refresh was applied after scrolling stopped.
final class AgentRosterScrollTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRosterStaysResponsiveWhileRefreshesReorderRows() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "rosterstress"
        app.launch()

        let scroll = app.scrollViews["agent-roster-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "agent roster scroll view did not appear")
        XCTAssertTrue(app.staticTexts["stress-agent-000"].waitForExistence(timeout: 5),
                      "stress roster did not load")

        for _ in 0..<18 {
            scroll.swipeUp()
        }

        // Return to the top without involving the software keyboard. A tap made while
        // momentum is still settling can be consumed only to stop deceleration, leaving
        // a text field visible but unfocused and making `typeText` fail for the wrong
        // reason. The final snapshot pins its sentinel first, so reaching that row is a
        // direct receipt for both continued gesture handling and deferred-state catch-up.
        for _ in 0..<18 {
            scroll.swipeDown()
        }

        XCTAssertTrue(app.staticTexts["roster-refresh-final"].waitForExistence(timeout: 8),
                      "newest deferred roster was not applied after scrolling became idle")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "roster-responsive-after-refresh-stress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
