import XCTest

/// Guest push registration and the guest's Notifications control (herdrup#343), over
/// GuestMockTransport. `HERDR_MOCK_PUSH_AUTH` is iOS's notification permission before any
/// question (`granted`, `denied`, or undecided by default); the pane's DEBUG probe
/// `guest-host-calls` lists what the mock host answered, so it shows every registration.
final class GuestPushTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private let registration = "notifications.register_device:device_token=mock-apns-token-guest,platform=apns,"
        + "notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=true"

    /// The guest home over the mock host, which shares Gram and takes guest push.
    /// `HERDR_MOCK_STILL` keeps the agent idle so XCUITest actions don't wait on a pulse.
    private func launch(authorization: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "guest"
        app.launchEnvironment["HERDR_MOCK_STILL"] = "1"
        app.launchEnvironment["HERDR_MOCK_GUEST_FEATURES"] = "gram,push"
        if let authorization { app.launchEnvironment["HERDR_MOCK_PUSH_AUTH"] = authorization }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Waits until `id`'s label satisfies `condition`; fails with its last label otherwise.
    @discardableResult
    private func waitForLabel(_ app: XCUIApplication, _ id: String, _ what: String, timeout: TimeInterval = 10,
                              _ condition: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let element = element(app, id)
            if element.exists {
                last = element.label
                if condition(last) { return last }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("\(what): \(id) = \(last)")
        return last
    }

    private func openTab(_ app: XCUIApplication, _ name: String) {
        let tab = app.tabBars.firstMatch.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the guest tab bar should offer \(name)")
        tab.tap()
    }

    private func openAgent(_ app: XCUIApplication) {
        openTab(app, "Agents")
        let row = app.buttons["guest-agent-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(app, "guest-terminal").waitForExistence(timeout: 10))
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A phone iOS already lets notify registers as soon as it connects, without a question,
    /// and the guest's Settings say On. The home and the agent screen share one connection,
    /// which registers once.
    func testGrantedPermissionRegistersWithoutAskingAndShowsOn() {
        let app = launch(authorization: "granted")
        openTab(app, "Settings")
        waitForLabel(app, "guest-push-status", "a granted phone's notifications should be on") { $0 == "On" }
        XCTAssertEqual(app.buttons["guest-push-action"].label, "Turn off")
        attachScreenshot(app, "guest-push-settings-on")

        openAgent(app)
        let calls = waitForLabel(app, "guest-host-calls", "the host should hold this phone's registration") {
            $0.contains(self.registration)
        }
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "nothing to ask when iOS already allows")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(element(app, "guest-host-calls").label.components(separatedBy: "notifications.register_device").count - 1,
                       1, "one connection registers once: \(calls)")
    }

    /// "Not now" on the explanation is undone from Settings: Turn on registers.
    func testNotNowCanBeUndoneFromSettings() {
        let app = launch(authorization: nil)
        openAgent(app)
        let notNow = app.buttons["guest-push-not-now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10), "an undecided phone gets the explanation")
        notNow.tap()
        XCTAssertTrue(element(app, "guest-push-prompt").waitForNonExistence(timeout: 5))
        app.buttons["guest-back"].tap()

        openTab(app, "Settings")
        waitForLabel(app, "guest-push-status", "Not now leaves notifications off") { $0 == "Off" }
        let action = app.buttons["guest-push-action"]
        XCTAssertEqual(action.label, "Turn on")
        action.tap()
        waitForLabel(app, "guest-push-status", "Turn on should turn them on") { $0 == "On" }

        openAgent(app)
        waitForLabel(app, "guest-host-calls", "Turn on should register this phone") { $0.contains(self.registration) }
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "no second explanation once on")
    }

    /// iOS refuses: nothing registers or asks, and Settings points to iOS Settings.
    func testDeniedPermissionPointsToSettingsAndNeverRegisters() {
        let app = launch(authorization: "denied")
        openTab(app, "Settings")
        waitForLabel(app, "guest-push-status", "a refused phone says so") { $0 == "Off in iOS Settings" }
        XCTAssertEqual(app.buttons["guest-push-action"].label, "Open Settings")

        openAgent(app)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(app, "guest-push-prompt").exists, "iOS won't ask again, so neither does the app")
        XCTAssertFalse(element(app, "guest-host-calls").label.contains("notifications.register_device"))
    }
}
