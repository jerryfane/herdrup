import XCTest
import UIKit

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// WHAT IT DOES AND DOES NOT GUARD, stated first because the previous version of this comment
/// claimed the wrong thing. A review found the repaired behaviour unguarded by a mutant that
/// removes `clearTap.require(toFail: t)` — and a LATER review showed this receipt does not kill
/// that mutant either, for a timing reason neither of us had accounted for: without the failure
/// requirement `clearTap` recognizes at tap-2 touch-up, which is STRICTLY BEFORE SwiftTerm's
/// tripleTap-delayed `doubleTap` selects the word. The clear lands on the pre-tap state, the
/// selection is made ~0.3s later, the highlight paints, and this test passes.
///
/// The same timing implies the mutant is largely BENIGN in production, so the original P1 was a
/// reasoned coin-toss rather than a measured wipe. What this file does guard: no highlight at
/// all, a selection that is active but EMPTY, a selection SwiftTerm holds but does not paint,
/// and a deselection that never reaches the view. Those are real and it has caught three of
/// them. It is not a guard on the require(toFail:) line, and saying so was overclaiming.
///
/// THIS FILE HAS NOW BEEN WRONG FOUR TIMES, always about its own instrument and never about the
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
///    measured SwiftTerm's `selectedTextBackgroundColor` at 0 of 3,162,132 pixels in every
///    frame while Copy WAS present: `selectedColumnsRange` yields an EMPTY range when
///    `startCol == endCol`, so a tap off the glyphs leaves `selection.active == true` with
///    nothing selected and nothing painted, and `canPerformAction` offers Copy anyway.
/// 4. A PIXEL COUNT CANNOT NAME A CAUSE. v4 measured the highlight and reported "teal px=0"
///    twice, which is consistent with four different bugs. I diagnosed it twice from that one
///    number and was wrong both times — first a keyboard-relayout race, then coordinates. So
///    the app now publishes SwiftTerm's own selection state under the mock env var and this
///    reads it, asserting STATE before PIXELS so a failure says which layer broke.
///
/// Two corrections to v4's own claims, both from review: my "these mock lines are short"
/// remark was wrong (they are 68 of 80 columns, so the earlier dx values were over text after
/// all, and the retroactive "past end of line" diagnosis was dubious), and the coordinates were
/// sound throughout. The two-stage focus tap is kept anyway: it removes a real race in which a
/// keyboard-driven resize can clear a just-made selection, which is a hazard on device even
/// when CI happens to win it.
final class TerminalSelectionTests: XCTestCase {

    /// SwiftTerm's default `selectedTextBackgroundColor` is (0, 166/255, 178/255) and the app's
    /// `Coordinator.style` never overrides it — verified: nothing in App/ or Sources/ assigns
    /// `selectedTextBackgroundColor` or `selectedTextForegroundColor` at all, and `style(view)`
    /// sets only font, nativeBackground/Foreground, backgroundColor, caretColor, isOpaque and
    /// installColors. So a teal region in a frame IS SwiftTerm's selection.
    ///
    /// "NOTHING ELSE IN THE PALETTE IS NEAR IT" WAS FALSE, and a reviewer did the arithmetic:
    /// `Palette.working` and `caretColor` are both 0x5B9BE8, which passes this detector
    /// outright (g=155 > 91+40, b=232 > 131, g > 70), as do the ANSI cyan slots 0x4FB8C8 and
    /// 0x74CEDC. None of them appears in THIS mock — the fixture's blocked agent draws an amber
    /// dot, the cursor is hidden by ESC[?25l, and the seeded text is uncoloured — so the
    /// detector is specific here. What makes that safe is not the constant but the
    /// `baseTeal < 20` premise: a working-status dot would contribute roughly 28 downsampled
    /// pixels, so any future collision fails the PREMISE loudly instead of quietly satisfying
    /// the conclusion.
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

