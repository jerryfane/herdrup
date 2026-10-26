import XCTest

final class ChatUXSmokeTests: XCTestCase {
    private func launch(failingRefresh: Bool = false, pendingQuestion: Bool = false, large: Bool = false,
                        copyFixture: Bool = false, plan: String = "", mermaid: Bool = false,
                        longSession: Bool = false, environment: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.launched(mock: "chatview", environment: [
            "HERDR_STEADY_CARET": "1", "HERDR_MOCK_STILL": "1", "HERDR_CHAT_UX_SMOKE": "1",
            "HERDR_CHAT_UX_FAIL_REFRESH": failingRefresh ? "1" : "0",
            "HERDR_CHAT_UX_PENDING_QUESTION": pendingQuestion ? "1" : "0",
            "HERDR_CHAT_UX_LARGE": large ? "1" : "0",
            "HERDR_CHAT_UX_COPY": copyFixture ? "1" : "0",
            "HERDR_CHAT_UX_PLAN": plan,
            "HERDR_CHAT_UX_MERMAID": mermaid ? "1" : "0",
            "HERDR_CHAT_UX_LONG_SESSION": longSession ? "1" : "0"
        ].merging(environment) { _, new in new })
        let agent = app.staticTexts["herdr-app"].firstMatch
        if !agent.exists {
            let idle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Idle")).firstMatch
            if idle.waitForExistence(timeout: 5) { idle.tap() }
        }
        XCTAssertTrue(agent.waitForExistence(timeout: 12), app.debugDescription)
        agent.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        return app
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func dismissTextSizeMenu(_ app: XCUIApplication) {
        if app.buttons["terminal-font-increase"].exists {
            app.descendants(matching: .any)["chat-view"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4)).tap()
        }
    }

    /// The space between the model label, the transcript's last line, and the composer card.
    /// At the tail nothing scrolls under the composer, so no fade-sized spacer pads it.
    private func tailGap(_ app: XCUIApplication) -> CGFloat {
        let composer = app.descendants(matching: .any)["composer-card"].firstMatch
        XCTAssertTrue(composer.exists, app.debugDescription)
        return composer.frame.minY - app.staticTexts["chat-model"].frame.maxY
    }

    private func assertTailGap(_ app: XCUIApplication, _ moment: String) {
        var gap = tailGap(app)
        for _ in 0..<10 where gap > 32 {
            Thread.sleep(forTimeInterval: 0.3)
            gap = tailGap(app)
        }
        XCTAssertGreaterThanOrEqual(gap, 0, "\(moment): the model label must sit above the composer")
        XCTAssertLessThanOrEqual(gap, 32, "\(moment): at most about 20 pt between the model label and the composer")
    }

