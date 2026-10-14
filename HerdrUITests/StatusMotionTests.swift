import XCTest

/// Status shapes that nobody can see must not move: a repeating SwiftUI animation drives the
/// display link every frame even behind another view (#427: an idle Mac app at 66% CPU).
final class StatusMotionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The DEBUG `status-motion` probe: how many `TurningRing`s and `PulsingDot`s are moving
    /// (its label; polled every 250 ms, so read it after a pause).
    private func moving(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["status-motion"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG status-motion probe should be present")
        return Int(probe.label) ?? -1
    }

    /// The list mock has one working agent, herdr-app: its roster ring turns, its open pane's
    /// dot pulses. Covered by the pane (iPhone) the ring stops; behind Gram and Settings the
    /// kept-alive pane's dot stops too. Back on Agents, and back from the Home screen, the
    /// same shapes move again.
    func testHiddenStatusShapesHoldStill() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        // The open pane's blinking caret never lets XCUITest's idle wait finish (60 s a tap).
        // The status shapes' SwiftUI animations do not hold it up.
        app.launchEnvironment["HERDR_STEADY_CARET"] = "1"
        app.launch()
        let row = app.staticTexts["herdr-app"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the roster should list the working agent")
        sleep(1)
        XCTAssertEqual(moving(app), 1, "the working row's ring turns on the roster")

        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10),
                      "the pane should open")
        sleep(1)
        // iPad / Mac keep the roster beside the pane: its ring and the pane's dot. iPhone covers
        // the roster: the dot alone.
        XCTAssertEqual(moving(app), pad ? 2 : 1, "only what is on screen moves with the pane open")

        if !pad { app.buttons["Back"].firstMatch.tap() }
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(moving(app), 0, "nothing moves behind Gram: the kept-alive pane holds still")

        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(moving(app), 0, "nothing moves behind Settings")

        app.buttons["Agents"].firstMatch.tap()
        sleep(1)
        // iPad / Mac: the roster and the still-fronted pane come back together. iPhone: the roster.
        XCTAssertEqual(moving(app), pad ? 2 : 1, "back on Agents, what is on screen moves again")
        if !pad {
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10),
                          "the kept-alive pane should come back to the front")
            sleep(1)
            XCTAssertEqual(moving(app), 1, "the kept-alive pane's dot pulses again in front")
        }

        // Everything holds still while the scene is not active, and resumes together.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        sleep(1)
        XCTAssertEqual(moving(app), pad ? 2 : 1, "back from the Home screen, the same shapes move again")
        app.terminate()
    }
}
