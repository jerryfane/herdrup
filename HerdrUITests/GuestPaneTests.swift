import XCTest

/// The guest's pane, against GuestMockTransport (a host that refuses anything a guest may
/// not call and records it). The `guest-forbidden-calls` probe lists those refused calls.
final class GuestPaneTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ mock: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mock
        app.launch()
        return app
    }

    private func forbiddenCalls(_ app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["guest-forbidden-calls"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG forbidden-calls probe should exist")
        return probe.label
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Watching never sends anything a guest may not send: no keyboard from the terminal, no
    /// quick keys, no size proposals, and a sent message goes out as a prompt.
    func testTerminalIsViewOnly() {
        let app = launch("guestpane")

        XCTAssertTrue(app.staticTexts["WORKING"].waitForExistence(timeout: 10),
                      "the running agent's status pill should render")
        XCTAssertTrue(app.staticTexts["Shared by Jerry"].exists)
        XCTAssertTrue(app.staticTexts["Message llm-opt as plotarmordev"].exists,
                      "the composer should name the agent and the guest")
        XCTAssertTrue(app.staticTexts["guest-view-only-note"].exists)
        XCTAssertFalse(app.staticTexts["jarvis"].exists, "an agent not shared with the guest must not show")

        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        // Let the stream seed and the fit-to-width settle before the screenshot and taps.
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(app, "guest-pane")

        for _ in 0..<3 {
            terminal.tap()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertEqual(app.keyboards.count, 0, "tapping the terminal must not raise a keyboard")
        XCTAssertFalse(app.buttons["terminal-ctrl"].exists, "a guest pane has no quick keys")
        XCTAssertFalse(app.buttons["esc"].exists, "a guest pane has no quick keys")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(forbiddenCalls(app), "", "watching must not call anything a guest may not call")

        let input = app.textViews["guest-composer-input"]
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("rerun it on Q4 too")
        let send = app.buttons["guest-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "typing should offer Send")
        send.tap()
        XCTAssertTrue(app.staticTexts["Message llm-opt as plotarmordev"].waitForExistence(timeout: 5),
                      "a delivered message clears the composer")
        XCTAssertFalse(app.descendants(matching: .any)["guest-note"].exists, "the send should not fail")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(forbiddenCalls(app), "", "sending must go out as agent.prompt only")
    }

    /// With the agent out of the foreground the host refuses the guest: the pane says so and
    /// the composer can't be used.
    func testPausedAgentDisablesTheComposer() {
        let app = launch("guestpaused")

        XCTAssertTrue(app.staticTexts["llm-opt isn't running"].waitForExistence(timeout: 10),
                      "the paused message should render")
        XCTAssertTrue(app.staticTexts["NOT RUNNING"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists, "the composer should read Paused")
        XCTAssertFalse(app.buttons["guest-attach-button"].isEnabled, "attach is disabled while paused")
        XCTAssertFalse(app.buttons["guest-mic-button"].isEnabled, "dictation is disabled while paused")

        app.textViews["guest-composer-input"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(app.keyboards.count, 0, "the paused composer must not take input")
        attachScreenshot(app, "guest-paused")
    }

    /// A question only the owner can answer is called out above the composer.
    func testBlockedAgentShowsTheOwnerBanner() {
        let app = launch("guestblocked")

        XCTAssertTrue(app.staticTexts["llm-opt is asking a question only Jerry can answer"]
            .waitForExistence(timeout: 10), "the blocked banner should render")
        XCTAssertTrue(app.staticTexts["NEEDS JERRY"].exists)
        XCTAssertTrue(app.textViews["guest-composer-input"].exists, "the guest can still send a message")
        Thread.sleep(forTimeInterval: 2)
        attachScreenshot(app, "guest-blocked")
    }
}