    func testChatSizeTablesMetadataAndRefresh() {
        let app = launch()
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        let model = app.staticTexts["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(model.label.contains("fixture-model"))
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        XCTAssertTrue(app.staticTexts["Ship after review"].exists)
        record(app, "Native current model, expanded TODO and fixture recap")

        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        let initialHeight = model.frame.height
        for _ in 0..<4 {
            app.buttons["terminal-actions"].tap()
            app.buttons["terminal-font-increase"].tap()
            dismissTextSizeMenu(app)
        }
        XCTAssertGreaterThan(model.frame.height, initialHeight)
        record(app, "Chat-only larger text through existing size controls")

        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        app.buttons["Dismiss refresh result"].tap()
        let modelVisible = NSPredicate(format: "hittable == true")
        expectation(for: modelVisible, evaluatedWith: model)
        waitForExpectations(timeout: 5)
        assertTailGap(app, "Following the tail after a refresh")
        record(app, "Tail gap between the model label and the composer")
        record(app, "Manual chat refresh completes without clearing the conversation")

        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        guard let table = app.descendants(matching: .any).matching(identifier: "chat-markdown-table").allElementsBoundByIndex.last else {
            return XCTFail("The fixture table must be rendered: \(app.debugDescription)")
        }
        for _ in 0..<4 where !table.isHittable { chat.swipeDown() }
        XCTAssertTrue(table.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(table.frame.maxX, chat.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(table.frame.minX, chat.frame.minX - 1)
        let description = app.staticTexts["A deliberately long description that must wrap within its column"].firstMatch
        XCTAssertGreaterThan(description.frame.height, 30)
        record(app, "Three-column table wraps within the phone width")
    }

    func testPlanCardCollapsesToTheCurrentWork() {
        let app = launch(plan: "six")
        let toggle = app.buttons["chat-plan-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(toggle.label, "To-do, 2 of 6 done")
        let rows = ["one", "two", "three", "four", "five", "six"].map { app.staticTexts["Plan item \($0)"] }
        XCTAssertEqual(rows.map(\.exists), [false, false, true, true, true, false],
                       "collapsed shows the in-progress item and the next two: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Build"].exists)
        XCTAssertTrue(app.staticTexts["Ship"].exists)
        let more = app.buttons["chat-plan-more"]
        XCTAssertTrue(more.exists, app.debugDescription)
        XCTAssertEqual(more.label, "+3 more")
        record(app, "Collapsed TODO shows the current work and +3 more")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.map(\.exists), Array(repeating: true, count: 6))
        XCTAssertFalse(more.exists, "expanded, nothing is hidden")
        record(app, "Expanded TODO shows every item")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(more.exists)
        more.tap()
        XCTAssertTrue(rows[5].waitForExistence(timeout: 5), "+3 more expands too: \(app.debugDescription)")
        XCTAssertEqual(rows.map(\.exists), Array(repeating: true, count: 6))
    }

    func testFinishedPlanShowsOnlyItsHeader() {
        let app = launch(plan: "done")
        let toggle = app.buttons["chat-plan-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(toggle.label, "To-do, 3 of 3 done")
        XCTAssertEqual(toggle.value as? String, "All done")
        let rows = ["one", "two", "three"].map { app.staticTexts["Plan item \($0)"] }
        XCTAssertEqual(rows.map(\.exists), [false, false, false], "a finished plan collapses to its header")
        XCTAssertFalse(app.buttons["chat-plan-more"].exists)
        record(app, "Finished TODO collapses to its header")

        toggle.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.map(\.exists), [true, true, true])
    }

    /// #523 item 1: a closed ```mermaid fence is drawn as a diagram (not its code), rasterised
    /// sharp for this screen; tapping it opens the zoomable viewer, "Show code" swaps in the
    /// source, search still finds words that are only in the diagram source, and after a
    /// relaunch the diagram comes back from the disk cache at the same size.
    func testMermaidReplyRendersADiagramThatOpensTheViewer() {
        let app = launch(mermaid: true)
        let block = app.descendants(matching: .any)["chat-mermaid"].firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 12), app.debugDescription)
        let image = app.buttons["chat-mermaid-image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30),
                      "The diagram must finish rendering offscreen: \(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["chat-mermaid-error"].exists, "The fixture diagram is valid mermaid")
        XCTAssertGreaterThan(image.frame.width, 40, "\(image.frame)")
        XCTAssertGreaterThan(image.frame.height, 40, "\(image.frame)")
        XCTAssertTrue(image.label.hasPrefix("Mermaid diagram, graph TD"), image.label)
        // The image's DEBUG value: "drawn|blank <raster scale>x fresh|disk".
        let screenScale = Self.screenScale(app)
        let drawn = "drawn \(screenScale)x "
        XCTAssertTrue((image.value as? String ?? "").hasPrefix(drawn),
                      "The raster must hold a drawing at the screen's scale (\(drawn)): \(String(describing: image.value))")
        let shownSize = image.frame.size
        let code = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "D[Render offscreen]")).firstMatch
        XCTAssertFalse(code.exists, "The diagram source must not be drawn as code")
        record(app, "Mermaid reply drawn as a diagram")

