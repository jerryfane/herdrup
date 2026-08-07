import XCTest
import UIKit

/// The automated SCROLL RECEIPT (JARVIS standing-rule 47874: no scroll change ships on
/// static review alone — a real drag must be exercised). Launches the app into a REAL
/// SwiftTerm pane seeded with 200 lines of scrollback (HERDR_SCREENSHOT_MOCK=scroll),
/// then:
///   1. proves the terminal is STATIC when untouched (two screenshots ~identical) — so
///      the scroll assertion can't be faked by ambient animation, and
///   2. swipes the terminal and asserts the rendered pixels MOVED substantially.
/// Dead scroll (the 7-build symptom) = unchanged pixels after the swipe = this fails.
/// Before/after screenshots are attached so the CI artifact is the visual proof.
final class ScrollTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTerminalScrollsWhenSwiped() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "scroll"
        app.launch()

        // Let the app launch and the mock stream feed all 200 lines into the real
        // SwiftTerm view (async), so there is scrollback to move.
        Thread.sleep(forTimeInterval: 3.0)

        // (1) STATIC CHECK: with the cursor hidden by the seed, an untouched terminal
        // must render essentially identically frame to frame. If it doesn't, some
        // animation is running and the scroll assertion below would be unreliable.
        let before = app.screenshot()
        Thread.sleep(forTimeInterval: 1.0)
        let beforeAgain = app.screenshot()
        let idleDiff = pixelDiffFraction(before, beforeAgain)
        attach(before, name: "01-before")
        XCTAssertLessThan(idleDiff, 0.02,
            "Terminal is not static when untouched (diff=\(idleDiff)); a moving element would invalidate the scroll check.")

        // (2) SWIPE: drag DOWN on the terminal body (below the header, above the reply
        // bar) to reveal older scrollback. Three firm drags to move a clear distance.
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let low  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        for _ in 0..<3 {
            high.press(forDuration: 0.05, thenDragTo: low)
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)   // let scroll settle + repaint

        let after = app.screenshot()
        attach(after, name: "02-after-swipe")
        let movedDiff = pixelDiffFraction(before, after)

        // A real scroll shifts ~a screen of distinct numbered lines → a large fraction
        // of pixels change. Dead scroll leaves them identical (movedDiff ~ 0).
        XCTAssertGreaterThan(movedDiff, 0.10,
            "Terminal did NOT scroll: rendered content is unchanged after swiping (diff=\(movedDiff)). This is the dead-scroll symptom.")
    }

    // MARK: - helpers

    private func attach(_ shot: XCUIScreenshot, name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Fraction of pixels that differ (beyond a small per-pixel threshold) between two
    /// screenshots, compared at a fixed small resolution so PNG-encoding jitter and
    /// antialiasing don't register as change. 0 = identical, 1 = fully different.
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
            if d > 30 { differing += 1 }   // channel-sum threshold: ignores tiny jitter
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
