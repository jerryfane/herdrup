import XCTest

/// Exercises the first screen's actual command buttons. The phone is showing
/// commands intended for another machine, so tapping them must visibly confirm
/// a copy rather than behaving like inert code blocks.
final class OnboardingTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testInstallAndPairCommandsAreCopyable() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "onboarding"
        app.launch()

        let install = app.buttons[
            "Copy command: curl -fsSL https://herdrup.themartian.app/install.sh | sh"
        ]
        XCTAssertTrue(install.waitForExistence(timeout: 8),
                      "the one-line fork installer should be visible and tappable")
        install.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2),
                      "tapping the installer should confirm the clipboard write")

        let pair = app.buttons["Copy command: herdr pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 3),
                      "the pairing command should be visible and tappable")
        pair.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2),
                      "tapping the pairing command should confirm the clipboard write")
    }
}
