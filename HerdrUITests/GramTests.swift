import XCTest

/// Exercise Gram through its real tab/sidebar host. A standalone GramView deliberately
/// omits the regular-width header: Read all, search and the conversations belong to the
/// host's sidebar there.
///
/// Strings come from the mock `gram.list` (MockTransport.gramList), the design's sample
/// conversation, newest first: g1 your "Great, ship it." to vetrina; g2 clientloop (relayed
/// from hetzner-1) with a one-line code fence and a zip; g3 a vetrina image; g4 vetrina's
/// 11-line "Deployed." report that folds at 8 lines; g5 a queue post grabbed by ci-watch; g6
/// trend-scout's "Digest ready" (relayed); g10 a LOCAL clientloop's "Lint is clean on my branch."
/// (two agents share the name clientloop); g7–g9 yesterday's vetrina thread. g2–g4 are unread.
final class GramTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// iPad and Mac draw Gram in the split view: the sidebar holds search, the conversations
    /// and Read all. iPhone keeps them on the page (search button, the "Gram ›" pill's sheet).
    private var hasSidebar: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    private func launchGram(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launchEnvironment.merge(environment) { _, new in new }
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

    /// Waits until Read all reports nothing unread. iPad/Mac: the sidebar button renders only
    /// while something is unread, so gone means zero. iPhone: the sheet's button stays and
    /// carries the count as its value ("3 unread"), which empties only at zero; disabled alone
    /// would also match the pass still in flight, or a pass that marked nothing.
    private func waitUntilNothingUnread(_ readAll: XCUIElement, timeout: TimeInterval) -> Bool {
        let zero = hasSidebar
            ? NSPredicate(format: "exists == false")
            : NSPredicate(format: "exists == true AND NOT (value CONTAINS %@)", "unread")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: zero, object: readAll)],
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
        // Like Messages, the feed opens at the NEWEST message (g1, the owner's reply), not
        // part-way up: a lazy feed once opened mid-history on iPhone.
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "the newest message should be laid out")
        XCTAssertTrue(newest.isHittable, "the feed should open showing the newest message")

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

        // Clearing the field restores the full list, back at the newest message: the deletes
        // pass through "z", which matches a short list (the hetzner-1 senders and the zip), and the feed must not be left
        // scrolled to that short list's top, where the restored rows near the bottom are not
        // even laid out. Checked ON SCREEN (hittable), not merely present: the newest bubble
        // (g1, "Great, ship it.") and its neighbour's sender, clientloop. With the iPhone
        // keyboard up the feed is short, so clientloop's label is checked for existence and the
        // newest bubble for being on screen.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5),
                      "clearing the search should bring the filtered-out messages back")
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        let onScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter().wait(for: [onScreen], timeout: 5), .completed,
                       "clearing the search should return the feed to the newest message, on screen")

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

    /// Read all marks the unread messages read: the count it reports reaches zero. On iPad/Mac
    /// it is the capsule button in the sidebar bar, present only while something is unread; on
    /// iPhone it is in the sheet the header's "Gram ›" pill opens, and its value is the unread
    /// count ("3 unread", empty at zero).
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
            if !hasSidebar {
                // The count is there to clear: the value names it before the tap.
                guard (readAll.value as? String)?.contains("unread") == true else {
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
            }
            readAll.tap()
            if waitUntilNothingUnread(readAll, timeout: 4) { cleared = true; break }
        }
        XCTAssertTrue(cleared, "tapping Read all should drive the unread count to zero")
    }

    /// iPhone: with Saved showing, the header pill says so ("Saved ›", spoken "Saved"); back
    /// on the inbox it reads "Gram" again. iPad/Mac show Saved as the sidebar's selected row.
    func testGramHeaderPillNamesSavedOnIPhone() throws {
        try XCTSkipIf(hasSidebar, "iPad/Mac name the Saved section in the sidebar")
        let app = launchGram()
        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the header should show the Gram pill")
        XCTAssertEqual(pill.label, "Gram")

        let savedToggle = app.buttons["gram-saved-toggle"]
        XCTAssertTrue(savedToggle.waitForExistence(timeout: 5))
        savedToggle.tap()
        XCTAssertTrue(app.staticTexts["No saved messages yet"].waitForExistence(timeout: 5),
                      "the bookmark toggle should show the (empty) Saved list")
        XCTAssertEqual(pill.label, "Saved", "the pill should name the Saved list")
        XCTAssertTrue(pill.staticTexts["Saved"].exists, "the pill should read \"Saved ›\"")

        savedToggle.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5))
        XCTAssertEqual(pill.label, "Gram", "back on the inbox the pill reads Gram again")
    }

    /// Paging: the first page (`HERDR_MOCK_GRAM_PAGED`, MockTransport.gramPagedList) has more
    /// behind it. Opening lands on the newest message; reaching the top fetches exactly ONE
    /// older page (24 rows, go1 newest to go24 oldest, more than a screen), and the message that
    /// was on top before (g9, "Picked up the deploy ticket.") stays on screen rather than being
    /// pushed down by the rows inserted above it. The mock has a third page behind go24, so a
    /// chained fetch would show as a count past 34. (A first page that fits the screen, as it
    /// may on a large iPad, shows the top on open, so its fetch then is the reader's too.)
    func testGramScrollingToTheTopLoadsOneOlderPage() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])

        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 5),
                      "the feed opens at the newest message")
        func label(_ prefix: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        }
        // The loaded-message count rides on the feed's message stack (`gram-feed-messages`).
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5), "the feed should report its message count")
        func waitForCount(_ count: Int, timeout: TimeInterval) -> Bool {
            let loaded = NSPredicate(format: "value == %@", "\(count) messages")
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: messages)],
                                    timeout: timeout) == .completed
        }
        if !hasSidebar {
            // The phone's first page overfills the screen: opening fetches nothing.
            XCTAssertTrue(waitForCount(10, timeout: 2), "opening should not load an older page; feed says \(messages.value ?? "nil")")
        }

        // Scroll up only until the page lands, so the swipes themselves cannot reach the top
        // of the NEW page and ask for the next one.
        var paged = waitForCount(34, timeout: 2)
        for _ in 0..<8 where !paged {
            feed.swipeDown(velocity: .slow)
            paged = waitForCount(34, timeout: 3)
        }
        XCTAssertTrue(paged, "reaching the top should load the older page (10 + 24 messages); feed says \(messages.value ?? "nil")")

        let previousTop = label("Picked up the deploy ticket.")
        XCTAssertTrue(previousTop.waitForExistence(timeout: 3) && previousTop.isHittable,
                      "the message that was on top should stay on screen after the older page lands")

        // Let a chained fetch, if any, land: the count must stay at exactly one page.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "34 messages", "exactly one older page should load")

        // The page's oldest message is at its top (reaching it may fetch the next page: the
        // reader is at the top again).
        let olderOldest = label("Older page: release planning starts here.")
        for _ in 0..<10 where !olderOldest.isHittable { feed.swipeDown(velocity: .slow) }
        XCTAssertTrue(olderOldest.isHittable, "the older page's oldest message should appear")
    }

    /// The feed draws only the newest window of the loaded messages (a search walk can load
    /// the whole store). Reaching the top reveals the older LOADED ones first, without asking
    /// the daemon for another page. A 6-message window over the 10-message first page. iPhone
    /// only: an iPad screen fits the 6 rows, so the sentinel is on screen at once and reveals
    /// them before anything can be observed (the same code path, correctly).
    func testOlderLoadedMessagesAreRevealedWithoutFetching() throws {
        try XCTSkipIf(hasSidebar, "the window fits the iPad screen: revealed at once")
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1", "HERDR_GRAM_RENDER_WINDOW": "6"])
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["Great, ship it."].waitForExistence(timeout: 5),
                      "the feed opens at the newest message")
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5))
        XCTAssertEqual(messages.value as? String, "10 messages", "one page is loaded")
        let oldest = app.descendants(matching: .any)["gram-bubble-g9"]
        XCTAssertFalse(oldest.exists, "the oldest loaded message is outside the drawn window")

        for _ in 0..<8 where !oldest.exists { feed.swipeDown(velocity: .slow); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(oldest.waitForExistence(timeout: 3), "reaching the top should draw the older loaded messages")
        // The revealed rows push the sentinel off screen again: no fetch. Wait past the anchor
        // restore (up to ~0.7 s) and the mock's round trip, so a page fetched after the reveal
        // would have landed.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "10 messages", "revealing loaded rows fetches no page")
    }

    /// iPhone: Gram is a persistent tab, so leaving it and coming back keeps the feed's layout
    /// exactly as it was. Leaving clears what the feed knows is on screen; coming back must
    /// re-learn it without the reader scrolling, or the initial scroll never finishes and the
    /// top sentinel never fetches (nor do rows mark read or new messages follow). After the
    /// round trip, reaching the top loads exactly one older page, as on first open.
    func testGramStillPagesAfterATabRoundTrip() throws {
        try XCTSkipIf(hasSidebar, "iPad/Mac show Gram in the split view, not a tab")
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_PAGED": "1"])

        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        let messages = app.otherElements["gram-feed-messages"]
        XCTAssertTrue(messages.waitForExistence(timeout: 5), "the feed should report its message count")
        func waitForCount(_ count: Int, timeout: TimeInterval) -> Bool {
            let loaded = NSPredicate(format: "value == %@", "\(count) messages")
            return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: messages)],
                                    timeout: timeout) == .completed
        }
        XCTAssertTrue(waitForCount(10, timeout: 5), "the first page only; feed says \(messages.value ?? "nil")")
        let newest = app.staticTexts["Great, ship it."]
        XCTAssertTrue(newest.waitForExistence(timeout: 5) && newest.isHittable,
                      "the feed opens at the newest message")

        let tabs = app.tabBars.firstMatch
        let agentsTab = tabs.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 5))
        agentsTab.tap()
        XCTAssertTrue(newest.waitForNonExistence(timeout: 5) || !newest.isHittable,
                      "the Agents tab should cover Gram")
        let gramTab = tabs.buttons["Gram"]
        XCTAssertTrue(gramTab.waitForExistence(timeout: 5))
        gramTab.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 5) && newest.isHittable,
                      "back on Gram, the feed is still at the newest message")
        XCTAssertTrue(waitForCount(10, timeout: 2), "coming back loads nothing; feed says \(messages.value ?? "nil")")

        var paged = waitForCount(34, timeout: 2)
        for _ in 0..<8 where !paged {
            feed.swipeDown(velocity: .slow)
            paged = waitForCount(34, timeout: 3)
        }
        XCTAssertTrue(paged, "after a tab round trip, reaching the top should still load the older page; feed says \(messages.value ?? "nil")")
        let previousTop = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Picked up the deploy ticket.")).firstMatch
        XCTAssertTrue(previousTop.waitForExistence(timeout: 3) && previousTop.isHittable,
                      "the message that was on top should stay on screen after the older page lands")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(messages.value as? String, "34 messages", "exactly one older page should load")
    }

    /// vetrina's report runs to 11 lines, past the 8-line fold, so it ends in "…" with a
    /// separate "Read more" line; tapping it shows the whole message (the bubble grows) and the
    /// line becomes "Show less", which folds it back.
    func testReadMoreExpandsALongMessageAndShowLessFoldsIt() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let readMore = app.buttons["gram-read-more"].firstMatch
        let showLess = app.buttons["gram-show-less"].firstMatch
        XCTAssertTrue(readMore.waitForExistence(timeout: 5), "a long report should fold with Read more")
        XCTAssertFalse(showLess.exists, "a folded report offers Read more, not Show less")
        // The feed opens at the newest message; on a phone the report can sit just above it.
        for _ in 0..<3 where !readMore.isHittable { app.swipeDown() }
        XCTAssertTrue(readMore.isHittable, "Read more should be reachable")

        // The report is exposed ONCE: the fold measures it with hidden copies, which must
        // not reach VoiceOver (they did once, and read the report three times).
        let prose = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Deployed."))
        XCTAssertEqual(prose.count, 1, "VoiceOver should meet the report once")
        let bubble = app.descendants(matching: .any)["gram-bubble-g4"]
        XCTAssertTrue(bubble.exists, "the folded report's bubble should be on screen")
        let folded = bubble.frame

        readMore.tap()
        XCTAssertTrue(showLess.waitForExistence(timeout: 3), "an expanded message offers Show less")
        XCTAssertFalse(readMore.exists, "an expanded message has no Read more")
        Thread.sleep(forTimeInterval: 0.4)   // the expand animates (0.2 s)
        // Three more 20 pt lines (the 15/20 body): the whole report, all 11 lines.
        XCTAssertGreaterThanOrEqual(bubble.frame.height, folded.height + 3 * 20 - 4,
                                    "the expanded report should show all 11 lines")
        // Like Messages, the bubble hugs its widest line, so it may widen; never narrower.
        XCTAssertGreaterThanOrEqual(bubble.frame.width, folded.width - 1, "expanding never narrows the bubble")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gram-read-more-expanded"
        shot.lifetime = .keepAlways
        add(shot)

        for _ in 0..<3 where !showLess.isHittable { app.swipeDown() }
        showLess.tap()
        XCTAssertTrue(readMore.waitForExistence(timeout: 3), "Show less folds the report back to Read more")
        XCTAssertFalse(showLess.exists, "a folded report has no Show less")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(bubble.frame.height, folded.height, accuracy: 2, "Show less folds back to 8 lines")
    }

    /// The label of the DEBUG `gram-post-calls` probe once it contains `expected`: the mock's
    /// recorded `gram.post` calls, one `to=<name|queue> text=<text>` per line ("none" before
    /// any). The label, not the value: on the iPhone tab the value reads the tab's badge.
    private func waitForPostCall(_ app: XCUIApplication, containing expected: String) -> String {
        let probe = app.descendants(matching: .any)["gram-post-calls"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG post probe should be present")
        let recorded = NSPredicate(format: "label CONTAINS %@", expected)
        let landed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: recorded, object: probe)],
                                      timeout: 5) == .completed
        XCTAssertTrue(landed, "the mock should record \"\(expected)\"; probe says \(probe.label)")
        return probe.label
    }

    /// Mock D: typing "@" lists the agents seen in Gram above the composer, typing narrows the
    /// list, and picking one puts "@vetrina " in the field. Sending posts to vetrina alone,
    /// with the leading mention taken off the text.
    func testAtMentionPicksAnAgentAndSendsToItAlone() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()

        let list = app.descendants(matching: .any)["gram-mention-list"]
        XCTAssertFalse(list.exists, "no list before an @")
        field.typeText("@")
        XCTAssertTrue(list.waitForExistence(timeout: 3), "typing @ lists the agents")
        XCTAssertTrue(app.staticTexts["Send to one agent"].exists, "the list says what picking does")
        XCTAssertTrue(app.staticTexts["No @ and it goes to the shared queue."].exists,
                      "the list reminds that no @ means the shared queue")
        let vetrina = app.buttons["gram-mention-vetrina"]
        // Two agents are called clientloop: the local one (sender ID "clientloop") and the one
        // relayed from hetzner-1. Both are listed, each under its own sender ID.
        let clientloop = app.buttons["gram-mention-clientloop"]
        let relayedClientloop = app.buttons["gram-mention-\(Self.relayedClientloop)"]
        XCTAssertTrue(vetrina.exists, "vetrina has messaged in Gram, so it is listed")
        XCTAssertTrue(clientloop.exists, "the local clientloop has messaged in Gram, so it is listed")
        XCTAssertTrue(relayedClientloop.exists, "the relayed clientloop is listed too, not merged into the local one")

        field.typeText("vet")
        XCTAssertTrue(clientloop.waitForNonExistence(timeout: 3), "\"vet\" filters clientloop out")
        XCTAssertTrue(vetrina.exists, "\"vet\" keeps vetrina")

        vetrina.tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 3), "picking an agent closes the list")
        XCTAssertEqual(field.value as? String, "@vetrina ", "picking completes the mention")

        field.typeText("Ship the drop")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isEnabled)
        send.tap()

        let calls = waitForPostCall(app, containing: "to=vetrina text=Ship the drop")
        XCTAssertFalse(calls.contains("@vetrina"), "the leading mention is not part of the text")
        XCTAssertFalse(calls.contains("to=queue"), "a mention never also posts to the queue")
    }

    /// The relayed clientloop's full sender ID in the mock (g2); the local one's is "clientloop".
    private static let relayedClientloop = "4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/clientloop"

    /// "@vetrina " with nothing after it has no message: Send shows but stays disabled.
    func testAMentionWithNoMessageCannotBeSent() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("@vet")
        let vetrina = app.buttons["gram-mention-vetrina"]
        XCTAssertTrue(vetrina.waitForExistence(timeout: 3))
        vetrina.tap()
        XCTAssertEqual(field.value as? String, "@vetrina ")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "a mention is content: send takes the saved-prompts place")
        XCTAssertFalse(send.isEnabled, "a mention alone has no message to send")
    }

    /// Two agents share the name clientloop. Typed, the name picks neither and Send stays off;
    /// picking the relayed one from the list sends to its full sender ID, never the local one.
    func testASharedNameSendsToTheAgentPicked() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // No space after the name, so autocorrect has nothing to act on.
        field.typeText("@clientloop")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "a typed name two agents share picks neither")

        let relayed = app.buttons["gram-mention-\(Self.relayedClientloop)"]
        XCTAssertTrue(relayed.waitForExistence(timeout: 3), "the list offers both clientloops")
        XCTAssertTrue(app.buttons["gram-mention-clientloop"].exists)
        XCTAssertTrue(relayed.label.contains("clientloop · hetzner-1"),
                      "a shared name is told apart by its machine; row reads \(relayed.label)")
        relayed.tap()
        XCTAssertEqual(field.value as? String, "@clientloop ")
        field.typeText("deploy?")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let calls = waitForPostCall(app, containing: "to=\(Self.relayedClientloop) text=deploy?")
        XCTAssertFalse(calls.contains("to=clientloop "), "the local clientloop must not get it")
    }

    /// The agents sheet addresses the exact agent: its relayed clientloop row sends to that
    /// agent's full sender ID, though a local agent has the same name.
    func testTheAgentsSheetSendsToTheExactAgent() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Status please")

        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()
        let row = app.buttons["gram-recipient-\(Self.relayedClientloop)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the sheet lists the relayed clientloop by its sender ID")
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "choosing an agent closes the sheet")
        XCTAssertEqual(field.value as? String, "@clientloop Status please",
                       "the sheet puts the agent's mention at the start")

        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isEnabled)
        send.tap()
        _ = waitForPostCall(app, containing: "to=\(Self.relayedClientloop) text=Status please")
    }

    /// A leading @name that names no agent in Gram is never sent to the shared queue: Send
    /// stays off and the composer says why.
    func testAnUnknownLeadingMentionBlocksSend() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // No space after the name, so autocorrect has nothing to act on.
        field.typeText("@nobody")
        let hint = app.staticTexts["gram-composer-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "the composer says why it cannot send")
        XCTAssertEqual(hint.label, "No agent called @nobody in Gram")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "an @name matching no agent must not fall back to the queue")
    }

    /// No "@" in the text: the post goes to the shared queue, text unchanged.
    func testSendingWithoutAMentionPostsToTheQueue() {
        let app = launchGram()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))
        let field = app.textViews["gram-composer-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Please review the docs")
        XCTAssertFalse(app.descendants(matching: .any)["gram-mention-list"].exists,
                       "no @, no agent list")
        let send = app.buttons["gram-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        _ = waitForPostCall(app, containing: "to=queue text=Please review the docs")
    }

    /// The header floats over the feed with no band, but the feed's top stops below it: scrolled
    /// to the top, the oldest loaded message is clear of the header's controls and hittable.
    func testOldestMessageClearsTheFloatingHeaderAtTheTop() {
        let app = launchGram()
        let feed = app.scrollViews["gram-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "the Gram feed should load")
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let oldest = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Picked up the deploy ticket.")).firstMatch
        let oldestBubble = app.descendants(matching: .any)["gram-bubble-g9"]
        for _ in 0..<6 { feed.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 0.6)   // let the scroll settle
        XCTAssertTrue(oldest.waitForExistence(timeout: 3) && oldest.isHittable,
                      "at the top, the oldest loaded message is on screen and hittable")

        let pill = app.buttons["gram-header-pill"]
        XCTAssertTrue(pill.exists, "the floating header shows the Gram pill")
        XCTAssertGreaterThanOrEqual(oldestBubble.frame.minY, pill.frame.maxY,
                                    "at the top, the oldest message sits below the floating header")
        if hasSidebar {
            XCTAssertTrue(app.buttons["gram-saved-toggle"].exists,
                          "iPad/Mac float a Saved capsule at the header's right")
        }
    }

    /// The attachment card of message `id`: the whole card is its Open button.
    private func attachmentCard(_ app: XCUIApplication, message id: String) -> XCUIElement {
        app.descendants(matching: .any)["gram-bubble-\(id)"]
            .descendants(matching: .button)["gram-attachment-open"].firstMatch
    }

    /// clientloop's zip (g2): tapping anywhere on its card opens it, and the card carries no
    /// Open / Save to Files bar of its own.
    func testTappingAFileCardOpensIt() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g2")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the zip should draw as a file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        XCTAssertEqual(card.label, "Open amigo-poc-scaffold.zip", "the card is one button that opens the file")
        let bubble = app.descendants(matching: .any)["gram-bubble-g2"]
        XCTAssertEqual(bubble.descendants(matching: .button).matching(identifier: "gram-attachment-open").count, 1,
                       "one Open target: the card itself")
        XCTAssertFalse(app.descendants(matching: .any)["gram-attachment-save"].exists,
                       "Save to Files is no longer a button on the card")
        XCTAssertFalse(bubble.buttons["Open"].exists, "no separate Open button")

        card.tap()
        let probe = app.descendants(matching: .any)["gram-opened-file"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG opened-file probe should be present")
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "opened:"),
                                               object: probe)
        XCTAssertEqual(XCTWaiter().wait(for: [opened], timeout: 10), .completed,
                       "tapping the card should download the file and hand it to a viewer; probe says \(probe.label)")
    }

    /// Long-pressing the file card offers Save to Files in the message's menu, beside the
    /// message's own actions (one menu, not two).
    func testLongPressingAFileCardOffersSaveToFiles() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g2")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the zip should draw as a file card")
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }

        card.press(forDuration: 1.2)
        let save = app.buttons["Save to Files"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the card's menu should offer Save to Files")
        XCTAssertTrue(app.buttons["Delete"].firstMatch.exists, "the same menu keeps the message's actions")
    }

    /// A DEBUG probe element by identifier (its state is in its label).
    private func probe(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits until `element`'s label matches the regular expression `pattern`.
    private func waitForLabel(_ element: XCUIElement, matching pattern: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", pattern),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits until `gram-get-file-calls` reports `count` `gram.get_file` calls for `id` (the
    /// label reads e.g. "g2=0 g3=1"). Polls the label directly: a predicate waiter with a
    /// regex re-checked too rarely for these short windows and failed on a matching label.
    private func waitForGetFileCalls(_ probe: XCUIElement, _ id: String, _ count: Int,
                                     timeout: TimeInterval) -> Bool {
        let wanted = "\(id)=\(count)"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if probe.label.split(separator: " ").contains(Substring(wanted)) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return probe.label.split(separator: " ").contains(Substring(wanted))
    }

    /// Scrolls the feed until `element` is on screen below the floating header (the header is
    /// see-through: a row behind it is "hittable" for XCUITest but not visible, and the app
    /// rightly does not count it as seen). Down for older rows, up for newer.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, older: Bool) {
        let feed = app.scrollViews["gram-feed"]
        let header = app.descendants(matching: .any)["gram-header-pill"]
        func shown() -> Bool {
            guard element.isHittable else { return false }
            let headerBottom = header.exists ? header.frame.maxY : feed.frame.minY
            return element.frame.minY >= headerBottom && element.frame.maxY <= feed.frame.maxY
        }
        for _ in 0..<12 where !shown() {
            if older { feed.swipeDown(velocity: .slow) } else { feed.swipeUp(velocity: .slow) }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// vetrina's image (g3) shows its picture without a tap: the card fetches it through the
    /// download cache while on screen and decodes a preview (the DEBUG
    /// `gram-image-preview-g3` probe says "placeholder" / "preview").
    func testImageCardShowsAPreviewWithoutOpening() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the image should draw as an image card")
        XCTAssertEqual(card.label, "Open vetrina-live.png, 412 KB")
        reveal(card, in: app, older: true)
        let preview = probe(app, "gram-image-preview-g3")
        XCTAssertTrue(waitForLabel(preview, matching: "preview", timeout: 8),
                      "the image card should decode its preview on its own; probe says \(preview.label)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gram-image-preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opening an image whose preview already landed opens the cached file: the daemon is
    /// asked for g3 once, by the prefetch, never again by the open.
    func testOpeningAPreviewedImageDoesNotFetchItAgain() {
        let app = launchGram()
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the image should draw as an image card")
        reveal(card, in: app, older: true)
        XCTAssertTrue(waitForLabel(probe(app, "gram-image-preview-g3"), matching: "preview", timeout: 8),
                      "the preview should land first")
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 3),
                      "the prefetch fetched g3 once; probe says \(calls.label)")

        card.tap()
        let opened = probe(app, "gram-opened-file")
        XCTAssertTrue(waitForLabel(opened, matching: "opened:vetrina-live\\.png", timeout: 5),
                      "tapping the card should open the image; probe says \(opened.label)")
        // Past the probe's poll, so a second fetch would show.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 1),
                      "the open must reuse the cached file, not fetch it again; probe says \(calls.label)")
    }

    /// The feed is an eager stack, so a drawn row exists whether it is seen or not: the
    /// image card must fetch only once it is really on screen. Fourteen newer messages
    /// (`HERDR_MOCK_GRAM_NEWER`) put g3 above the fold, inside a window that draws it.
    func testAnImageCardAboveTheFoldFetchesOnlyOnceScrolledIntoView() {
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_NEWER": "1", "HERDR_GRAM_RENDER_WINDOW": "200"])
        let newest = app.descendants(matching: .any)["gram-bubble-gn14"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the newer messages should load")
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 5), .completed, "the feed opens at the newest message")
        let card = attachmentCard(app, message: "g3")
        XCTAssertTrue(card.exists, "the image row is drawn")
        XCTAssertFalse(card.isHittable, "precondition: the image sits above the fold")

        // Past the landing, the prefetch delay and the probe's poll.
        Thread.sleep(forTimeInterval: 2)
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 0, timeout: 1),
                      "an image card off screen must not fetch; probe says \(calls.label)")

        reveal(card, in: app, older: true)
        XCTAssertTrue(card.isHittable, "scrolling up should bring the image on screen")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 5),
                      "on screen, the card fetches its preview once; probe says \(calls.label)")
        XCTAssertTrue(waitForLabel(probe(app, "gram-image-preview-g3"), matching: "preview", timeout: 8),
                      "and draws it")
    }

    /// A prefetch never holds up an open: with g3's download held in flight for 10 s
    /// (`HERDR_MOCK_GRAM_FILE_DELAY`), opening the zip (g2) still opens it at once.
    func testAPrefetchDoesNotBlockOpeningAnotherFile() {
        // Held for 60 s: a slow CI runner spent more than 10 s scrolling, and the download
        // landed before the precondition check. The test ends when the zip opens, not then.
        let app = launchGram(environment: ["HERDR_MOCK_GRAM_FILE_DELAY": "g3=60"])
        let image = attachmentCard(app, message: "g3")
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the image should draw as an image card")
        reveal(image, in: app, older: true)
        let calls = probe(app, "gram-get-file-calls")
        XCTAssertTrue(waitForGetFileCalls(calls, "g3", 1, timeout: 5),
                      "the image's prefetch should be in flight; probe says \(calls.label)")
        XCTAssertEqual(probe(app, "gram-image-preview-g3").label, "placeholder",
                       "precondition: the held download has not landed")

        let file = attachmentCard(app, message: "g2")
        reveal(file, in: app, older: false)
        file.tap()
        let opened = probe(app, "gram-opened-file")
        XCTAssertTrue(waitForLabel(opened, matching: "opened:.+", timeout: 4),
                      "the zip should open while the image is still downloading; probe says \(opened.label)")
        XCTAssertTrue(waitForGetFileCalls(calls, "g2", 1, timeout: 2),
                      "the open fetched the zip itself; probe says \(calls.label)")
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

    /// A reader at the newest message who starts typing stays there, as in Messages: the
    /// keyboard shrinks the feed, and the newest message must stay visible above the composer
    /// (not slide under it, and no "New messages" pill when nothing arrived).
    func testReaderAtTheBottomStaysThereWhenTheKeyboardComesUp() throws {
        let app = launchGram()
        let newest = app.descendants(matching: .any)["gram-bubble-g1"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        XCTAssertTrue(newest.isHittable, "the feed opens at the newest message")
        let field = app.textViews["gram-composer-input"]
        field.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no software keyboard on this destination: the feed does not shrink")
        }
        field.typeText("ok")
        let card = app.descendants(matching: .any)["composer-card"].firstMatch
        let settled = NSPredicate { _, _ in newest.isHittable && newest.frame.maxY <= card.frame.minY + 1 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)],
                                        timeout: 3), .completed,
                       "the newest message should stay visible above the composer")
        XCTAssertFalse(app.buttons["gram-new-messages"].exists, "nothing new arrived: no pill")
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
