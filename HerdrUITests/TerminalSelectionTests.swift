import XCTest
import UIKit

/// THE REGRESSION RECEIPT for double-tap word selection.
///
/// A review found the repaired behaviour unguarded: a compiling mutant that removes
/// `clearTap.require(toFail: t)` restores the original defect, where the app's own tap
/// recognizer clears the word SwiftTerm selected on the SAME touch-up, and nothing in the
/// suite noticed.
///
/// THE FIRST VERSION OF THIS FILE WAS PIXEL-BASED AND WAS WEAK, which its own CI run
/// exposed. It asserted "the selection is still there" by diffing against the pre-selection
/// baseline, and ANY difference satisfied that, including SwiftTerm's context menu simply
/// being on screen. The final assertion then failed with a diff of exactly 0.0, which is the
/// signature of a screen where nothing was left to change: the earlier step had passed for
/// the wrong reason. Pixels cannot tell a selection from a popover.
///
/// So this asserts on the CLIPBOARD instead, which cannot be satisfied by accident: a word
/// only reaches the pasteboard if a selection existed AND Copy acted on it. That also
/// settles, rather than assumes, the open question about `UIMenuController` being deprecated
/// at iOS 16: if the menu never presents, this test says so directly.
final class TerminalSelectionTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
        UIPasteboard.general.string = ""   // a stale clipboard would fake a pass
    }

    func testDoubleTapSelectsAWordCopyWorksAndASingleTapDismisses() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "scroll"
        app.launch()

        // The mock feeds 200 numbered lines into a real SwiftTerm view asynchronously.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) PREMISE: an untouched terminal is static, so a later pixel change means the
        // gesture did something rather than the stream repainting under us.
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

        // (3) THE COPY PATH. SwiftTerm presents Copy through UIMenuController, and
        // canPerformAction only offers it while a selection is active, so the item existing
        // IS the proof that a selection survived the same touch-up that created it. This is
        // where the mutant shows: with the clear tap firing on tap 2, there is no selection
        // by now and no Copy item.
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 4),
                      "no Copy item after a double tap. Either the selection was cleared on the same touch-up (the regression this file guards) or UIMenuController no longer presents on this OS, which is a finding in its own right")

        copy.tap()
        Thread.sleep(forTimeInterval: 1.0)

        // (4) THE UNAMBIGUOUS ASSERTION: a word is on the clipboard. Nothing but a real
        // selection plus a working Copy can produce this.
        let pasted = UIPasteboard.general.string ?? ""
        XCTAssertFalse(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Copy put nothing on the clipboard, so no selection was actually held")
        // The mock seeds numbered lines, so whatever was selected should be printable text
        // rather than control bytes.
        XCTAssertNil(pasted.rangeOfCharacter(from: CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)),
                     "clipboard holds control bytes (\(pasted.debugDescription)); that is not selected screen text")

        // (5) DESELECTION still works, so the fix did not simply disable it. A genuine
        // single tap must leave no Copy item behind, which is a state assertion rather than
        // a pixel guess.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.70)).tap()
        Thread.sleep(forTimeInterval: 2.0)
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
