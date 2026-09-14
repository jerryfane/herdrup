import XCTest

/// Receipts for the Settings switches that change how the app treats data it did not
/// author. The DEFAULT of the JavaScript switch is pinned on Linux
/// (`WebViewPolicyTests.testJavaScriptIsOffUntilTheSettingIsTurnedOn`), because
/// `@AppStorage` survives between simulator launches, so a UI test cannot honestly
/// claim to observe a fresh install.
final class SettingsTests: XCTestCase {

    /// The switch exists and its explanation tracks it: with script ON the row must say
    /// scripts will run, with it OFF that they are ignored. A reader flipping this is
    /// loosening how an attachment somebody else wrote gets rendered, so the screen has
    /// to state which of the two it is doing — silently changing is the failure.
    ///
    /// Drives both directions from whatever state the simulator was left in, and leaves
    /// it OFF, so neither the assertion nor a later test depends on run order.
    func testJavaScriptPreviewSwitchFlipsAndExplainsItself() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "settings"
        app.launch()

        let heading = app.staticTexts["HTML PREVIEWS"]
        var scrolls = 0
        while !heading.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Settings should carry an HTML previews section")

        let row = app.staticTexts["Run JavaScript"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        let willRun = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "will run")).firstMatch
        let ignored = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "are ignored")).firstMatch

        if !willRun.exists { row.tap() }
        XCTAssertTrue(willRun.waitForExistence(timeout: 5),
                      "turning the switch on must say scripts will run")

        row.tap()
        XCTAssertTrue(ignored.waitForExistence(timeout: 5),
                      "and turning it off must say they are ignored")
    }
}
