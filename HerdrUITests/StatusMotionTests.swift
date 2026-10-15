import XCTest

/// Status shapes that nobody can see must not move: a repeating SwiftUI animation drives the
/// display link every frame even behind another view (#427: an idle Mac app at 66% CPU).
/// Ones that can be seen must move, on screen, not just be counted (build 203).
final class StatusMotionTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// The DEBUG `status-motion` probe: how many `TurningRing`s and `PulsingDot`s are moving
    /// (its label; polled every 250 ms, so read it after a pause).
    private func moving(_ app: XCUIApplication) -> Int {
        let probe = app.descendants(matching: .any)["status-motion"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG status-motion probe should be present")
        return Int(probe.label) ?? -1
    }

    private func launchList() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        // The open pane's blinking caret never lets XCUITest's idle wait finish (60 s a tap).
        app.launchEnvironment["HERDR_STEADY_CARET"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["herdr-app"].firstMatch.waitForExistence(timeout: 15),
                      "the roster should list the working agent")
        return app
    }

    /// Whether `shape` visibly moves on screen: photographed every 0.25 s, some photo differs
    /// from the first. A ring that turns once per 0.9 s, or a dot that pulses every 0.8 s,
    /// never comes back to the same pixels at all five instants; a stuck one always does.
    /// Counting the motion in the view tree (`moving`) cannot see a motion that never starts.
    private func moves(_ shape: XCUIElement) -> Bool {
        XCTAssertTrue(shape.waitForExistence(timeout: 10), "the status shape should be on screen")
        let first = shape.screenshot()
        for _ in 0..<4 {
            usleep(250_000)
            if shape.screenshot().pngRepresentation != first.pngRepresentation { return true }
        }
        // Keep the photo of the stuck shape in the result bundle.
        let photo = XCTAttachment(screenshot: first)
        photo.name = "\(shape.identifier) held still"
        photo.lifetime = .keepAlways
        add(photo)
        return false
    }

    private func ring(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["status-ring"].firstMatch
    }

    private func dot(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["status-dot"].firstMatch
    }

    func testRingTurnsOnFirstOpen() {
        let app = launchList()
        XCTAssertTrue(moves(ring(app)), "the working row's ring turns")
        app.terminate()
    }

    /// The owner's report (build 203): Agents → Gram → Agents left the working ring stuck.
    func testRingTurnsAfterGram() {
        let app = launchList()
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(moves(ring(app)), "back from Gram, the working row's ring turns again")
        app.terminate()
    }

    func testRingTurnsAfterSettings() {
        let app = launchList()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(moves(ring(app)), "back from Settings, the working row's ring turns again")
        app.terminate()
    }

    /// The working pane's header dot, left for Gram and fronted again (iPhone: back to the
    /// roster and the row again; iPad: the pane stays beside the roster).
    func testPaneDotPulsesAfterGram() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = launchList()
        let row = app.staticTexts["herdr-app"].firstMatch
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10),
                      "the pane should open")
        XCTAssertTrue(moves(dot(app)), "the working pane's dot pulses")

        if !pad { app.buttons["Back"].firstMatch.tap() }
        app.buttons["Gram"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        if !pad {
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10),
                          "the kept-alive pane should come back to the front")
        }
        XCTAssertTrue(moves(dot(app)), "back from Gram, the working pane's dot pulses again")
        app.terminate()
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
        XCTAssertTrue(moves(ring(app)), "back on Agents, the ring turns on screen")
        if !pad {
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10),
                          "the kept-alive pane should come back to the front")
            sleep(1)
            XCTAssertEqual(moving(app), 1, "the kept-alive pane's dot pulses again in front")
            XCTAssertTrue(moves(dot(app)), "the kept-alive pane's dot pulses on screen")
        }

        // Everything holds still while the scene is not active, and resumes together.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        sleep(1)
        XCTAssertEqual(moving(app), pad ? 2 : 1, "back from the Home screen, the same shapes move again")
        XCTAssertTrue(moves(pad ? ring(app) : dot(app)), "back from the Home screen, they move on screen")
        app.terminate()
    }
}
