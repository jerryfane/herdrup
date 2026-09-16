import XCTest

/// Screenshots the Live Activity layout so it can be LOOKED at.
///
/// XCUITest cannot see a real Live Activity, which is why three rounds of this design
/// shipped judged only by arithmetic and two came back wrong from the owner's phone.
/// `ScreenshotMock.widgets` renders the widget's own views — same file, same private
/// types — over a bright and a dark backdrop; this captures them as attachments, which
/// CI keeps in the result bundle.
///
/// It asserts almost nothing on purpose: its product is the image. The one assertion is
/// that the gallery rendered at all, so a crash or an empty screen cannot pass as a
/// receipt.
final class WidgetGalleryTests: XCTestCase {
    func testCaptureLiveActivityLayouts() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "widgets"
        app.launch()

        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 20),
                      "the gallery must render before anything is captured")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "live-activity-open").firstMatch.waitForExistence(timeout: 10),
                      "the card's action must render, not just the gallery container")

        // Let the timers settle before the first capture.
        Thread.sleep(forTimeInterval: 1.5)
        attach(named: "widget-gallery-top")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.0)
        attach(named: "widget-gallery-middle")

        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.0)
        attach(named: "widget-gallery-bottom")

        for index in 0..<8 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            attach(named: "widget-gallery-scroll-\(index)")
        }
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
