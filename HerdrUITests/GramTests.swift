import XCTest

/// Exercise Gram through its real tab/sidebar host. A standalone GramView deliberately
/// omits the regular-width header: Read all, search and the conversations belong to the
/// host's sidebar there.
///
/// Strings come from the mock `gram.list` (MockTransport.gramList), the design's sample
/// conversation, newest first: g1 your "Great, ship it." to vetrina; g2 clientloop (relayed
/// from hetzner-1) with a one-line code fence and a zip; g3 a vetrina image; g4 vetrina's long
/// "Deployed." report that folds; g5 a queue post grabbed by ci-watch; g6 trend-scout's
/// "Digest ready" (relayed); g7–g9 yesterday's vetrina thread. g2–g4 are unread.
final class GramTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// iPad and Mac draw Gram in the split view: the sidebar holds search, the conversations
    /// and Read all. iPhone keeps them on the page (search button, the "Gram ›" pill's sheet).
    private var hasSidebar: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    private func launchGram() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        let tab = app.buttons["Gram"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        return app
    }

    /// The search field: in the sidebar on iPad/Mac (always there, no toggle on the page),
    /// behind the page's search button on iPhone.
    private func openSearchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["gram-search-field"]
        if hasSidebar {
            XCTAssertTrue(field.waitForExistence(timeout: 5), "the sidebar should hold the Gram search")
            XCTAssertFalse(app.buttons["gram-search"].exists,
                           "with the sidebar's field the page shows no search toggle of its own")
        } else {
            let toggle = app.buttons["gram-search"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the header should offer search")
            XCTAssertTrue(toggle.isHittable, "the newest message must not cover the search control")
            toggle.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "the search button should reveal the search field")
        }
        return field
    }

    /// Waits until `element` is gone or disabled.
    private func waitUntilGoneOrDisabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = NSPredicate(format: "exists == false OR enabled == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element)],
                                timeout: timeout) == .completed
    }

    func testGramPageRenders() {
        let app = launchGram()

        // Give the mock gram.list a moment to load + lay out the rows.
        Thread.sleep(forTimeInterval: 2.0)

        // A canned agent->owner message's sender label should appear: the bare agent name,
        // its machine ("· hetzner-1") a separate span.
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
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
    /// "Digest" appears in exactly one message (g6, from trend-scout), and "clientloop" is the
    /// sender label of a DIFFERENT message (g2), near the bottom of the feed so it is on screen
    /// before filtering — so one label surviving while the other disappears is a receipt that
    /// rows were filtered, not merely re-laid-out.
    func testGramSearchFiltersTheInbox() {
        let app = launchGram()

        // The sender that should disappear is present before any filter: the pre-state the
        // filter acts on. Without this the later disappearance would prove nothing.
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10),
                      "the newest agent->owner message should render before filtering")

        let field = openSearchField(app)
        field.tap()
        field.typeText("Digest")

        XCTAssertTrue(app.staticTexts["trend-scout"].waitForExistence(timeout: 3),
                      "the matching message should survive the filter")
        XCTAssertTrue(app.staticTexts["clientloop"].waitForNonExistence(timeout: 5),
                      "a message matching nothing in the search should be filtered out")

        // A filter that matches nothing: the "No matches" state, NOT a blank list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5),
                      "a filter matching no message should say so")

        // Clearing the field restores the full list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "clearing the search should bring the filtered-out messages back")

        // CLOSING must also clear. A hidden field that is still filtering would leave the
        // list silently short with nothing on screen to explain it - the failure mode a
        // dismissible search box invites. Re-filter first so the close has work to undo.
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        if hasSidebar {
            // The sidebar field stays; its Clear button is the way back.
            app.buttons["Clear search"].firstMatch.tap()
        } else {
            app.buttons["gram-search"].tap()
            XCTAssertFalse(field.exists, "closing should dismiss the field")
        }
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "clearing or closing search should restore the unfiltered list")
    }

    /// Owner rule: search fields have no mic (the composer keeps dictation). Neither the Gram
    /// search nor anything beside it offers dictation.
    func testGramSearchFieldHasNoMic() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = openSearchField(app)

        XCTAssertFalse(app.buttons["gram-search-mic"].exists, "the Gram search has no mic")
        XCTAssertFalse(app.buttons["agent-search-mic"].exists, "no search field has a mic")
        // The composer's own Dictate stays (it is far below); none may sit on the field's row.
        let row = field.frame.insetBy(dx: -60, dy: -8)
        let dictate = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@",
                                                       "Dictate", "Dictate"))
        for mic in dictate.allElementsBoundByIndex where mic.exists {
            XCTAssertFalse(mic.frame.intersects(row), "a Dictate button sits beside the search field")
        }
    }

    /// Read all marks the unread messages read: the button is present while something is unread
    /// and gone once the pass completes (it renders only for `unreadCount > 0`). On iPad/Mac it
    /// is the capsule button in the sidebar bar; on iPhone it is in the sheet the header's
    /// "Gram ›" pill opens.
    ///
    /// The button's presence is only STABLE after the first poll, and the test waits for that
    /// deliberately: at launch the unread messages' own rows mark themselves read within a
    /// moment (`markReadIfNeeded` from `onAppear`), which drives the count to zero and removes
    /// the button — so a tap aimed at the launch-time button can miss. The mock's `gram.list` is
    /// a CONSTANT that always reports g2–g4 unread, so the 6-second poll restores it, and because
    /// the rows' identity is unchanged `onAppear` does not fire again: from then on the button
    /// stays up. The retry exists because the same poll also re-creates it a few seconds after a
    /// successful pass; each attempt guards `exists`/`isHittable` so a vanished button re-enters
    /// the loop instead of failing the test on an unrecoverable `tap()`.
    func testGramReadAllClearsTheUnreadCount() {
        let app = launchGram()

        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10),
                      "the Gram page should load the mock inbox")

        let readAll = app.buttons["Read all"].firstMatch
        let pill = app.buttons["gram-header-pill"]
        if !hasSidebar {
            XCTAssertTrue(pill.waitForExistence(timeout: 5), "the header should show the Gram pill")
            XCTAssertEqual(pill.label, "Gram")
        }
        var cleared = false
        for _ in 0..<4 {
            // iPhone: Read all lives in the pill's sheet; (re)open it when it is not up.
            if !hasSidebar, !readAll.exists, pill.exists, pill.isHittable {
                pill.tap()
            }
            // One poll interval plus slack, so this waits out the launch-time flip described
            // above rather than racing it.
            guard readAll.waitForExistence(timeout: 14), readAll.isHittable, readAll.isEnabled else {
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            readAll.tap()
            if waitUntilGoneOrDisabled(readAll, timeout: 4) { cleared = true; break }
        }
        XCTAssertTrue(cleared, "tapping Read all should drive the unread count to zero")
    }

    /// vetrina's report runs past four lines, so it folds with "Show more"; tapping it shows
    /// the whole message (the text grows) and the button goes away.
    func testShowMoreExpandsALongMessage() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let showMore = app.buttons["gram-show-more"].firstMatch
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), "a long report should fold with Show more")
        // The feed opens at the newest message; on a phone the report can sit just above it.
        for _ in 0..<3 where !showMore.isHittable { app.swipeDown() }
        XCTAssertTrue(showMore.isHittable, "Show more should be reachable")

        // The report is exposed ONCE: the fold measures it with hidden copies, which must
        // not reach VoiceOver (they did once, and read the report three times).
        let prose = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Deployed."))
        XCTAssertEqual(prose.count, 1, "VoiceOver should meet the report once")
        let bubble = app.descendants(matching: .any)["gram-bubble-g4"]
        XCTAssertTrue(bubble.exists, "the folded report's bubble should be on screen")
        let folded = bubble.frame

        showMore.tap()
        XCTAssertTrue(showMore.waitForNonExistence(timeout: 3), "an expanded message has no Show more")
        Thread.sleep(forTimeInterval: 0.4)   // the expand animates (0.2 s)
        XCTAssertGreaterThanOrEqual(bubble.frame.height, folded.height + 18,
                                    "the expanded report should show more than four lines")
        // Like Messages, the bubble hugs its widest line, so it may widen; never narrower.
        XCTAssertGreaterThanOrEqual(bubble.frame.width, folded.width - 1, "expanding never narrows the bubble")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gram-show-more-expanded"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// clientloop's command sits in a code block with its own Copy. Tapping it says "Copied".
    /// The pasteboard is deliberately NOT read back: a programmatic read raises the system
    /// paste prompt, which hung CI before (TerminalSelectionTests).
    func testCodeBlockCopyConfirms() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let copy = app.buttons["gram-code-copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "a code block should offer Copy")
        for _ in 0..<3 where !copy.isHittable { app.swipeUp() }
        XCTAssertEqual(copy.label, "Copy code")

        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Copied"),
                                               object: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [copied], timeout: 2), .completed,
                       "Copy should confirm with \"Copied\"")
    }

    /// iPad/Mac: the sidebar lists Gram's two conversations, Gram selected, and selecting Saved
    /// swaps the feed in place (the mock inbox's senders leave; Saved holds only local copies,
    /// and no test saves one). Selecting Gram brings them back.
    func testSidebarConversationsSwitchTheFeed() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone,
                      "the conversation rows are the iPad/Mac sidebar's; iPhone has no sidebar")
        let app = launchGram()

        let gram = app.buttons["gram-conversation-gram"]
        let saved = app.buttons["gram-conversation-saved"]
        XCTAssertTrue(gram.waitForExistence(timeout: 10), "the sidebar should list the Gram conversation")
        XCTAssertTrue(saved.exists, "the sidebar should list the Saved conversation")
        XCTAssertTrue(gram.isSelected, "Gram is the conversation shown at first")
        XCTAssertFalse(saved.isSelected)
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10),
                      "the Gram feed shows the mock inbox")

        saved.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForNonExistence(timeout: 5),
                      "selecting Saved should replace the Gram feed")
        XCTAssertTrue(saved.isSelected, "Saved should read as selected")
        XCTAssertFalse(gram.isSelected)

        gram.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "selecting Gram should bring the feed back")
        XCTAssertTrue(gram.isSelected)
    }

    /// Reported on TestFlight 170: the keyboard could not be dismissed from the composer.
    /// Whenever a full software keyboard is on screen the composer must offer the button,
    /// and tapping it must put the keyboard away.
    func testFullSoftwareKeyboardCanBeDismissedFromComposer() throws {
        let app = launchGram()
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
        let app = launchGram()

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
