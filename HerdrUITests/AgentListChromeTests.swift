import XCTest
import UIKit

final class AgentListChromeTests: XCTestCase {
    func testBackReturnsFromAgentsToMachines() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        let back = app.buttons[UIDevice.current.userInterfaceIdiom == .pad ? "agents-back" : "Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["connect to your machine"].waitForExistence(timeout: 5))
    }

    func testSearchFiltersAndClearsWithoutLosingMic() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        let search = app.textFields["agent-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["agent-search-mic"].exists)
        search.tap()
        search.typeText("jarvis")
        XCTAssertTrue(app.staticTexts["jarvis"].exists)
        XCTAssertFalse(app.staticTexts["vetrina"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["vetrina"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agent-search-mic"].exists)
    }

    func testTabletSidebarCanHideAndRestoreInEverySection() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Tablet split view") }
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        for section in ["Agents", "Gram", "Settings"] {
            if section != "Agents" { app.buttons[section].firstMatch.tap() }
            let hide = app.buttons["Minimise sidebar"].firstMatch
            XCTAssertTrue(hide.waitForExistence(timeout: 10), section)
            hide.tap()
            let restore = app.buttons["Expand sidebar"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: 5), section)
            restore.tap()
            XCTAssertTrue(hide.waitForExistence(timeout: 5), section)
        }
    }
}