        image.tap()
        let viewer = app.descendants(matching: .any)["chat-mermaid-viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(viewer.frame.height, 100, "\(viewer.frame)")
        record(app, "Mermaid viewer full screen")
        app.buttons["chat-mermaid-viewer-done"].tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10))

        // The chat follows its tail, so the block's header can sit under the top bar: bring
        // it into view the way a reader would.
        let toggle = app.buttons["chat-mermaid-toggle"]
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        for _ in 0..<4 where !toggle.isHittable {
            chat.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(toggle.isHittable, "\(toggle.frame)")
        toggle.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["chat-mermaid-image"].exists)
        toggle.tap()
        XCTAssertTrue(app.buttons["chat-mermaid-image"].waitForExistence(timeout: 5))

        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Render offscreen")
        expectation(for: NSPredicate(format: "label == %@", "1/1"), evaluatedWith: app.staticTexts["terminal-find-count"])
        waitForExpectations(timeout: 5)

        // A relaunch draws nothing: the diagram comes back from the disk cache, at the size
        // it was shown at and still at the screen's scale.
        app.terminate()
        let relaunched = launch(mermaid: true)
        let cachedImage = relaunched.buttons["chat-mermaid-image"].firstMatch
        XCTAssertTrue(cachedImage.waitForExistence(timeout: 30), relaunched.debugDescription)
        XCTAssertEqual(cachedImage.value as? String, drawn + "disk")
        XCTAssertEqual(cachedImage.frame.width, shownSize.width, accuracy: 0.5)
        XCTAssertEqual(cachedImage.frame.height, shownSize.height, accuracy: 0.5)
        record(relaunched, "Mermaid diagram from the disk cache after relaunch")
    }

    /// Pixels per point of this device's screen, from a screenshot of it.
    private static func screenScale(_ app: XCUIApplication) -> Int {
        let shot = XCUIScreen.main.screenshot().image
        let pixels = max(shot.size.width * shot.scale, shot.size.height * shot.scale)
        let points = max(app.frame.width, app.frame.height)
        return Int((pixels / max(points, 1)).rounded())
    }

    func testSearchRevealsThoughtAndKeepsActiveChat() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(".*[x]")
        let result = app.staticTexts["chat-search-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(result.label.contains(".*[x]"))
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.exists)
        XCTAssertTrue(app.otherElements["chat-thought-open"].exists || app.descendants(matching: .any)["chat-thought-open"].exists)
        record(app, "Literal punctuation search reveals rendered thought without switching to Terminal")
        app.buttons["terminal-find"].tap()
        XCTAssertFalse(app.staticTexts["chat-search-result"].exists)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        chat.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["chat-jump-latest"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["chat-jump-latest"].tap()
        XCTAssertTrue(app.staticTexts["chat-model"].waitForExistence(timeout: 5), app.debugDescription)
        record(app, "Tail position immediately after jumping")
        let modelVisible = NSPredicate(format: "hittable == true")
        expectation(for: modelVisible, evaluatedWith: app.staticTexts["chat-model"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["chat-jump-latest"].exists, "The control must disappear at the measured tail")
        assertTailGap(app, "After the animated jump")
        record(app, "Centered clear-glass jump returns to latest without a composer fade")

        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Incoming café update after refresh."].isHittable)
        XCTAssertTrue(app.staticTexts["chat-model"].isHittable, "New content must retain the tail while following")

        app.textViews["terminal-reply-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        expectation(for: modelVisible, evaluatedWith: app.staticTexts["chat-model"])
        waitForExpectations(timeout: 5)
        record(app, "Following latest keeps the final line above the keyboard and composer")

        chat.swipeDown(velocity: .fast)
        XCTAssertFalse(app.staticTexts["chat-model"].isHittable, "The drag must move into history before refreshing")
        let incoming = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Incoming update ")).firstMatch
        let previousUpdate = incoming.label
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertNotEqual(incoming.label, previousUpdate, "The refresh must deliver changed reply content before checking reader position")
        XCTAssertFalse(app.staticTexts["chat-model"].isHittable, "An incoming reply must not pull the reader out of history")
        XCTAssertTrue(app.buttons["chat-jump-latest"].isHittable)
        record(app, "Incoming content preserves manual history position")
    }

    func testUnicodeSearchNavigationSurvivesRefresh() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("café")
        let count = app.staticTexts["terminal-find-count"]
        expectation(for: NSPredicate(format: "label == %@", "1/2"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        app.buttons["terminal-find-next"].tap()
        XCTAssertEqual(count.label, "2/2")
        app.buttons["terminal-find-next"].tap()
        XCTAssertEqual(count.label, "1/2")
        app.buttons["terminal-find-previous"].tap()
        XCTAssertEqual(count.label, "2/2")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(count.label, "2/3", "The new reply must add one match without moving the selected table match")
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Refreshing chat…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "2/3", "A no-change refresh must not duplicate the incoming reply")
        record(app, "Unicode search counts an incoming reply and preserves selection through a no-change refresh")
        app.buttons["terminal-find"].tap()
        XCTAssertFalse(app.staticTexts["chat-search-result"].exists)
    }

    /// The newest page is five turns (three synthetic prompts and the mockup's two); each
    /// Load older adds a twenty-turn page, the second reaching the start of the session.
    func testSearchPagingPreservesSelectedMatchAndLoadedScope() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Synthetic question")
        let count = app.staticTexts["terminal-find-count"]
        expectation(for: NSPredicate(format: "label == %@", "1/3"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Searching loaded history"].isHittable)
        app.buttons["Load older"].tap()
        expectation(for: NSPredicate(format: "label == %@", "21/23"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.buttons["Load older"].tap()
        expectation(for: NSPredicate(format: "label == %@", "38/40"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Load older"].exists)
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "38/40", "Refresh must retain paged history and the same selected prompt")
        record(app, "Loaded-history search expands to all forty prompts and preserves selection across refresh")
    }

    /// The DEBUG `chat-row-renders` probe: how many chat row bodies have run (its label;
    /// polled every 250 ms, so read it after a pause).
    private func rowRenders(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["chat-row-renders"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the row render probe should be on screen")
        return Int(probe.label) ?? -1
    }

    /// TestFlight build 221 lagged on every keystroke in a long agent session: the page
    /// that holds the composer redrew the chat with each character, and the chat redrew
    /// every one of its ~650 rows. On a page shaped like that session (`HERDR_CHAT_UX_LONG_SESSION`)
    /// typing must draw no transcript row at all.
    func testTypingInTheComposerDoesNotReRenderTheTranscript() {
        let app = launch(longSession: true)
        XCTAssertTrue(app.staticTexts["A complete fixture response."].waitForExistence(timeout: 12), app.debugDescription)
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The keyboard is up and the chat has settled over it.
        Thread.sleep(forTimeInterval: 2)
        let before = rowRenders(app)
        XCTAssertGreaterThan(before, 0, "the chat's rows were drawn")
        let typed = "typing thirty chars into chat."
        XCTAssertEqual(typed.count, 30)
        field.typeText(typed)
        Thread.sleep(forTimeInterval: 1.5)
        let spent = rowRenders(app) - before
        XCTAssertEqual(spent, 0, "typing 30 characters re-rendered \(spent) transcript rows")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// herdrup#523 item 8: a one-letter search on a long chat froze the app until it was
    /// killed. On the large fixture it must cap the count, draw only a window of results,
    /// step through matches, and narrow to an exact count as the term grows.
    func testOneLetterSearchOnLargeChatCapsAndStaysResponsive() {
        let app = launch(large: true)
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("e")
        let count = app.staticTexts["terminal-find-count"]
        let capped = { (index: Int) in NSPredicate(format: "label == %@", "Match \(index) of 500 or more matches") }
        expectation(for: capped(1), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.state, .runningForeground)
        let results = app.staticTexts.matching(identifier: "chat-search-result")
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertLessThanOrEqual(results.count, 23, "Only the selected match's neighbourhood is drawn, not every match")

        app.buttons["terminal-find-next"].tap()
        expectation(for: capped(2), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        app.buttons["terminal-find-previous"].tap()
        expectation(for: capped(1), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        app.buttons["terminal-find-previous"].tap()
        expectation(for: capped(500), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        record(app, "One-letter search on a long chat caps at 500+ and wraps to the last match")

        for letter in "xample" { field.typeText(String(letter)) }
        expectation(for: NSPredicate(format: "label == %@", "1/480"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.buttons["terminal-find-next"].tap()
        expectation(for: NSPredicate(format: "label == %@", "2/480"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testQuestionSheetFitsAndExpandsContext() {
        let app = launch(pendingQuestion: true)
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("Merge #305")
        XCTAssertTrue(app.staticTexts["chat-search-result"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["terminal-find"].tap()
        guard let open = app.buttons.matching(identifier: "chat-question-open").allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail(app.debugDescription)
        }
        open.tap()
        let context = app.buttons["Show context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5), app.debugDescription)
        record(app, "Question-first content-sized sheet")
        context.tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        record(app, "Question sheet expands context without losing question state")
        context.tap()
        guard let option = app.buttons.matching(identifier: "chat-ask-option-0").allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("The pending question must remain answerable after toggling context: \(app.debugDescription)")
        }
        option.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-chosen"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Done"].exists, "Answering must not dismiss the question sheet")
        record(app, "Question answer persists in the open content-sized sheet")
        app.buttons["Done"].tap()
        record(app, "Agent surface immediately after closing the question sheet")
        XCTAssertTrue(app.descendants(matching: .any)["chat-view"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["chat-note-done"].waitForNonExistence(timeout: 5), "Done must close only the question sheet")
    }

    func testRefreshFailureKeepsLoadedConversation() {
        let app = launch(failingRefresh: true)
        XCTAssertTrue(app.staticTexts["Review the table"].waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["terminal-refresh"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Refresh failed:")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Review the table"].exists)
        record(app, "Refresh failure remains visible without removing loaded chat")
    }

    /// What the chat's Copy last wrote, from the DEBUG `chat-copy-probe` (JSON in its label).
    /// Never `UIPasteboard`: a pasteboard read raises the system paste prompt, which nothing
    /// answers in CI (see TerminalSelectionTests' lesson 2).
    private func copiedText(_ app: XCUIApplication) -> String? {
        let label = app.descendants(matching: .any)["chat-copy-probe"].firstMatch.label
        let json = (try? JSONSerialization.jsonObject(with: Data(label.utf8))) as? [String: Any]
        return json?["copied"] as? String
    }

    private func waitForCopied(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 5,
                               file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while copiedText(app) != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(copiedText(app), expected, "the clipboard write", file: file, line: line)
    }

    /// Long-presses `element` (a right click on a Mac opens the same menu) and waits for its
    /// menu's `entry`.
    private func openMenu(_ app: XCUIApplication, on element: XCUIElement, entry: String,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        element.press(forDuration: 1.2)
        let button = app.buttons[entry].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the message menu offers \(entry): \(app.debugDescription)",
                      file: file, line: line)
        return button
    }

    /// Item 5 of #523: a reply's and a prompt's text can be copied and selected. The reply's
    /// menu copies it without markdown syntax, or as markdown; Select Text opens the message
    /// in a selectable text view; a fenced code block has its own Copy.
    func testMessagesCopyAndSelectText() {
        let app = launch(copyFixture: true)
        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        let paragraph = app.staticTexts["Copy this reply, then paste it."].firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 12), app.debugDescription)
        for _ in 0..<4 where !paragraph.isHittable { chat.swipeDown() }
        XCTAssertTrue(paragraph.isHittable, app.debugDescription)
        XCTAssertNil(copiedText(app), "precondition: nothing copied yet")

        let codeCopy = app.buttons["gram-code-copy"].firstMatch
        XCTAssertTrue(codeCopy.exists, "a chat code block has the Gram code block's Copy: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["swift"].exists, "a multi-line code block names its language")
        codeCopy.tap()
        expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: codeCopy)
        waitForExpectations(timeout: 5)
        record(app, "Chat code block with language header and Copy")

        let copy = openMenu(app, on: paragraph, entry: "Copy")
        XCTAssertTrue(app.buttons["Copy as Markdown"].exists, "a reply offers Copy as Markdown")
        XCTAssertTrue(app.buttons["Select Text"].exists, "a reply offers Select Text")
        record(app, "Reply message menu")
        copy.tap()
        waitForCopied(app, "Copy this reply, then paste it.\n\nlet copied = true\nprint(copied)")
        XCTAssertTrue(app.buttons["Copy as Markdown"].waitForNonExistence(timeout: 5), "the menu closes after Copy")

        openMenu(app, on: paragraph, entry: "Copy as Markdown").tap()
        waitForCopied(app, "Copy **this** reply, then *paste* it.\n\n```swift\nlet copied = true\nprint(copied)\n```")
        XCTAssertTrue(app.buttons["Select Text"].waitForNonExistence(timeout: 5), "the menu closes after Copy as Markdown")

        openMenu(app, on: paragraph, entry: "Select Text").tap()
        let textView = app.textViews["chat-select-text"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5), app.debugDescription)
        let selectable = textView.value as? String ?? ""
        XCTAssertTrue(selectable.contains("Copy this reply, then paste it."), "the sheet shows the reply: \(selectable)")
        XCTAssertTrue(selectable.contains("let copied = true\nprint(copied)"), "the sheet shows the code: \(selectable)")
        XCTAssertFalse(selectable.contains("**"), "the sheet shows the reply as read, not its markdown: \(selectable)")
        record(app, "Select Text sheet with the reply")
        app.buttons["chat-select-text-done"].tap()
        XCTAssertTrue(textView.waitForNonExistence(timeout: 5), "Done closes the Select Text sheet")

        let bubble = app.staticTexts["Check typography and wrapped tables."].firstMatch
        for _ in 0..<6 where !bubble.isHittable { chat.swipeDown() }
        XCTAssertTrue(bubble.isHittable, app.debugDescription)
        let bubbleCopy = openMenu(app, on: bubble, entry: "Copy")
        XCTAssertFalse(app.buttons["Copy as Markdown"].exists, "a prompt is copied as typed, with no markdown variant")
        XCTAssertTrue(app.buttons["Select Text"].exists, "a prompt offers Select Text")
        bubbleCopy.tap()
        waitForCopied(app, "Check typography and wrapped tables.")

        // The chat's text-size control grows the code block's code too, as it does the
        // rest of the reply (GramCodeBlock's `textScale`; Gram itself keeps 1).
        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
        let code = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "let copied = true")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), app.debugDescription)
        let codeHeight = code.frame.height
        for _ in 0..<4 {
            app.buttons["terminal-actions"].tap()
            app.buttons["terminal-font-increase"].tap()
            dismissTextSizeMenu(app)
        }
        let deadline = Date().addingTimeInterval(5)
        while code.frame.height <= codeHeight + 4, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(code.frame.height, codeHeight + 4,
                             "four text-size steps grow the chat code block's code (was \(codeHeight) pt)")
        record(app, "Chat code block follows the chat text size")
        app.buttons["terminal-actions"].tap()
        app.buttons["Reset"].tap()
        dismissTextSizeMenu(app)
    }

    // MARK: Chat column width (#523 items 2 and 12)

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Polls `read` until `done` holds or `timeout` passes; returns the last reading.
    @discardableResult
    private func settle(within timeout: TimeInterval = 5, _ read: () -> CGFloat, until done: (CGFloat) -> Bool) -> CGFloat {
        var value = read()
        let deadline = Date().addingTimeInterval(timeout)
        while !done(value), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            value = read()
        }
        return value
    }

    /// A real touch drag on the column's right-edge handle: press just inside the edge (still
    /// on the handle's band, and clear of a window edge when the column is Full) at the chat's
    /// mid-height, then drag `dx` points sideways.
    private func dragRightEdge(_ app: XCUIApplication, by dx: CGFloat) {
        let column = element(app, "chat-column").frame
        let chat = element(app, "chat-view").frame
        let origin = app.frame.origin
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: column.maxX - 6 - origin.x, dy: chat.midY - origin.y))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    /// The Chat-mode composer card sits under the column at its width (less the card's 12 pt
    /// inset on each side), centred on it.
    private func assertComposerMatchesColumn(_ app: XCUIApplication, _ moment: String) {
        let column = element(app, "chat-column").frame
        let card = element(app, "composer-card")
        XCTAssertTrue(card.exists, app.debugDescription)
        XCTAssertEqual(card.frame.width, column.width - 24, accuracy: 2, "\(moment): the composer takes the column's width")
        XCTAssertEqual(card.frame.midX, column.midX, accuracy: 2, "\(moment): the composer is centred under the column")
    }

    /// iPhone keeps today's layout: no handles, a full-width column and composer. iPad shows
    /// both handles, named for VoiceOver.
    func testChatWidthHandlesOnlyOnRegularWidth() {
        let app = launch()
        let chat = element(app, "chat-view")
        let column = element(app, "chat-column")
        XCTAssertTrue(column.waitForExistence(timeout: 10), app.debugDescription)
        let left = element(app, "chat-width-handle-left")
        let right = element(app, "chat-width-handle-right")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(right.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(left.exists, app.debugDescription)
            XCTAssertEqual(right.label, "Chat width")
            XCTAssertTrue((right.value as? String)?.hasSuffix("points") == true
                          || (right.value as? String)?.contains("points,") == true,
                          "the handle reads its width: \(String(describing: right.value))")
            if column.frame.width < chat.frame.width - 30 {
                XCTAssertEqual(left.frame.midX, column.frame.minX, accuracy: 1, "the left handle sits on the column's edge")
                XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the right handle sits on the column's edge")
            }
            assertComposerMatchesColumn(app, "iPad Chat")
            record(app, "iPad chat column with its edge handles")
        } else {
            XCTAssertFalse(left.exists, "no width handles on iPhone")
            XCTAssertFalse(right.exists, "no width handles on iPhone")
            XCTAssertEqual(column.frame.width, chat.frame.width, accuracy: 1, "the phone's column spans the chat")
            let card = element(app, "composer-card")
            XCTAssertTrue(card.exists, app.debugDescription)
            XCTAssertEqual(card.frame.width, chat.frame.width - 24, accuracy: 2, "the phone's composer keeps the full width")
            record(app, "iPhone chat keeps the full-width column and composer")
        }
    }

    /// Dragging the right edge resizes the column around its centre and the composer follows;
    /// near 720 it snaps to Readable; the width survives a relaunch; a double tap resets to Wide.
    func testDraggingTheChatEdgeResizesTheColumn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the chat width is resizable on regular width only")
        // Landscape gives the detail column room for Wide (1000) and a drag down to Readable.
        XCUIDevice.shared.orientation = .landscapeLeft
        rotated = true
        let hold = ["HERDR_CHAT_WIDTH_READOUT_HOLD": "8"]
        let app = launch(environment: hold)
        let chat = element(app, "chat-view")
        let column = element(app, "chat-column")
        let right = element(app, "chat-width-handle-right")
        XCTAssertTrue(right.waitForExistence(timeout: 10), app.debugDescription)
        var available = settle(within: 8, { chat.frame.width }, until: { $0 > 1000 })
        // An earlier class may leave the app in a smaller window (iPadOS restores its size):
        // minimising the sidebar gives the chat the window's width.
        if available < 780 {
            let minimise = app.buttons.matching(NSPredicate(format: "label == %@", "Minimise sidebar")).firstMatch
            XCTAssertTrue(minimise.waitForExistence(timeout: 5), "chat only \(available) pt wide: \(app.debugDescription)")
            minimise.tap()
            minimisedSidebar = true
            available = settle(within: 8, { chat.frame.width }, until: { $0 >= 780 })
        }
        XCTAssertGreaterThanOrEqual(available, 780, "the chat needs room to drag down to Readable: \(app.debugDescription)")
        let wide = min(1000, available)
        let initial = settle({ column.frame.width }, until: { abs($0 - wide) < 0.5 })
        XCTAssertEqual(initial, wide, accuracy: 0.5, "the column starts Wide (or Full when narrower)")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1, "the column is centred")
        if initial < available - 30 {
            XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the handle sits on the column's edge")
        }
        assertComposerMatchesColumn(app, "Wide")
        let initialMinX = column.frame.minX
        record(app, "Chat column at Wide (\(Int(initial)) pt of \(Int(available)))")

        // Inwards: both edges move in by the drag, so the column narrows by twice it and stays
        // centred. The target stays clear of Readable's snap zone.
        let shrink: CGFloat = abs(initial - 120 - 720) <= 16 ? 200 : 120
        dragRightEdge(app, by: -shrink / 2)
        let narrowed = settle({ column.frame.width }, until: { abs($0 - (initial - shrink)) <= 4 })
        XCTAssertEqual(narrowed, initial - shrink, accuracy: 4, "each point of drag narrows the column by two")
        XCTAssertEqual(column.frame.minX - initialMinX, shrink / 2, accuracy: 2, "the left edge moves in with the right")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1, "the column stays centred")
        XCTAssertEqual(right.frame.midX, column.frame.maxX, accuracy: 1, "the handle follows the edge")
        assertComposerMatchesColumn(app, "After a drag")
        record(app, "Chat column narrowed by dragging its right edge")

        // Aim at 714: within 12 pt of Readable, so it lands on exactly 720.
        dragRightEdge(app, by: -(narrowed - 714) / 2)
        let readable = settle({ column.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(readable, 720, accuracy: 0.5, "a width near 720 snaps to Readable")
        let readout = app.staticTexts["chat-width-readout"]
        XCTAssertTrue(readout.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(readout.label, "720 pt · Readable")
        XCTAssertEqual(right.value as? String, "720 points, Readable")
        XCTAssertEqual(column.frame.midX, chat.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(app, "Readable")
        record(app, "Chat column snapped to Readable with its readout")

        // Remembered: a relaunch that keeps the stored width shows Readable again.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
        let again = launch(environment: hold.merging(["HERDR_MOCK_CHAT_WIDTH": "keep"]) { _, new in new })
        let againChat = element(again, "chat-view")
        let againColumn = element(again, "chat-column")
        let againRight = element(again, "chat-width-handle-right")
        XCTAssertTrue(againRight.waitForExistence(timeout: 10), again.debugDescription)
        let kept = settle({ againColumn.frame.width }, until: { abs($0 - 720) < 0.5 })
        XCTAssertEqual(kept, 720, accuracy: 0.5, "the chosen width survives a relaunch")
        assertComposerMatchesColumn(again, "After relaunch")
        record(again, "Readable remembered across a relaunch")

        // A double tap on a handle resets to Wide (Full when the chat is narrower).
        againRight.doubleTap()
        let againWide = min(1000, againChat.frame.width)
        let reset = settle({ againColumn.frame.width }, until: { abs($0 - againWide) < 0.5 })
        XCTAssertEqual(reset, againWide, accuracy: 0.5, "a double tap resets to Wide")
        XCTAssertEqual(againColumn.frame.midX, againChat.frame.midX, accuracy: 1)
        assertComposerMatchesColumn(again, "After reset")
        if againChat.frame.width > 1000.5 {
            XCTAssertEqual(againRight.value as? String, "1000 points, Wide")
        }
        record(again, "Double tap resets the chat column to Wide")
    }

    /// Set by the width test: puts the iPad back as the other tests expect it, pass or fail.
    private var rotated = false
    private var minimisedSidebar = false

    override func tearDown() {
        if minimisedSidebar {
            let app = XCUIApplication()
            let expand = app.buttons.matching(NSPredicate(format: "label == %@", "Expand sidebar")).firstMatch
            if app.state == .runningForeground, expand.exists { expand.tap() }
            minimisedSidebar = false
        }
        if rotated {
            XCUIDevice.shared.orientation = .portrait
            rotated = false
        }
        super.tearDown()
    }
}
