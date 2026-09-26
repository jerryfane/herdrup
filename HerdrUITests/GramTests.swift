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

        // The search control must remain above the newest message and clickable.
        let toggle = app.buttons["gram-search"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the header should offer search")
        XCTAssertTrue(toggle.isHittable, "the newest message must not cover the search control")
        toggle.tap()

        let field = app.textFields["gram-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search button should reveal the search field")
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

        // CLOSING must also clear. A hidden field that is still filtering would leave the
        // list silently short with nothing on screen to explain it - the failure mode a
        // dismissible search box invites. Re-filter first so the close has work to undo.
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(field.exists, "closing should dismiss the field")
        XCTAssertTrue(app.staticTexts["vetrina"].waitForExistence(timeout: 5),
                      "closing search should restore the unfiltered list")
    }

    /// Read all marks the unread messages read: the button is present while something is unread
    /// and gone once the pass completes (it renders only for `unreadCount > 0`).
    ///
    /// The button's presence is only STABLE after the first poll, and the test waits for that
    /// deliberately: at launch the single unread message's own row marks itself read within a
    /// moment (`markReadIfNeeded` from `onAppear`), which drives the count to zero and removes
    /// the button — so a tap aimed at the launch-time button can miss. The mock's `gram.list` is
    /// a CONSTANT that always reports g1 unread, so the 6-second poll restores it, and because
    /// the row's identity is unchanged `onAppear` does not fire again: from then on the button
    /// stays up. The retry exists because the same poll also re-creates it a few seconds after a
    /// successful pass; each attempt guards `exists`/`isHittable` so a vanished button re-enters
    /// the loop instead of failing the test on an unrecoverable `tap()`.
    func testGramReadAllClearsTheUnreadCount() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()

        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 10),
                      "the Gram page should load the mock inbox")

        let readAll = app.buttons["Read all"]
        var cleared = false
        for _ in 0..<4 {
            // One poll interval plus slack, so this waits out the launch-time flip described
            // above rather than racing it.
            guard readAll.waitForExistence(timeout: 14), readAll.isHittable else {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            readAll.tap()
            if readAll.waitForNonExistence(timeout: 4) { cleared = true; break }
        }
        XCTAssertTrue(cleared, "tapping Read all should drive the unread count to zero")
    }

    /// Reported on TestFlight 170: the keyboard could not be dismissed from the composer.
    /// Whenever a full software keyboard is on screen the composer must offer the button,
    /// and tapping it must put the keyboard away.
    func testFullSoftwareKeyboardCanBeDismissedFromComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no full software keyboard on this destination; nothing to dismiss")
        }
        let collapse = app.buttons["Collapse keyboard"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "a visible software keyboard must be dismissible")
        collapse.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the collapse button puts the keyboard away")
    }

    func testComposerStartsAsOneRowThenDropsToToolbarAndScrolls() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "gram"
        app.launch()

        let field = app.textViews["gram-composer-input"]
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("one")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        let oneLine = field.frame
        let sendBottom = send.frame.maxY
        XCTAssertEqual(oneLine.midY, send.frame.midY, accuracy: 4,
                       "a one-line message shares a single row with the send button")
        // No dead strip above a one-row composer (review f1 on #297 suspected an empty
        // attachment slot added 8 points; it does not, and this keeps it that way).
        let card = app.descendants(matching: .any)["composer-card"].firstMatch
        XCTAssertTrue(card.exists)
        XCTAssertLessThanOrEqual(card.frame.height - send.frame.height, 13,
                                 "a one-row composer is the button row plus its padding, with no dead space")

        field.typeText("\ntwo\nthree")
        Thread.sleep(forTimeInterval: 0.6)
        let threeLines = field.frame
        XCTAssertGreaterThan(threeLines.height, oneLine.height)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertLessThanOrEqual(threeLines.maxY, send.frame.minY + 1,
                                 "wrapped text moves above a toolbar holding the buttons")
        XCTAssertTrue(send.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "gram-composer-three-lines"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // The pull-to-expand editor: the handle appears at three lines, a tap opens a
        // taller editor above a fixed send button, and a second tap closes it.
        let handle = app.descendants(matching: .any)["composer-expand-handle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 3), "three lines offer the expand handle")
        handle.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(field.frame.height, threeLines.height + 20, "tapping the handle opens the editor")
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2, "opening the editor does not move send")
        let editor = XCTAttachment(screenshot: app.screenshot())
        editor.name = "gram-composer-editor"
        editor.lifetime = .keepAlways
        add(editor)
        handle.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(field.frame.height, threeLines.height, accuracy: 2, "a second tap closes it")

        field.typeText("\nfour\nfive")
        Thread.sleep(forTimeInterval: 0.6)
        let fiveLines = field.frame
        XCTAssertGreaterThan(fiveLines.height, threeLines.height)
        field.typeText("\nsix\nseven")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(field.frame.height, fiveLines.height, accuracy: 2,
                       "past five lines the text scrolls instead of growing")
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("seven") == true)
        XCTAssertTrue(send.isHittable)
    }
}
