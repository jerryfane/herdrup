import XCTest

extension XCTestCase {
    /// Keeps `shot` in the result bundle as `name`, whether the test passes or fails.
    @nonobjc func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Keeps a screenshot of `app` in the result bundle as `name`.
    @nonobjc func attach(_ app: XCUIApplication, _ name: String) {
        attach(app.screenshot(), name)
    }
}
