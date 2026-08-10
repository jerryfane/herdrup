import XCTest

/// Smoke test for the Gram page. Launches into the `gram` screenshot mock — a
/// canned owner-view `gram.list` (agent->owner messages, owner posts, an
/// unclaimed queue item, a grabbed one, a direct message) — and asserts the page
/// renders its title and a message, then attaches a screenshot for the CI
/// artifact / layout FYI. Unlike the scroll receipts this exercises no gesture;
/// it just proves GramView builds and renders the mock owner view.
final class GramTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testGramPageRenders() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()

        // The title renders once the view is up.
        XCTAssertTrue(app.staticTexts["Gram"].waitForExistence(timeout: 8),
                      "the Gram page title should render")

        // Give the mock gram.list a moment to load + lay out the rows.
        Thread.sleep(forTimeInterval: 2.0)

        // A canned agent->owner message's sender label should appear.
        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 5),
                      "an agent->owner message should render its sender")

        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "gram-page"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
