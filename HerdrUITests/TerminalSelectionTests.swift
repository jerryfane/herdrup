import XCTest

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// A review found the repaired behaviour unguarded: a compiling mutant that removes
/// `clearTap.require(toFail: t)` restores the original defect, where the app's own tap
/// recognizer clears the word SwiftTerm selected on the SAME touch-up, and nothing in the
/// suite noticed. This file is the guard.
///
/// It uses PIXEL DIFF rather than accessibility, for two reasons. SwiftTerm draws the
/// selection highlight and its two handle ellipses with CoreGraphics, so there is no
/// element to query; and the Copy affordance rides on `UIMenuController`, deprecated at
/// iOS 16, so asserting on the menu would couple this receipt to an API whose survival is
/// exactly what nobody can currently promise. Pixels are the thing a person sees.
///
/// Structure mirrors ScrollTests: prove the terminal is STATIC first, so a later diff
/// cannot be ambient animation.
final class TerminalSelectionTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testDoubleTapSelectionSurvivesAndASingleTapClearsIt() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "scroll"
        app.launch()

        // The mock feeds 200 numbered lines into a real SwiftTerm view asynchronously.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) PREMISE: an untouched terminal is static. Without this, every diff below
        // could be a cursor blink or a stream repaint rather than a selection.
        let baseline = app.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let idleDiff = pixelDiffFraction(baseline, app.screenshot())
        attach(baseline, name: "01-baseline")
        XCTAssertLessThan(idleDiff, 0.02,
                          "terminal is not static when untouched (diff=\(idleDiff)); no later diff would mean anything")

        // (2) DOUBLE TAP on terminal text. Mid-body: below the header, above the reply bar,
        // matching the drag origin ScrollTests uses.
        let word = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        word.doubleTap()
        Thread.sleep(forTimeInterval: 1.0)

        let selected = app.screenshot()
        attach(selected, name: "02-after-double-tap")
        let selectionDiff = pixelDiffFraction(baseline, selected)
        XCTAssertGreaterThan(selectionDiff, 0.005,
                             "double tap drew nothing (diff=\(selectionDiff)); word select is not reaching SwiftTerm")

        // (3) THE REGRESSION ITSELF: the selection must still be there a moment later.
        // With one recognizer doing both jobs, the app's tap fired on tap 2 as well and
        // cleared the selection on the same touch-up, so this is where that defect shows.
        Thread.sleep(forTimeInterval: 1.5)
        let held = app.screenshot()
        attach(held, name: "03-selection-held")
        let heldVsBaseline = pixelDiffFraction(baseline, held)
        XCTAssertGreaterThan(heldVsBaseline, 0.005,
                             "the selection vanished on its own (diff vs baseline=\(heldVsBaseline)); the clear tap is firing on tap 2")

        // (4) A GENUINE SINGLE TAP elsewhere must clear it, so the fix did not simply
        // disable deselection. Tapped well away from the selected word.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.70)).tap()
        Thread.sleep(forTimeInterval: 1.5)

        let cleared = app.screenshot()
        attach(cleared, name: "04-after-single-tap")
        let clearedVsHeld = pixelDiffFraction(held, cleared)
        XCTAssertGreaterThan(clearedVsHeld, 0.002,
                             "a single tap changed nothing (diff=\(clearedVsHeld)); deselection is not reaching the view")
        XCTAssertLessThan(pixelDiffFraction(baseline, cleared), heldVsBaseline,
                          "after a single tap the terminal should be CLOSER to its unselected baseline than it was while selected")
    }

    // MARK: - helpers (duplicated from ScrollTests, which keeps them private)

    private func attach(_ shot: XCUIScreenshot, name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Fraction of pixels that differ beyond a small per-pixel threshold, compared at a
    /// fixed small resolution so PNG jitter and antialiasing do not register as change.
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
