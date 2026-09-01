import XCTest

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// A review found the repaired behaviour unguarded: a compiling mutant that removes
/// `clearTap.require(toFail: t)` restores the original defect, where the app's own tap
/// recognizer clears the word SwiftTerm selected on the SAME touch-up, and nothing in the
/// suite noticed.
///
/// THIS FILE HAS FAILED CI TWICE, BOTH TIMES ON ITSELF RATHER THAN ON PRODUCT CODE, and
/// both lessons are recorded here because each was already knowable.
///
/// 1. PIXELS CANNOT TELL A SELECTION FROM A POPOVER. The first version proved persistence
///    by diffing against the pre-selection baseline, so ANY on-screen difference satisfied
///    it, including SwiftTerm's context menu merely being present. That step passed and the
///    next failed with a diff of exactly 0.0, which is what revealed the earlier assertion
///    had been satisfied for the wrong reason.
/// 2. NEVER READ THE PASTEBOARD IN THIS REPO. The second version asserted on
///    `UIPasteboard.general.string`. A pasteboard READ raises a system paste prompt, which
///    nothing answers in CI, so the run hung until the 45 minute job timeout and was
///    cancelled with no test results at all. This constraint was already written down twice
///    in the app, at CopyForAgentButton.swift:9 and HerdrApp.swift:685, both saying the app
///    writes and never reads precisely because that prompt failed App Review under 2.1a.
///
/// So this asserts on the MENU ITEM alone, which needs no clipboard and cannot pass by
/// accident: `canPerformAction` returns Copy only while `selection.active`, so the item
/// existing after a double tap IS proof that a selection survived the same touch-up that
/// created it, and its absence after a single tap is proof deselection reached the view.
///
/// It also settles rather than assumes the standing question of whether `UIMenuController`,
/// deprecated at iOS 16, still presents: if it does not, this fails and says which cause.
final class TerminalSelectionTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testDoubleTapHoldsASelectionAndASingleTapDismissesIt() {
        let app = XCUIApplication()

        // Defence against the failure above generalising: if ANY system dialog appears, dismiss
        // it rather than letting the run hang to the job timeout with no results.
        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }

        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "scroll"
        app.launch()

        // The mock feeds 200 numbered lines into a real SwiftTerm view asynchronously.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) PREMISE: the terminal is static when untouched, so a later pixel change means
        // the gesture did something rather than the stream repainting under us.
        let baseline = app.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let idleDiff = pixelDiffFraction(baseline, app.screenshot())
        attach(baseline, name: "01-baseline")
        XCTAssertLessThan(idleDiff, 0.02,
                          "terminal is not static when untouched (diff=\(idleDiff)); no later diff would mean anything")

        // (2) DOUBLE TAP on terminal text: mid-body, below the header and above the reply
        // bar, matching the drag origin ScrollTests uses.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).doubleTap()
        Thread.sleep(forTimeInterval: 1.0)
        let selected = app.screenshot()
        attach(selected, name: "02-after-double-tap")
        XCTAssertGreaterThan(pixelDiffFraction(baseline, selected), 0.005,
                             "double tap drew nothing at all; word select is not reaching SwiftTerm")

        // (3) THE ASSERTION THAT CANNOT PASS BY ACCIDENT. Copy is offered only while a
        // selection is active, so this is where the mutant shows: with the clear tap firing
        // on tap 2 there is no selection by now and no Copy item.
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5),
                      "no Copy item after a double tap. Either the selection was cleared on the same touch-up (the regression this file guards) or UIMenuController no longer presents on this OS, which is a finding in its own right")

        // (4) DESELECTION still works, so the fix did not simply disable it. Deliberately NOT
        // tapping Copy: that would put the reader's selection on the clipboard, and reading it
        // back to verify is the pasteboard prompt that hung this test once already.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.70)).tap()
        Thread.sleep(forTimeInterval: 2.5)
        attach(app.screenshot(), name: "03-after-single-tap")
        XCTAssertFalse(app.menuItems["Copy"].exists,
                       "a genuine single tap left the selection up; deselection is not reaching the view")
    }

    // MARK: - helpers (duplicated from ScrollTests, which keeps them private)

    private func attach(_ shot: XCUIScreenshot, name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Fraction of pixels differing beyond a small per-pixel threshold, compared at a fixed
    /// small resolution so PNG jitter and antialiasing do not register as change.
    private func pixelDiffFraction(_ a: XCUIScreenshot, _ b: XCUIScreenshot) -> Double {
        let w = 90, h = 180
        guard let bufA = rgbaBuffer(a.image, w: w, h: h),
              let bufB = rgbaBuffer(b.image, w: w, h: h) else { return 1.0 }
        var differing = 0
        var i = 0
        while i < bufA.count {
            let d = abs(Int(bufA[i]) - Int(bufB[i]))
                  + abs(Int(bufA[i + 1]) - Int(bufB[i + 1]))
                  + abs(Int(bufA[i + 2]) - Int(bufB[i + 2]))
            if d > 30 { differing += 1 }
            i += 4
        }
        return Double(differing) / Double(w * h)
    }

    private func rgbaBuffer(_ image: UIImage, w: Int, h: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}
