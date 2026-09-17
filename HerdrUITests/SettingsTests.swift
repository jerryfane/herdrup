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
        // TEXT SCALE PINNED. `ui.fontScale` is @AppStorage and survives between simulator
        // launches, so without this the measurements below depend on whatever a previous
        // run left behind — at scale 1.2 the same correct layout measures 0.136.
        app.launchArguments += ["-ui.fontScale", "1.0"]
        app.launch()

        let accountsRow = app.staticTexts["Accounts"]
        XCTAssertTrue(accountsRow.waitForExistence(timeout: 15), "Settings should list Accounts")
        accountsRow.tap()

        let pill = app.staticTexts["exhausted"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "the exhausted account must show its status")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, 0)

        let exhaustedRow = app.staticTexts["Claude Pro (personal)"]
        XCTAssertTrue(exhaustedRow.waitForExistence(timeout: 5))

        // THE PILL MUST BE ONE LINE, expressed against a known single line of text rather
        // than a point constant. The bug wrapped "exhausted" to one letter per line into a
        // ~9-line capsule; the label beside it is always one line, so a pill more than
        // three label-heights tall is wrapped whatever the device or text size.
        XCTAssertLessThan(
            pill.frame.height, exhaustedRow.frame.height * 3,
            """
            the pill is \(pill.frame.height)pt against a \(exhaustedRow.frame.height)pt             single-line label, so it wrapped instead of keeping its intrinsic width.
            """)

        // THE NAME MUST KEEP A REAL SHARE OF THE ROW — and the floor has to be
        // WIDTH-AWARE, because a single fraction cannot do this job. Executed shares of
        // this label across the phone fleet at scale 1.0:
        //
        //   width  375   390   393   402   414   428   430   440
        //   fixed  .227  .257  .263  .279  .300  .318  .317  .310   <- correct
        //   mid    .102  .137  .144  .163  .187  .214  .217  .235   <- readout rigid
        //   base   .054  .091  .098  .118  .143  .171  .175  .194   <- reported bug
        //
        // The bands OVERLAP: correct-at-375 is 0.227 while the intermediate broken layout
        // reaches 0.235 at 440pt, so any constant that passes a 375pt phone also passes a
        // 440pt phone carrying the bug the previous commit fixed — a 0.20 gate did exactly
        // that. Bucketing by width separates all three, because the comparison is then
        // against the same device's own numbers.
        let floors: [(width: CGFloat, floor: CGFloat)] = [
            (440, 0.27), (428, 0.26), (414, 0.24), (402, 0.22),
            (393, 0.20), (390, 0.20), (375, 0.19), (0, 0.19),
        ]
        let widestRow = app.staticTexts["Claude Max (work)"]
        XCTAssertTrue(widestRow.waitForExistence(timeout: 5))
        let share = widestRow.frame.width / window.width
        let floor = floors.first { window.width >= $0.width }?.floor ?? 0.19
        XCTAssertGreaterThan(
            share, floor,
            """
            the account label took \(Int(share * 100))% of the \(window.width)pt window \
            (\(widestRow.frame.width)pt) against a floor of \(Int(floor * 100))%, so the \
            trailing cluster squeezed the name column — this is what showed as "C…".
            """)

        // THE WINDOW LABEL MUST SURVIVE. An earlier fix let the readout absorb the whole
        // deficit, so both meters truncated to "42% · 5…" / "68% · w…" and a stacked pair
        // became indistinguishable — worse than a short name. The window token is what
        // tells them apart, so assert it rendered.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "weekly"))
                .firstMatch.waitForExistence(timeout: 5),
            "the weekly meter lost its window label, so two stacked meters cannot be told apart")
    }
}
