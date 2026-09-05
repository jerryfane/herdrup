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

    /// The search field filters the loaded inbox, and a filter that matches nothing says so
    /// instead of leaving a blank scroll that reads as an empty inbox.
    ///
    /// Strings are picked from the `gram` fixture (MockTransport.gramList): "Digest" appears in
    /// exactly one message (g1, from trend-scout), and "vetrina" is the sender label of a
    /// DIFFERENT message (g5) — so one label surviving while the other disappears is a receipt
    /// that rows were filtered, not merely re-laid-out.
    func testGramSearchFiltersTheInbox() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()

        // Both senders are present before any filter: the pre-state the filter acts on. Without
        // this the later disappearance would prove nothing (it could have never rendered).
        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 10),
                      "the unread agent->owner message should render before filtering")
        XCTAssertTrue(app.staticTexts["vetrina"].waitForExistence(timeout: 5),
                      "the second agent->owner message should render before filtering")

        let field = app.textFields["Search messages"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search field should be pinned above the list")
        field.tap()
        field.typeText("Digest")
        // Assert the FIELD took the text before asserting anything about the list: an unfocused
        // field would otherwise fail as "filtering is broken" when the real fault is the keyboard.
        XCTAssertEqual(field.value as? String, "Digest", "the search field did not take the typed text")

        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 3),
                      "the matching message should survive the filter")
        XCTAssertTrue(app.staticTexts["vetrina"].waitForNonExistence(timeout: 5),
                      "a message matching nothing in the search should be filtered out")

        // A filter that matches nothing: the "No matches" state, NOT a blank list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5),
                      "a filter matching no message should say so")

        // Clearing the field restores the full list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.staticTexts["vetrina"].waitForExistence(timeout: 5),
                      "clearing the search should bring the filtered-out messages back")
    }

    /// Read all marks the unread messages read: the button is present while something is unread
    /// and gone once the pass completes (it renders only for `unreadCount > 0`).
    ///
    /// Bounded retry, deliberately: the mock's `gram.list` is a CONSTANT that always reports g1
    /// unread, so the page's 6-second poll re-introduces the unread message and the button
    /// reappears. The receipt is that a tap drives it away at all — one attempt could sample the
    /// instant a poll lands. A failure here means no tap ever cleared the unread count.
    func testGramReadAllClearsTheUnreadCount() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()

        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 10),
                      "the Gram page should load the mock inbox")

        let readAll = app.buttons["Read all"]
        var cleared = false
        for _ in 0..<3 {
            // Up to two poll intervals: the row's own onAppear mark-read can clear the count
            // first, and the next poll restores it.
            guard readAll.waitForExistence(timeout: 14) else { continue }
            readAll.tap()
            if readAll.waitForNonExistence(timeout: 4) { cleared = true; break }
        }
        XCTAssertTrue(cleared, "tapping Read all should drive the unread count to zero")
    }
}
