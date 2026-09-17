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

    /// THE BEHAVIOUR, not the copy: a received document whose script rewrites the page
    /// is rendered by the shipping viewer, and what the page ends up SAYING is the
    /// answer. With the switch off the script must not have run.
    ///
    /// The value is forced through the argument domain rather than left to whatever a
    /// previous run on this simulator stored, so each direction is deterministic. The
    /// DEFAULT — an absent key — is pinned on Linux, where a fresh `UserDefaults` suite
    /// can actually be created.
    func testAPreviewedScriptDoesNotRunWhenTheSwitchIsOff() {
        let app = launchPreview(javaScript: false)
        XCTAssertTrue(app.webViews.staticTexts["script did not run"].waitForExistence(timeout: 20),
                      "the document must render unexecuted")
        XCTAssertFalse(app.webViews.staticTexts["script ran"].exists,
                       "and the script must not have rewritten it")
    }

    /// And the switch has to actually reach the viewer: with it on, the same document
    /// rewrites itself. Without this direction the test above would pass just as well
    /// against a viewer that ignored the setting entirely.
    func testAPreviewedScriptRunsWhenTheSwitchIsOn() {
        let app = launchPreview(javaScript: true)
        XCTAssertTrue(app.webViews.staticTexts["script ran"].waitForExistence(timeout: 20),
                      "turning the switch on must let the document's script run")
    }

    private func launchPreview(javaScript: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "htmlpreview"
        app.launchArguments += ["-previews.javascript", javaScript ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// GEOMETRY, because the defect was geometric and every text assertion passed
    /// through it. An exhausted account that also reports usage — the common case, since
    /// reaching 100% is what exhausts it — put the meters and the status pill on one
    /// line. `Text("exhausted")` had no line limit, so it wrapped to one letter per
    /// line into a ~9-line red capsule that doubled the row height, and the width it
    /// claimed squeezed "Claude Pro (personal)" down to "C…".
    ///
    /// Accessibility labels are unaffected by truncation, so a `staticTexts["..."]`
    /// existence check reports success on the broken layout. What separates the two is
    /// the rendered FRAME: the pill's height, and the label's width.
    ///
    /// The mock's `acc-claude-2` is exactly this case (active false, both windows at
    /// 100%), which is why this is checkable at all.
    func testAnExhaustedAccountRowKeepsItsShape() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "settings"
        app.launch()

        let accountsRow = app.staticTexts["Accounts"]
        XCTAssertTrue(accountsRow.waitForExistence(timeout: 15), "Settings should list Accounts")
        accountsRow.tap()

        let pill = app.staticTexts["exhausted"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the exhausted account must show its status")

        // RELATIVE TO THE ROW, not absolute points. Fixed thresholds made this receipt
        // pass on the BROKEN layout: the pre-fix name floor scales with device width and
        // crosses 90pt at ~396pt, so on an iPhone 16 Pro (402pt) or Pro Max (440pt) the
        // old `> 90` assertion held before the fix and only the height half did any work.
        // CI does not pin the simulator width either. Both gates are now fractions of the
        // window, so the test means the same thing on every device.
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, 0)

        // One line of 11pt text plus 3pt padding each side is ~20pt; the wrapped capsule
        // was roughly nine times that. Expressed against the row so a larger Dynamic Type
        // setting cannot make a single line look like a wrap.
        let exhaustedRow = app.staticTexts["Claude Pro (personal)"]
        XCTAssertTrue(exhaustedRow.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            pill.frame.height, 32,
            "the exhausted pill is \(pill.frame.height)pt tall, so it wrapped instead of keeping its intrinsic width")

        // MEASURED ON THE WORST ROW, which is not the exhausted one. `acc-claude-2`
        // carries only the flat back-compat fields — deliberately, so the synthesized
        // -window path stays covered by MockWireFixtureTests — so its readout is the
        // short "100% · 5h" and its cluster is ~126pt. The ACTIVE `acc-claude-1` has
        // resets_at, giving "42% · 5h · May 18" and a ~162pt cluster, which is the case
        // closest to a live daemon and the one that squeezed hardest. Assert there.
        let widestRow = app.staticTexts["Claude Max (work)"]
        XCTAssertTrue(widestRow.waitForExistence(timeout: 5))
        let share = widestRow.frame.width / window.width
        XCTAssertGreaterThan(
            share, 0.30,
            """
            the account label took \(Int(share * 100))% of the row width             (\(exhaustedRow.frame.width)pt of \(window.width)pt), so the trailing cluster             squeezed the name column — this is what showed as "C…".
            """)

        // And the exhausted row must not be taller than a healthy one. This is the
        // symptom the owner actually reported, and it is device-independent by
        // construction: the two rows are compared to each other, not to a constant.
        let healthyRow = app.staticTexts["Kimi"]
        XCTAssertTrue(healthyRow.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            exhaustedRow.frame.height, healthyRow.frame.height * 2,
            "the exhausted row's label grew relative to a healthy row's, so the row inflated")
    }
}
