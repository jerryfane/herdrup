import XCTest
import UIKit

final class AgentListChromeTests: XCTestCase {
    func testBackReturnsFromAgentsToMachines() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        let back = app.buttons[UIDevice.current.userInterfaceIdiom == .pad ? "agents-back" : "Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let window = app.windows.firstMatch
            // iPadOS can restore a compact window from an earlier launch. Resize only
            // a full-screen window: a minimum-size window cannot shrink any further.
            if window.frame.minX == 0 && window.frame.minY == 0 {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                    .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.82)))
            }
            XCTAssertTrue(window.frame.minX > 0 || window.frame.minY > 0,
                          "Back must be exercised in a system window, not just full screen")
        }
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["connect to your machine"].waitForExistence(timeout: 5))
    }

    /// iPad: Back leads in full screen (no window controls on the left), joins the
    /// right-hand capsule in a window, and in a window the bar sits inside the window's
    /// top edge instead of touching it. Named to run first in this class: the next test
    /// leaves the window shrunk, and iPadOS restores that size on later launches.
    func testAIPadBackFollowsFullScreenAndWindowMode() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad window modes only")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()
        let window = app.windows.firstMatch
        let back = app.buttons["agents-back"].firstMatch
        let title = app.staticTexts["Agents"].firstMatch
        let newAgent = app.buttons["New agent"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))

        let startedFullScreen = window.frame.minX == 0 && window.frame.minY == 0
        if startedFullScreen {
            attach("ipad-fullscreen-back-left", app)
            XCTAssertLessThan(back.frame.maxX, title.frame.minX, "full screen: Back is left of the title")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.997, dy: 0.997))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.82)))
        }
        XCTAssertTrue(window.frame.minX > 0 || window.frame.minY > 0, "must be in a window")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        waitForSettledFrame(window)
        attach("ipad-window-back-right", app)
        XCTAssertGreaterThan(back.frame.minX, title.frame.maxX, "window: Back joins the right-hand capsule")
        XCTAssertGreaterThan(newAgent.frame.minY, window.frame.minY + 4,
                             "window: the bar must not touch the window's top edge")
        XCTAssertTrue(back.isHittable)
        // Gram's header is built from the same bar: it must sit inside the edge too.
        let refresh = app.buttons["Refresh"].firstMatch
        for _ in 0..<3 where !refresh.exists {
            app.buttons["Gram"].firstMatch.tap()
            _ = refresh.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(refresh.exists, "Gram should open with its header")
        attach("ipad-window-gram", app)
        XCTAssertGreaterThan(refresh.frame.minY, window.frame.minY + 4,
                             "window: Gram's bar must not touch the window's top edge")
        if !startedFullScreen {
            // The window survived from an earlier run; the window case above still ran.
            throw XCTSkip("started in a restored window: the full-screen half was not exercised")
        }
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// iPadOS animates a restored or resized window into place; frames read during that
    /// animation, and taps aimed with them, are wrong.
    private func waitForSettledFrame(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = element.frame
            if now == last { return }
            last = now
        }
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
