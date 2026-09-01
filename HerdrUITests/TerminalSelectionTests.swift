import XCTest
import UIKit

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// A review found the repaired behaviour unguarded: a compiling mutant that removes
/// `clearTap.require(toFail: t)` restores the original defect, where the app's own tap
/// recognizer clears the word SwiftTerm selected on the SAME touch-up, and nothing in the
/// suite noticed.
///
/// THIS FILE HAS BEEN WRONG THREE TIMES, always about its own instrument and never about the
/// product code. Each lesson is kept because each was independently discoverable and I missed
/// it:
///
/// 1. PIXELS AGAINST A BASELINE CANNOT TELL A SELECTION FROM A POPOVER. v1 proved persistence
///    by diffing against the pre-selection frame, so ANY on-screen difference satisfied it —
///    including SwiftTerm's context menu merely being present.
/// 2. NEVER READ THE PASTEBOARD IN THIS REPO. v2 asserted on `UIPasteboard.general.string`. A
///    pasteboard READ raises a system paste prompt, nothing answers it in CI, and the run hung
///    to the 45-minute job timeout and was cancelled with no test results at all. The
///    constraint was already written twice in the app, at CopyForAgentButton.swift:9 and
///    HerdrApp.swift:685, both saying the app writes and never reads because that prompt
///    failed App Review under 2.1a.
/// 3. A COPY MENU IS NOT A SELECTION. v3 asserted `menuItems["Copy"].exists`. A reviewer
///    downloaded the CI artifacts and measured SwiftTerm's `selectedTextBackgroundColor`
///    (0,166,178) at 0 of 3,162,132 pixels in every frame — while Copy WAS present. The cause
///    is in SwiftTerm's own code: `selectedColumnsRange` yields an EMPTY range when
///    `startCol == endCol`, so double-tapping blank space leaves `selection.active == true`
///    with nothing selected and nothing painted, and `canPerformAction` offers Copy anyway.
///    Both of v3's taps were also mis-aimed: dx=0.35 lands past the end of these short
///    numbered lines, and dy=0.70 lands on the software keyboard, which occupies the bottom
///    ~40% and would type into a live agent's PTY.
///
/// So this version measures THE HIGHLIGHT ITSELF, with the same detector the reviewer used to
/// falsify v3. A word painted in the selection colour cannot be produced by a popover, by an
/// empty range, or by a stale clipboard, and it needs no pasteboard read. Copy's presence is
/// kept only as a secondary signal, never as the proof.
final class TerminalSelectionTests: XCTestCase {

    /// SwiftTerm's default `selectedTextBackgroundColor` is (0, 166/255, 178/255) and the app's
    /// `Coordinator.style` never overrides it (it sets only nativeBackground/Foreground,
    /// backgroundColor, caretColor and installColors), so this teal is the selection and
    /// nothing else in the palette is near it.
    ///
    /// The hue tests (`g > r + 40`, `b > r + 40`) are the reviewer's, unchanged. The
    /// BRIGHTNESS floor is 70 rather than their 90 because they measured full-resolution
    /// frames and this downsamples: a teal pixel averaged with the terminal's near-black
    /// ground (#0B0D1C) at the edge of a glyph lands around g=89, which their threshold would
    /// reject. Relaxing it can only admit more colours, which is why the test asserts the
    /// BASELINE count is near zero before drawing any conclusion from a later count — that
    /// premise, not this constant, is what makes the detector specific to the selection.
    private func tealPixelCount(_ shot: XCUIScreenshot) -> Int {
        let w = 300, h = 600
        guard let buf = rgbaBuffer(shot.image, w: w, h: h) else { return 0 }
        var n = 0
        var i = 0
        while i < buf.count {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            if g > r + 40 && b > r + 40 && g > 70 { n += 1 }
            i += 4
        }
        return n
    }

    override func setUp() { continueAfterFailure = false }