        // (3) DOUBLE TAP INSIDE THE WIDEST LETTER RUN AVAILABLE, because the previous
        // coordinate was a coin toss and CI proved it.
        //
        // THE PROBE ANSWERED THE QUESTION THIS TEST EXISTED TO ASK. Aimed at the line number it
        // reported `sel=1 len=1 text=< >` — a ONE-CHARACTER SPACE. `selectWordOrExpression` has
        // a dedicated whitespace branch, so a tap that misses the glyphs selects the run of
        // spaces instead of nothing, which is an active, non-empty, entirely invisible-ish
        // selection: one cell paints roughly 26 downsampled pixels, under the 60 this test
        // requires. The retry pass then SUCCEEDED, which settles the older mystery too — the
        // selection does paint when the tap lands on a word, so the earlier zero-teal runs were
        // about WHERE the tap landed and not about SwiftTerm's drawing.
        //
        // The mock line is "SCROLLTEST line 007  the quick brown fox jumps over the lazy dog" at
        // 80 columns, and its longest letter runs are five characters. Columns: 0-9 SCROLLTEST,
        // 10 space, 11-14 line, 15 space, 16-18 the digits, 19-20 two spaces, 21-23 the,
        // 24 space, 25-29 quick, 30 space, 31-35 brown. Aiming at the MIDDLE of "quick" (col 27,
        // dx = 27.5/80 ≈ 0.344) leaves two columns of slack on either side, which is the widest
        // margin this fixture offers. The number at 16-18 offered one column, and dx 0.22 landed
        // on a space at least once in two runs.
        //
        // dy=0.30 stays in the terminal band, which the keyboard has shrunk to roughly the top 58%.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.344, dy: 0.30)).doubleTap()
        Thread.sleep(forTimeInterval: 1.5)
        let selected = app.screenshot()
        attach(selected, name: "03-selection-held")

        // (4) READ THE STATE, THEN THE PIXELS — in that order, because for four consecutive CI
        // runs "no teal" was all this test could say, and it cannot distinguish: no selection
        // was made; an EMPTY range was selected; a late resize wiped it (SwiftTerm clears the
        // selection on any rows/cols change); or a selection exists and is painted a colour the
        // detector does not match. Those are four different bugs and I guessed wrong twice.
        // `terminal-selection-probe` is published by the app under the same mock env var and
        // reports sel/len/rows/cols/resizes, so the diagnosis now comes from SwiftTerm.
        let probe = app.descendants(matching: .any)["terminal-selection-probe"]
        let reading = probe.waitForExistence(timeout: 5) ? (probe.label) : "PROBE ABSENT"

        // THE STATE ASSERTIONS, in order of how badly a failure would mislead.
        XCTAssertTrue(reading.contains("sel=1"),
                      "SwiftTerm reports no active selection after a double tap. probe[\(reading)]. If resizes climbed since the focus tap, a late relayout wiped it; if not, the double tap never reached SwiftTerm's recognizer")
        XCTAssertFalse(reading.contains("len=0"),
                       "the selection is active but EMPTY, so the tap landed past the end of the line. probe[\(reading)]")

        // A WHITESPACE SELECTION IS A COORDINATE MISS, NOT A RENDER BUG, and it must say so.
        // `selectWordOrExpression` has a dedicated branch that selects a RUN OF SPACES, so a tap
        // between words yields an active, non-empty selection that paints one or two cells —
        // which then fails the pixel threshold below and reads exactly like a drawing failure.
        // That cost a CI round: the probe reported `len=1 text=< >` while the message blamed the
        // renderer. Extracting the text and checking it is a word turns the same run into a
        // one-line diagnosis.
        let selectedText = reading.range(of: "text=<").flatMap { start -> String? in
            let rest = reading[start.upperBound...]
            guard let end = rest.range(of: ">") else { return nil }
            return String(rest[..<end.lowerBound])
        } ?? ""
        XCTAssertFalse(selectedText.trimmingCharacters(in: .whitespaces).isEmpty,
                       "the double tap selected WHITESPACE (\(selectedText.count) char(s)), so the coordinate missed the glyphs — this is a test-aim failure, not a drawing failure. probe[\(reading)]")
        XCTAssertGreaterThanOrEqual(selectedText.count, 3,
                                    "selected '\(selectedText)', shorter than any word in the fixture line, so the tap clipped a word edge and the pixel threshold below would be unreliable. probe[\(reading)]")

        // THE RENDER ASSERTION, which the state assertion cannot replace: the user sees pixels,
        // and a selection that exists without being drawn is still broken for them.
        //
        // 60, three times the baseline ceiling of 20, so a marginal pass cannot straddle the
        // two limits: a run reading 19 before and 21 after would satisfy both a "nothing is
        // teal" premise and a "something is teal" conclusion, and mean neither. A selected
        // word is ~3000 px at full resolution, ~170 here, so the gap is not tight.
        let heldTeal = tealPixelCount(selected)
        XCTAssertGreaterThan(heldTeal, 60,
                             "SwiftTerm holds a selection but nothing is painted in the selection colour (teal px=\(heldTeal), baseline \(baseTeal)). probe[\(reading)]")

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
