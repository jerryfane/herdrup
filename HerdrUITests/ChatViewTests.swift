import UIKit
import XCTest

/// The omp Chat view (#481 owner, #482 guest), against `ChatMockTransport` (the `chatview`
/// mock: herdr-app is an omp agent blocked on "Merge #305 and update the servers?",
/// keephair a Claude agent) and `GuestMockTransport` with the guest transcript
/// (`guestchat`). Runs on iPhone and iPad alike.
final class ChatViewTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// `HERDR_MOCK_STILL` keeps every agent off "working" and `HERDR_STEADY_CARET` stops the
    /// hidden terminal's caret: a working spinner, a pulse or a blinking caret never lets
    /// XCUITest's idle wait finish (a minute per action). `still: false` keeps the working
    /// agents (keephair is only listed outside the Idle group while it works).
    private func launch(_ mock: String, _ environment: [String: String] = [:], still: Bool = true) -> XCUIApplication {
        var quiet = ["HERDR_STEADY_CARET": "1"]
        if still { quiet["HERDR_MOCK_STILL"] = "1" }
        return XCUIApplication.launched(mock: mock, environment: quiet.merging(environment) { _, new in new })
    }

    private func openAgent(_ name: String, in app: XCUIApplication) {
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 12), "the home should list \(name)")
        row.tap()
    }

    private func turns(_ chat: XCUIElement) -> Int {
        Int((chat.value as? String ?? "").replacingOccurrences(of: "turns=", with: "")) ?? -1
    }

    /// The last on-screen button identified `id` (the chat is a plain stack: older turns'
    /// rows exist above the viewport too).
    private func visibleButton(_ id: String, in app: XCUIApplication) -> XCUIElement? {
        var found: XCUIElement?
        _ = poll(8, every: 0.3) {
            let all = app.buttons.matching(identifier: id).allElementsBoundByIndex
            found = all.last(where: { $0.isHittable })
            return found != nil
        }
        return found
    }

    // MARK: - Owner

    /// An omp agent opens in Chat by default; the switch flips to the terminal and back.
    func testOmpAgentOpensInChatAndSwitches() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)

        let chat = app.scrollViews["chat-view"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "an omp agent should open in Chat")
        XCTAssertTrue(app.buttons["chat-switch-chat"].isSelected, "Chat should be the selected segment")
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].waitForExistence(timeout: 8),
                      "the pending question should show as a card")
        attach(app, "chat-owner")

        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 6), "Terminal should hide the chat")
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
        attach(app, "chat-owner-terminal")

        app.buttons["chat-switch-chat"].tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 6), "Chat should come back")
    }

    /// A Claude agent has no Chat: no switch, the terminal as before.
    func testClaudeAgentHasNoSwitch() {
        let app = launch("chatview", still: false)
        openAgent("keephair", in: app)
        XCTAssertTrue(app.terminalSurface.waitForExistence(timeout: 10), "a Claude agent opens its terminal")
        XCTAssertFalse(app.buttons["chat-switch-chat"].exists, "only omp agents get the switch")
        XCTAssertFalse(app.scrollViews["chat-view"].exists)
    }

    /// Settings shows the default (Chat); with Terminal chosen, omp agents open in the
    /// terminal, the switch still offering Chat.
    func testSettingsDefaultDecidesWhereOmpOpens() {
        let app = launch("chatview")
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The split view's "Text & typing" page holds it on iPad.
            let page = app.buttons["Text & typing"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 6))
            page.tap()
        }
        let picker = app.segmentedControls["settings-omp-opens-in"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "Settings should offer the omp default")
        XCTAssertTrue(picker.buttons["Chat"].isSelected, "Chat should be the default")
        picker.buttons["Terminal"].tap()
        XCTAssertTrue(picker.buttons["Terminal"].isSelected)
        attach(app, "chat-settings")

        let terminalFirst = launch("chatview", ["HERDR_MOCK_CHAT_OPENS_IN": "terminal"])
        openAgent("herdr-app", in: terminalFirst)
        let terminal = terminalFirst.buttons["chat-switch-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "an omp agent still offers the switch")
        XCTAssertTrue(terminal.isSelected, "with Terminal the default, the page opens in the terminal")
        XCTAssertFalse(terminalFirst.scrollViews["chat-view"].exists)
    }

    /// Scrolling to the top loads older turns.
    func testScrollingUpLoadsOlderTurns() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let chat = app.scrollViews["chat-view"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8, every: 0.3) { self.turns(chat) > 0 }, "the newest page should load")
        let first = turns(chat)
        var loaded = false
        for _ in 0..<12 where !loaded {
            chat.swipeDown(velocity: .fast)
            loaded = poll(2, every: 0.3) { self.turns(chat) > first }
        }
        XCTAssertTrue(loaded, "scrolling to the top should load an older page (had \(first) turns)")
    }

    /// The thought line and the steps line expand.
    func testThoughtAndStepsExpand() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        XCTAssertTrue(app.scrollViews["chat-view"].waitForExistence(timeout: 10))

        guard let thought = visibleButton("chat-thought", in: app) else {
            return XCTFail("a work group on screen should show its thought")
        }
        thought.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-thought-open"].waitForExistence(timeout: 4),
                      "tapping the thought should show it whole")

        guard let steps = visibleButton("chat-steps", in: app) else {
            return XCTFail("a work group on screen should summarise its steps")
        }
        steps.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-steplist"].waitForExistence(timeout: 4),
                      "tapping the steps line should list them")
        attach(app, "chat-expanded")
    }

    /// Tapping an option answers the question; the card then shows the choice.
    func testAnsweringTheQuestion() {
        let app = launch("chatview")
        openAgent("herdr-app", in: app)
        let option = app.buttons["chat-ask-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "the owner should get answer buttons")
        option.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-chosen"].waitForExistence(timeout: 8),
                      "the card should show the answer")
        XCTAssertFalse(app.buttons["chat-ask-option-0"].exists, "an answered question offers no buttons")
    }

    /// A server that cannot answer through the UI sends the owner to the terminal.
    func testRefusedAnswerOffersTheTerminal() {
        let app = launch("chatview", ["HERDR_MOCK_CHAT_ANSWER": "ask_ui_not_found"])
        openAgent("herdr-app", in: app)
        let option = app.buttons["chat-ask-option-0"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        let terminal = app.buttons["chat-ask-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "a refusal should offer Answer in Terminal")
        terminal.tap()
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected, "Answer in Terminal should switch to it")
    }

    // MARK: - Guest

    /// A shared omp agent on a host serving guests its transcript: the Chat tab, first;
    /// the question read-only; no note cards.
    func testGuestChatTabIsReadOnly() {
        let app = launch("guestchat")
        let tab = app.buttons["guest-tab-chat"]
        XCTAssertTrue(tab.waitForExistence(timeout: 12), "the guest should get a Chat tab")
        XCTAssertTrue(tab.isSelected, "Chat should be the guest's first tab")
        XCTAssertTrue(app.buttons["guest-tab-terminal"].exists)
        let chat = app.scrollViews["chat-view"]
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-waiting"].waitForExistence(timeout: 8),
                      "the guest sees the question waiting for the owner")
        XCTAssertFalse(app.buttons["chat-ask-option-0"].exists, "a guest cannot answer")
        XCTAssertFalse(app.descendants(matching: .any)["chat-note"].exists, "guests see no note cards")
        attach(app, "chat-guest")

        app.buttons["guest-tab-terminal"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 6))
        tab.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 6))
        let refused = app.descendants(matching: .any)["guest-forbidden-calls"].label
        XCTAssertFalse(refused.contains("agent.transcript"), "the transcript is on the guest allowlist: \(refused)")
    }

    /// A host that predates guest transcripts: no Chat tab, the terminal as before.
    func testGuestHasNoChatTabOnAnOlderHost() {
        let app = launch("guestpane")
        XCTAssertTrue(app.otherElements["guest-terminal"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["guest-tab-chat"].exists, "no capability, no Chat tab")
        XCTAssertFalse(app.scrollViews["chat-view"].exists)
    }

    // MARK: - Screenshots

    /// The mockups' four screens (iPhone/iPad × own/shared), for the visual comparison.
    /// Not still, so the iPad sidebar shows keephair working as in the mockup; the guest's
    /// host also offers Gram (its tab and unread badge are in the mockup).
    func testScreenshotOwnChat() {
        let app = launch("chatview", still: false)
        openAgent("herdr-app", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask"].waitForExistence(timeout: 10))
        sleep(2)
        attach(app, "shot-own")
    }

    func testScreenshotSharedChat() {
        let app = launch("guestchat", ["HERDR_MOCK_GUEST_FEATURES": "gram"], still: false)
        XCTAssertTrue(app.descendants(matching: .any)["chat-ask-waiting"].waitForExistence(timeout: 15))
        sleep(2)
        attach(app, "shot-guest")
    }
}