    func testDoubleTapSelectsAWordAndASingleTapDeselectsIt() {
        let app = XCUIApplication()

        // If ANY system dialog appears, dismiss it rather than letting the run hang to the job
        // timeout with no results — the shape of lesson 2 above, guarded generally.
        addUIInterruptionMonitor(withDescription: "system dialog") { alert in
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            if allow.exists { allow.tap(); return true }
            return false
        }

        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "scroll"
        app.launch()

        // The mock feeds 200 numbered lines into a real SwiftTerm view asynchronously.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) PREMISES, both asserted before anything is concluded from them.
        let baseline = app.screenshot()
        attach(baseline, name: "01-baseline")

        // 1a. The terminal is static when untouched, so a later change means the gesture did
        // something rather than the stream repainting under us.
        Thread.sleep(forTimeInterval: 1.0)
        let idleDiff = pixelDiffFraction(baseline, app.screenshot())
        XCTAssertLessThan(idleDiff, 0.02,
                          "terminal is not static when untouched (diff=\(idleDiff)); no later measurement would mean anything")

        // 1b. NOTHING is already teal. Without this the selection assertion could be satisfied
        // by any pre-existing colour in the palette, which is exactly how v1 passed.
        let baseTeal = tealPixelCount(baseline)
        XCTAssertLessThan(baseTeal, 20,
                          "found \(baseTeal) selection-coloured pixels BEFORE selecting anything; the detector cannot distinguish a selection here")

        // (2) RAISE THE KEYBOARD FIRST, AND ASSERT THAT IT HAPPENED. This step exists because
        // of a measured failure, not for tidiness: the previous version double-tapped a COLD
        // pane and got teal px=0 with a clean baseline. Tap 1 of that double tap fires
        // `focusTap`, which requests terminal focus and so raises the iPhone software keyboard;
        // the keyboard takes roughly the bottom 40%, the terminal band relaid out under the
        // finger, and tap 2 therefore hit different content and word-selected an EMPTY range —
        // active selection, Copy offered, nothing painted. Doing it in two stages means the
        // layout is settled before the gesture under test runs.
        //
        // The assertion is what makes this a wait with a reason rather than a sleep: a large
        // diff IS the keyboard arriving, so if it ever stops arriving this fails here, naming
        // the cause, instead of failing later as a mysteriously absent selection.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.30)).tap()
        Thread.sleep(forTimeInterval: 2.5)
        let focused = app.screenshot()
        attach(focused, name: "02-keyboard-up")
        let focusDiff = pixelDiffFraction(baseline, focused)
        XCTAssertGreaterThan(focusDiff, 0.10,
                             "the focus tap changed almost nothing (diff=\(focusDiff)); the keyboard did not come up, so the double tap below would run against a layout that is still about to move")
        XCTAssertLessThan(tealPixelCount(focused), 20,
                          "a single tap on an unselected pane produced selection colour; the premise for step 4 is broken")

        // (3) DOUBLE TAP ON ACTUAL TEXT, on the now-stable layout. The mock lines read
        // "SCROLLTEST line 007  the quick brown fox…" at 80 columns, so dx=0.30 is comfortably
        // inside the glyphs — a tap past end-of-line selects an EMPTY range, which is the third
        // way this file has been fooled. dy=0.30 stays in the terminal band, which the keyboard
        // has now shrunk to roughly the top 58%.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.30)).doubleTap()
        Thread.sleep(forTimeInterval: 1.5)
        let selected = app.screenshot()
        attach(selected, name: "03-selection-held")

        // (4) THE ASSERTION THAT CANNOT PASS BY ACCIDENT: a word is painted in the selection
        // colour. This is where the mutant shows — with the clear tap firing on tap 2, the
        // selection is gone by now and there is no teal to find.
        //
        // 60, three times the baseline ceiling of 20, so a marginal pass cannot straddle the
        // two limits: a run reading 19 before and 21 after would satisfy both a "nothing is
        // teal" premise and a "something is teal" conclusion, and mean neither. A selected
        // word is ~3000 px at full resolution, ~170 here, so the gap is not tight.
        let heldTeal = tealPixelCount(selected)
        XCTAssertGreaterThan(heldTeal, 60,
                             "no selection highlight after a double tap (teal px=\(heldTeal), baseline \(baseTeal)). Either the selection was cleared on the same touch-up — the regression this file guards — or the tap selected an empty range")

        // Secondary only: Copy SHOULD be offered, but its presence alone proves nothing, since
        // an empty-but-active selection also offers it.
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5),
                      "a word is highlighted but Copy is not offered, so the selection cannot be acted on")

        // (5) DESELECTION still works, so the fix did not simply disable it. The tap stays in
        // the terminal band and well away from the selected word — NOT on the keyboard, which
        // on a live pane would type a character into the agent's shell. The keyboard is already
        // up by now, so this tap cannot move the layout the way step 2's did.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.20)).tap()
        Thread.sleep(forTimeInterval: 2.0)
        let cleared = app.screenshot()
        attach(cleared, name: "04-after-single-tap")
        let clearedTeal = tealPixelCount(cleared)
        XCTAssertLessThan(clearedTeal, 20,
                          "the selection highlight survived a genuine single tap (teal px=\(clearedTeal)); deselection is not reaching the view")
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
