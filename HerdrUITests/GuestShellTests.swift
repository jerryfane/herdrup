import XCTest

/// The guest shell (#312) over GuestMockTransport: accepting an invite, a home that
/// shows only the shared agent with no Gram tab, and leaving the share.
final class GuestShellTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(_ mock: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mock
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAcceptLandsOnGuestHome() {
        let app = launch("guestaccept")

        XCTAssertTrue(app.staticTexts["Jerry shared llm-opt with you"].waitForExistence(timeout: 10),
                      "the accept screen should say who shared which agent")
        XCTAssertTrue(app.staticTexts["plotarmordev"].exists, "the name the guest appears as should show")
        attach(app, "guest-accept")

        app.buttons["guest-accept"].tap()

        XCTAssertTrue(app.staticTexts["guest-home-title"].waitForExistence(timeout: 10),
                      "accepting should land on guest home")
        XCTAssertEqual(app.staticTexts["guest-home-title"].label, "Jerry's Mac Studio")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10),
                      "guest home should list the shared agent")
    }

    func testHomeShowsOnlyTheSharedAgentAndNoGram() {
        let app = launch("guest")

        let row = app.buttons["guest-agent-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the shared agent's row should render")
        XCTAssertTrue(row.label.contains("llm-opt"), "the row should be llm-opt, got \(row.label)")
        XCTAssertTrue(app.staticTexts["Shared by Jerry · 1 agent"].exists)
        // The mock agent.list also returns jarvis; only the shared agent may render.
        XCTAssertEqual(app.buttons.matching(identifier: "guest-agent-row").count, 1)
        XCTAssertFalse(app.staticTexts["jarvis"].exists, "an agent that was not shared must not render")

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.buttons.count, 2, "the guest tab bar should hold only Agents and Settings")
        XCTAssertTrue(tabs.buttons["Agents"].exists)
        XCTAssertTrue(tabs.buttons["Settings"].exists)
        XCTAssertFalse(tabs.buttons["Gram"].exists, "a guest has no Gram tab")
        attach(app, "guest-home")
    }

    func testLeaveRemovesTheShare() {
        let app = launch("guest")
        XCTAssertTrue(app.buttons["guest-agent-row"].waitForExistence(timeout: 10))

        // A tap on the tab bar right after launch can be swallowed while it settles, so
        // tap until the tab reports selected.
        let settingsTab = app.tabBars.firstMatch.buttons["Settings"]
        let selected = NSPredicate(format: "isSelected == true")
        for _ in 0..<3 where !settingsTab.isSelected {
            settingsTab.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: settingsTab)], timeout: 3)
        }
        let leave = app.buttons["guest-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "guest Settings should offer Leave share")
        XCTAssertTrue(app.staticTexts["guest-settings-fingerprint"].label.hasPrefix("SHA256:"),
                      "Settings should show this phone's key fingerprint")
        attach(app, "guest-settings")
        leave.tap()

        // The confirmation's destructive button, not the row that opened it.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Leave share' AND identifier != 'guest-leave'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "leaving should ask for confirmation")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["guest-home-title"].waitForNonExistence(timeout: 5),
                      "leaving should close guest home")
        XCTAssertTrue(app.staticTexts["Scan pairing code"].waitForExistence(timeout: 5),
                      "with no machines left the phone should be back on onboarding")
        XCTAssertFalse(app.buttons["shared-machine-row"].exists, "the share should be gone")
    }
}
