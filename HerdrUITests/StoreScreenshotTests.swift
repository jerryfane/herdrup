import XCTest
import UIKit

/// Captures the five App Store screens from the REAL app, at the simulator's native
/// resolution, so store artwork is regenerated from the shipping UI rather than
/// re-scaled from whatever was published last.
///
/// Not part of the normal suite's job: it asserts almost nothing and exists to produce
/// attachments. It is dispatched deliberately (`-only-testing:HerdrUITests/StoreScreenshotTests`)
/// and its output is collected from the result bundle.
///
/// Each case waits for a distinctive element of that screen before capturing, so a slow
/// launch cannot silently produce a screenshot of an empty or half-built view — which is
/// the failure mode that would quietly ship a broken store image.
final class StoreScreenshotTests: XCTestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func capture(_ mode: String, named name: String, until: (XCUIApplication) -> Bool) {
        // Store artwork for iPad is LANDSCAPE (2732x2048): the split view with its sidebar
        // is the whole reason an iPad shot differs from a phone one, and portrait hides it.
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mode
        app.launch()
        // AFTER launch, and CONFIRMED rather than assumed. Rotating before the app
        // exists does nothing (attempt 1), and a fixed sleep after the request is not
        // evidence the window rotated (attempt 2 came back portrait anyway). Poll the
        // window's own frame until it is wider than it is tall.
        if isPad {
            XCUIDevice.shared.orientation = .landscapeLeft
            let window = app.windows.firstMatch
            let rotateBy = Date().addingTimeInterval(15)
            var rotated = false
            while Date() < rotateBy {
                let f = window.frame
                if f.width > f.height { rotated = true; break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            XCTAssertTrue(rotated,
                          "the window never rotated to landscape; frame \(window.frame)")
            Thread.sleep(forTimeInterval: 1.0)   // let the split view re-lay-out
        }

        let deadline = Date().addingTimeInterval(20)
        var ready = false
        while Date() < deadline {
            if until(app) { ready = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(ready, "\(mode) never reached a capturable state")

        // Let the first paint settle: animations and async rows land after the element
        // that proves the screen exists.
        Thread.sleep(forTimeInterval: 1.5)

        // `app.screenshot()`, not `XCUIScreen.main.screenshot()`: the screen's capture
        // comes back in the device's NATIVE orientation however the app is rotated - the
        // second reason that attempt was portrait.
        let shot = app.screenshot()
        // The size goes in the NAME rather than an assertion. Both capture APIs return
        // the device's native orientation even when the window has rotated - confirmed
        // here, where the rotation poll passes and the capture is still 1032x1376 - so a
        // portrait-shaped file does not by itself mean the layout is portrait. Recording
        // the dimensions lets the caller settle that from the artefact instead of
        // spending a CI round per guess.
        let size = shot.image.size
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testCaptureAgents() {
        capture("list", named: "store-01-agents") { $0.staticTexts["Agents"].exists }
    }

    func testCaptureTerminal() {
        capture("pane", named: "store-02-terminal") { $0.otherElements["terminal-surface"].exists || $0.staticTexts["Terminal"].exists }
    }

    func testCaptureGram() {
        // "Gram" as a title exists only on PHONE: at regular width the page draws no
        // header of its own - the host renders that section's controls in the app's real
        // sidebar - so waiting for it on iPad waits forever. The composer is present in
        // both layouts, which is what makes it the right readiness signal.
        capture("gram", named: "store-03-gram") {
            $0.textViews["Message an agent…"].exists
                || $0.textFields["Message an agent…"].exists
                || $0.staticTexts["Gram"].exists
        }
    }

    func testCaptureSettings() {
        capture("settings", named: "store-04-settings") { $0.staticTexts["Settings"].exists }
    }

    func testCaptureConnect() {
        capture("onboarding", named: "store-05-connect") { $0.buttons["Connect"].exists || $0.staticTexts["herdrup"].exists }
    }
}
