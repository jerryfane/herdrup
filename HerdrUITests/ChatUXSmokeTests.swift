import XCTest

final class ChatUXSmokeTests: XCTestCase {
    private func launch(failingRefresh: Bool = false, pendingQuestion: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.launched(mock: "chatview", environment: [
            "HERDR_STEADY_CARET": "1", "HERDR_MOCK_STILL": "1", "HERDR_CHAT_UX_SMOKE": "1",
            "HERDR_CHAT_UX_FAIL_REFRESH": failingRefresh ? "1" : "0",
            "HERDR_CHAT_UX_PENDING_QUESTION": pendingQuestion ? "1" : "0"
        ])
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
        XCTAssertTrue(app.buttons["chat-jump-latest"].waitForExistence(timeout: 5), app.debugDescription)
        print("JUMP_BEFORE \(app.buttons["chat-jump-latest"].debugDescription)")
        app.buttons["chat-jump-latest"].tap()
        XCTAssertTrue(app.staticTexts["chat-model"].waitForExistence(timeout: 5), app.debugDescription)
        record(app, "Tail position immediately after jumping")
        if app.buttons["chat-jump-latest"].exists {
            print("JUMP_AFTER \(app.buttons["chat-jump-latest"].debugDescription)")
        } else {
            print("JUMP_AFTER control removed")
        }
        let modelVisible = NSPredicate(format: "hittable == true")
        expectation(for: modelVisible, evaluatedWith: app.staticTexts["chat-model"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["chat-jump-latest"].exists, "The control must disappear at the measured tail")
        record(app, "Centered clear-glass jump returns to latest above composer fade")
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

    func testSearchPagingPreservesSelectedMatchAndLoadedScope() {
        let app = launch()
        app.buttons["terminal-find"].tap()
        let field = app.textFields["terminal-find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Synthetic question")
        let count = app.staticTexts["terminal-find-count"]
        expectation(for: NSPredicate(format: "label == %@", "1/18"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Searching loaded history"].isHittable)
        app.buttons["Load older"].tap()
        expectation(for: NSPredicate(format: "label == %@", "21/38"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.buttons["Load older"].tap()
        expectation(for: NSPredicate(format: "label == %@", "23/40"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Load older"].exists)
        app.buttons["terminal-refresh"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "23/40", "Refresh must retain paged history and the same selected prompt")
        record(app, "Loaded-history search expands to all forty prompts and preserves selection across refresh")
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
        XCTAssertFalse(app.buttons["chat-note-done"].exists, "Done must close only the question sheet")
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
}
