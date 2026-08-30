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

        XCTAssertTrue(
            app.descendants(matching: .any)["pairing-prerequisite-tailscale"]
                .waitForExistence(timeout: 8),
            "the first screen should name the two-device Tailscale prerequisite")
        XCTAssertTrue(
            app.descendants(matching: .any)["pairing-prerequisite-ssh"]
                .waitForExistence(timeout: 3),
            "the first screen should name SSH and macOS Remote Login")

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

    func testScannerExplainsBothCleanQRAlternatives() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "pairing-guidance"
        app.launch()

        let fallback = app.descendants(matching: .any)["pairing-qr-fallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 8),
                      "scanner guidance should explain what to do with a distorted QR")
        XCTAssertTrue(fallback.label.contains("herdr pair --open"),
                      "scanner guidance should offer a clean opened QR")
        XCTAssertTrue(fallback.label.contains("--qr-file"),
                      "scanner guidance should offer an SVG file")
    }
}
