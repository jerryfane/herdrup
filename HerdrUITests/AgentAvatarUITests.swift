import XCTest

/// herdrup#538: agent pictures. The demo roster (MockWireFixtures.agentList) gives
/// clientloop the Tri mascot and discovery a photo; everyone else wears the default, Herdy.
/// `HERDR_MOCK_AVATARS` makes the mock daemon advertise `agent_avatar` and keeps choices in
/// a store that survives relaunch, like the server's `agent-avatars/index.json`.
final class AgentAvatarUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func avatar(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "agent-avatar-\(id)").firstMatch
    }

    /// The row shows `mascot`: by the avatar's own identifier, or, where the row's button
    /// merges its children into one element, by the avatar's name in the row's label.
    private func row(_ row: XCUIElement, shows mascot: String, in app: XCUIApplication,
                     timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if row.exists, row.label.contains(mascot.capitalized) { return true }
            if avatar(app, mascot).exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    func testAnAgentWithoutAChoiceWearsHerdy() {
        let app = XCUIApplication.launched(mock: "list")
        let jarvis = app.descendants(matching: .any)["agent-row-w1:p1"]
        XCTAssertTrue(jarvis.waitForExistence(timeout: 10))
        XCTAssertTrue(row(jarvis, shows: "herdy", in: app), "an agent with no avatar shows Herdy, got \(jarvis.label)")
        XCTAssertFalse(jarvis.label.contains("Bot"))
        // An older mock daemon (no agent_avatar) offers no Avatar… entry.
        jarvis.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Avatar…"].exists, "the menu must hide Avatar… without server support")
    }

    func testChoosingBotChangesTheRowPersistsAndShowsInGram() {
        var app = XCUIApplication.launched(mock: "list", environment: ["HERDR_MOCK_AVATARS": "reset"])
        var vetrina = app.descendants(matching: .any)["agent-row-w1:p2"]
        XCTAssertTrue(vetrina.waitForExistence(timeout: 10))
        XCTAssertTrue(row(vetrina, shows: "herdy", in: app), "vetrina starts on the default")

        // Long-press → Avatar… → Bot. The capability probe lands with the first load.
        var opened = false
        for _ in 0..<5 where !opened {
            vetrina.press(forDuration: 1.0)
            let item = app.buttons["Avatar…"]
            if item.waitForExistence(timeout: 3) {
                item.tap()
                opened = true
            } else {
                app.tap()   // dismiss the menu and retry once the probe has answered
                Thread.sleep(forTimeInterval: 1)
            }
        }
        XCTAssertTrue(opened, "the owner's row menu should offer Avatar…")
        XCTAssertTrue(app.staticTexts["Guests you share this agent with will see this picture."].waitForExistence(timeout: 5))
        let bot = app.descendants(matching: .any)["agent-avatar-choice-bot"]
        XCTAssertTrue(bot.waitForExistence(timeout: 5))
        bot.tap()
        XCTAssertTrue(avatar(app, "bot").waitForExistence(timeout: 5), "the sheet's preview should show Bot")
        app.buttons["agent-avatar-done"].tap()
        XCTAssertTrue(row(vetrina, shows: "bot", in: app), "the row should show Bot, got \(vetrina.label)")

        // Relaunch: the mock daemon kept the choice, as the server does.
        app.terminate()
        app = XCUIApplication.launched(mock: "list", environment: ["HERDR_MOCK_AVATARS": "keep"])
        vetrina = app.descendants(matching: .any)["agent-row-w1:p2"]
        XCTAssertTrue(vetrina.waitForExistence(timeout: 10))
        XCTAssertTrue(row(vetrina, shows: "bot", in: app), "Bot should survive a relaunch, got \(vetrina.label)")

        // Gram is name-keyed: vetrina's bubbles wear the same mascot.
        let gram = app.buttons["Gram"].firstMatch
        XCTAssertTrue(gram.waitForExistence(timeout: 10))
        gram.tap()
        XCTAssertTrue(app.descendants(matching: .any)["gram-bubble-g1"].waitForExistence(timeout: 10))
        XCTAssertTrue(avatar(app, "bot").waitForExistence(timeout: 10), "a Gram bubble from vetrina should show Bot")
        XCTAssertTrue(avatar(app, "tri").exists, "a Gram bubble from clientloop should show its Tri")
    }

    func testAGuestSeesTheOwnersMascotAndCannotEditIt() {
        let app = XCUIApplication.launched(mock: "guest")
        let shared = app.buttons["guest-agent-row"]
        XCTAssertTrue(shared.waitForExistence(timeout: 10))
        XCTAssertTrue(row(shared, shows: "pip", in: app), "the guest should see the owner's Pip, got \(shared.label)")

        shared.tap()
        // The guest pane's ⋯ (GuestPaneView), not the owner's `terminal-actions`.
        let actions = app.buttons["guest-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the guest pane should offer ⋯")
        actions.tap()
        // The menu is open once one of its known entries shows; only then does the missing
        // Avatar… entry mean anything.
        let entries = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                       ["guest-font-increase", "guest-notifications"]))
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 5), "the guest ⋯ menu should open")
        XCTAssertFalse(app.buttons["agent-avatar-edit"].exists, "guests have no Avatar… entry")
        XCTAssertFalse(app.buttons["Avatar…"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["guest-forbidden-calls"].label, "",
                       "a guest never calls agent.avatar.set")
    }
}
