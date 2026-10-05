import XCTest

/// #347: the Agents home on a machine with several herdr sessions. The `sessions` mock
/// lists work, personal and default as running and scratch as stopped, and the home is
/// on "work"; every session answers with the demo roster (3 agents need you).
final class SessionPillsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testRunningSessionsShowAsPillsWithTheCurrentOneSelected() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "sessions"
        app.launch()

        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].waitForExistence(timeout: 12),
                      "the roster should have loaded")

        // Labels are what VoiceOver reads: name, then the needs-you count.
        let work = app.buttons["work, 3 need you"]
        XCTAssertTrue(work.waitForExistence(timeout: 6), "the current session should have a pill")
        XCTAssertTrue(work.isSelected, "the session the app is on should read as selected")

        let personal = app.buttons["personal, 3 need you"]
        XCTAssertTrue(personal.waitForExistence(timeout: 6), "another running session should have a pill")
        XCTAssertFalse(personal.isSelected)
        XCTAssertTrue(app.buttons["default, 3 need you"].exists, "the default session should have a pill")

        // A stopped session can't be switched to, so it gets no pill.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'scratch'")).firstMatch.exists,
                       "a stopped session must not be offered")
    }
}
