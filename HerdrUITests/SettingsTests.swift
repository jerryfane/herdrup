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
    /// THE DISCORD ROW RENDERS IN THE REAL SETTINGS SCREEN, which is the half a font
    /// test cannot reach.
    ///
    /// `TerminalFontTests.testSettingsDiscordGlyphResolvesByFontName` proves the glyph is
    /// in the bundle and resolvable by name; it says nothing about whether this row is
    /// built, reachable, or tappable. This drives the shipping Settings view and asserts
    /// the row exists, carries its label, and is hittable.
    ///
    /// It deliberately does NOT tap it: the tap hands off to Safari, and asserting on
    /// another app's state from here would be a receipt about SafariViewController rather
    /// than about this row. The URL itself is a constant in one place
    /// (`SettingsView.discordInvite`), so there is nothing a tap would prove that reading
    /// it does not.
    ///
    /// The glyph's own appearance is unverifiable here for the honest reason that XCUITest
    /// cannot read a rendered outline: a missing-glyph box and the Discord mark are the
    /// same element tree. A screenshot is attached so the result bundle carries the
    /// evidence a human can check.
    func testTheDiscordRowIsPresentAndTappable() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "settings"
        app.launch()

        let heading = app.staticTexts["ABOUT"]
        var scrolls = 0
        while !heading.exists, scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Settings should carry an ABOUT section")

        let row = app.buttons["settings-discord"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the ABOUT section should offer the Discord invite")
        XCTAssertTrue(row.isHittable, "the Discord row must be tappable where it sits")
        XCTAssertTrue(
            row.label.contains("Discord"),
            "the row's accessible name must say Discord, not read out a private-use codepoint (got: \(row.label))")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-about-discord"
        shot.lifetime = .keepAlways
        add(shot)
    }

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

        // COMPARE THE TWO ROWS, not the window. Fourth calibration of this gate, and the
        // first that is device-free — because a share-of-window gate CANNOT work: the
        // name saturates at its 136.25pt intrinsic width, so the correct layout's share
        // falls as 1/W and goes red above ~505pt. The review measured the correct layout
        // at 0.183 on a 744pt iPad and 0.132 at 1032pt — the iPad Pro ci.yml:167-170
        // deliberately selects — and at 320pt iPad Slide Over. My width-bucket table
        // passed every phone and would have failed every iPad.
        //
        // The two labels this test already holds are enough — with ONE premise, which is
        // now asserted rather than assumed.
        //
        // `acc-claude-2` carries no resets_at, so its meter has no reset hint and its row
        // is identical in the correct layout and in the `mid` one (125.80pt cluster in
        // both). That is what makes it usable as a yardstick. Two honest caveats the
        // review established:
        //
        //  * it is NOT invariant in the `base` layout (158.71pt there, because the status
        //    sat beside the meters and the pill compressed this row too). The gate still
        //    catches `base` on phones, but because BOTH rows compress and the name
        //    compresses harder — 20.40pt against 68.29pt at 375pt — not because the
        //    denominator held still.
        //  * if that fixture ever gains a resets_at — the production-NORMAL case for an
        //    exhausted account — the yardstick compresses too and the ratio rises to
        //    ~1.08, which would BLIND this gate silently. So the premise is pinned below:
        //    the yardstick's readout must be exactly "100% · weekly", with no hint.
        //
        // Executed ratios of name / yardstick:
        //
        //   correct  0.842 … 0.886 across 375-440pt, and 0.871 at 820 and 1032
        //   mid      0.379 … 0.661   (readout rigid)
        //   base     0.202 … 0.546   (the reported bug)
        //
        // 0.70 rather than the 0.75 the review suggested: if SwiftUI's minimum for the
        // truncating hint is the longest word rather than one ellipsis cell, the correct
        // ratio at 375pt is 0.711, which 0.75 would fail. 0.70 survives both models.
        //
        // The margin against `mid` at 440pt is only 0.92 of one IBM Plex Mono cell, so it
        // depends on the mock's reset hint staying two tokens long. That is exactly why
        // the premise assertion below exists: a fixture change breaks the test loudly
        // instead of quietly disarming it.
        //
        // Above ~472pt all three layouts converge, which is honest: nothing truncates
        // there, so there is no defect to detect.
        XCTAssertTrue(
            app.staticTexts["100% · weekly"].waitForExistence(timeout: 5),
            """
            the yardstick row's readout is not exactly "100% · weekly" any more, so \
            `acc-claude-2` has gained a reset hint and the ratio gate below is no longer \
            discriminating — re-derive it before trusting a green result.
            """)

        // NAMES, not "widest"/"short": at 15pt Geist-SemiBold "Claude Max (work)" is
        // 136.25pt and "Claude Pro (personal)" is 156.38pt, so the row this gate measures
        // is the NARROWER of the two and a fully healthy render tops out at 0.871.
        let measuredName = app.staticTexts["Claude Max (work)"]
        XCTAssertTrue(measuredName.waitForExistence(timeout: 5))
        let yardstick = exhaustedRow
        let ratio = measuredName.frame.width / yardstick.frame.width
        XCTAssertGreaterThan(
            ratio, 0.70,
            """
            "Claude Max (work)" rendered at \(Int(ratio * 100))% of the unsqueezed \
            "Claude Pro (personal)" row (\(measuredName.frame.width)pt vs \
            \(yardstick.frame.width)pt, healthy ceiling 87%), so the trailing cluster \
            squeezed the name column — this is what showed as "C…".
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
