import UIKit
import XCTest

/// The guest's pane, against GuestMockTransport (a host that refuses anything a guest may
/// not call and records it). The `guest-forbidden-calls` probe lists those refused calls.
final class GuestPaneTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

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

    /// The terminal's `terminal-grid-probe`: "cols=C rows=R font=F fill=X".
    private func grid(_ app: XCUIApplication) -> (cols: Int, font: Double, fill: Double)? {
        let probe = app.descendants(matching: .any)["terminal-grid-probe"]
        guard probe.exists else { return nil }
        var fields: [String: String] = [:]
        for pair in probe.label.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let cols = fields["cols"].flatMap({ Int($0) }),
              let font = fields["font"].flatMap({ Double($0) }),
              let fill = fields["fill"].flatMap({ Double($0) }) else { return nil }
        return (cols, font, fill)
    }

    /// Polls the grid probe until `condition` holds; fails with the last reading otherwise.
    @discardableResult
    private func waitForGrid(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 10,
                             _ condition: ((cols: Int, font: Double, fill: Double)) -> Bool)
        -> (cols: Int, font: Double, fill: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = grid(app)
        while Date() < deadline {
            if let reading = last, condition(reading) { return reading }
            Thread.sleep(forTimeInterval: 0.25)
            last = grid(app)
        }
        XCTFail("\(what): last grid \(String(describing: last))")
        return last ?? (0, 0, 0)
    }

    /// Reported by the guest: fitted to a desktop-wide terminal, the text was unreadable and
    /// could not be changed. The guest's terminal now proposes the grid that fits its own text
    /// size, and A+ makes that grid narrower; the agent's stream follows, still without the
    /// terminal taking any input.
    func testLargerTextResizesTheAgentsTerminal() {
        let app = launch("guestpane")
        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        // The mock host's pane starts 120 columns wide; the guest's first proposal replaces it
        // with the grid that fits the guest's screen at the default text size.
        let before = waitForGrid(app, "the guest's fit should replace the desktop's 120 columns") {
            $0.cols != 120 && $0.font == 12.5 && $0.fill <= 1.0
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(app, "guest-resize-before")

        let larger = app.buttons["guest-font-increase"]
        XCTAssertTrue(larger.waitForExistence(timeout: 5), "the guest pane should offer A+")
        larger.tap()
        let after = waitForGrid(app, "A+ should make the agent's grid narrower") {
            $0.cols < before.cols && $0.font > before.font
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(app, "guest-resize-after")

        app.buttons["guest-font-decrease"].tap()
        waitForGrid(app, "A− should widen the agent's grid again") {
            $0.cols > after.cols && $0.font < after.font
        }
        XCTAssertEqual(app.keyboards.count, 0, "resizing must not raise a keyboard")
        XCTAssertEqual(forbiddenCalls(app), "", "resizing is a call a guest may make")
    }

    /// A guest on iPad re-proposes when the pane's width changes, as the owner's pane does.
    func testRotationReproposesTheGuestsGrid() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPhone is portrait-only; rotation re-proposes on iPad")
        }
        let app = launch("guestpane")
        let portrait = waitForGrid(app, "the guest's first fit") { $0.cols != 120 }
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForGrid(app, "landscape should propose a wider grid") { $0.cols > portrait.cols }
        attachScreenshot(app, "guest-resize-landscape")
    }

    /// A host older than guest resizing refuses `pane.set_pty_size` with `guest_forbidden`. The
    /// pane keeps today's fit-to-width view, drops the size controls, and never asks again:
    /// not on a retry, not on a relayout.
    func testOldHostKeepsTheFitToWidthViewAndStopsProposing() {
        let app = launch("guestoldhost")
        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["View-only · this host doesn't support guest resizing"]
            .waitForExistence(timeout: 10), "the pane should say why the size can't change")
        XCTAssertFalse(app.buttons["guest-font-increase"].exists, "no size controls on an older host")
        XCTAssertFalse(app.buttons["guest-font-decrease"].exists, "no size controls on an older host")
        // Fitted: the widest whole-pixel cell that keeps all 120 columns inside the width.
        let fitsWidth = { (reading: (cols: Int, font: Double, fill: Double)) -> Bool in
            let slack = Double(reading.cols) / Double(UIScreen.main.scale * terminal.frame.width)
            return reading.cols == 120 && reading.fill <= 1.0 && reading.fill > 1.0 - slack
        }
        waitForGrid(app, "the host's 120 columns should fill the width", fitsWidth)
        // Anything that would re-propose: a rotation on iPad, a keyboard raising and dropping.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        XCUIDevice.shared.orientation = .portrait
        let input = app.textViews["guest-composer-input"]
        input.tap()
        Thread.sleep(forTimeInterval: 1)
        if app.buttons["guest-keyboard-button"].exists { app.buttons["guest-keyboard-button"].tap() }
        Thread.sleep(forTimeInterval: 3)
        waitForGrid(app, "the fallback should still fit the width", fitsWidth)
        attachScreenshot(app, "guest-resize-old-host")
        XCTAssertEqual(forbiddenCalls(app), "pane.set_pty_size",
                       "one refusal, then no further set_pty_size calls")
    }

    /// Watching never sends anything a guest may not send: no keyboard from the terminal, no
    /// quick keys, and a sent message goes out as a prompt.
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

    /// Reported on TestFlight 176: with the keyboard up, the guest composer (attach, mic,
    /// send) had no way to put it away, and the view-only terminal takes no taps. It must
    /// offer the standard composer's collapse button, and tapping it hides the keyboard.
    func testKeyboardCanBeDismissedFromTheComposer() throws {
        let app = launch("guestpane")
        let input = app.textViews["guest-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let collapse = app.buttons["guest-keyboard-button"]
        XCTAssertFalse(collapse.exists, "no collapse button while the keyboard is down")

        input.tap()
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5), keyboard.frame.height >= 150 else {
            throw XCTSkip("no full software keyboard on this destination; nothing to dismiss")
        }
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "a visible software keyboard must be dismissible")
        XCTAssertTrue(app.buttons["guest-attach-button"].exists, "the collapse button sits beside attach, not over it")
        Thread.sleep(forTimeInterval: 0.6)
        attachScreenshot(app, "guest-pane-keyboard")

        collapse.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "the collapse button puts the keyboard away")
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5), "the button goes with the keyboard")
    }

    /// A guest scrolls back past what streamed in since connecting: like the owner's pane, the
    /// guest's backfills the agent's scrollback with `agent.read`, and a swipe down on the
    /// terminal brings those older rows into view. The mock's stream paints only the current
    /// screen, so an `earlier NNN` row at the top can only have come from the backfill.
    func testSwipeRevealsScrollbackFromBeforeTheGuestConnected() {
        let app = launch("guestpane")

        let terminal = app.descendants(matching: .any)["guest-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let topRow = app.descendants(matching: .any)["terminal-top-row-probe"]
        XCTAssertTrue(topRow.waitForExistence(timeout: 10),
                      "the DEBUG top-row probe should publish once the stream seeds")
        // Let the backfill, the seed and the fit-to-width settle.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(topRow.label.contains("earlier"),
                       "the pane should open on the live screen, not in history: \(topRow.label)")

        let high = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let low = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(app, "guest-scrollback")
        XCTAssertTrue(topRow.label.contains("earlier"),
                      "a swipe down should reveal the backfilled scrollback: \(topRow.label)")
        XCTAssertEqual(forbiddenCalls(app), "", "the backfill is an allowed agent.read")
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
