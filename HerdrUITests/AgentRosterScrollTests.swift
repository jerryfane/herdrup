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

        let search = app.textFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), "app stopped responding after roster scrolling")
        search.tap()
        search.typeText("roster-refresh-final")

        XCTAssertTrue(app.staticTexts["roster-refresh-final"].waitForExistence(timeout: 8),
                      "newest deferred roster was not applied after scrolling became idle")
        XCTAssertFalse(app.staticTexts["no matches"].exists,
                       "search remained on an older roster after the scroll settled")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "roster-responsive-after-refresh-stress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
