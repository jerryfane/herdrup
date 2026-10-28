import XCTest

/// In-app herdr updates (herdrup#565, proposal B) over the `serverupdate` mock server: the
/// Settings tab's "1" and the update card in Settings › Machines, in every state, on whichever
/// device runs the class (the iPhone app round, and the iPad by `only_device=ipad`).
final class ServerUpdateUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        XCUIApplication.launched(mock: "serverupdate", environment: ["HERDR_MOCK_UPDATE": scenario])
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func settingsTab(_ app: XCUIApplication) -> XCUIElement {
        isPad ? app.buttons.matching(NSPredicate(format: "label == 'Settings'")).firstMatch
              : app.tabBars.buttons["Settings"]
    }

    /// Opens Settings › Machines (the iPad split shows Machines by default).
    private func openMachines(_ app: XCUIApplication) {
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Settings tab")
        tab.tap()
        if !isPad {
            let machines = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Machines'")).firstMatch
            XCTAssertTrue(machines.waitForExistence(timeout: 10), "no Machines row")
            machines.tap()
        }
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["server-update-card"].firstMatch
    }

    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["server-update-title"].firstMatch
    }

    private func waitForTitle(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 30) -> Bool {
        let predicate = NSPredicate(format: "label == %@", text)
        return title(app).waitForExistence(timeout: 2)
            && XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title(app))],
                                timeout: timeout) == .completed
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "update-\(name)-\(isPad ? "ipad" : "iphone")"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func settingsBadgeValue(_ app: XCUIApplication) -> String {
        settingsTab(app).value as? String ?? ""
    }

    private func confirmUpdate(_ app: XCUIApplication, button: String = "Update") {
        app.buttons["server-update-button"].tap()
        let confirm = app.alerts.buttons[button]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        record(app, "confirm")
        confirm.tap()
    }

    // MARK: States

    func testAvailableShowsBadgeAndCard() {
        let app = launch("available")
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let badged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '1'"), object: tab)
        XCTAssertEqual(XCTWaiter().wait(for: [badged], timeout: 15), .completed,
                       "the Settings tab should carry a 1; value \(settingsBadgeValue(app))")
        record(app, "badge")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        XCTAssertTrue(app.staticTexts["Folders and avatars need herdr 0.9.5. mac-mini has 0.9.3."].exists)
        XCTAssertTrue(app.buttons["server-update-button"].exists)
        record(app, "available")
    }

    func testUpdatingShowsProgressAndTerminalsStayOpen() {
        let app = launch("updating")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Updating herdr"))
        let now = app.staticTexts["server-update-now"]
        let downloading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Downloading 12 of 38 MB'"), object: now)
        XCTAssertEqual(XCTWaiter().wait(for: [downloading], timeout: 15), .completed, "now: \(now.label)")
        XCTAssertTrue(app.staticTexts["Your terminals stay open. You can leave this screen."].exists)
        record(app, "updating")
    }

    /// The update drops the connection while it switches: the card follows it to Done.
    func testDoneAfterTheHandoff() {
        let app = launch("available")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "herdr 0.9.5 is running", timeout: 40))
        XCTAssertTrue(app.staticTexts["All 14 terminals stayed open. Folders and avatars are on."].exists)
        record(app, "done")
    }

    func testFailedOffersTryAgainAndCopyDetails() {
        let app = launch("failed")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Update didn't finish", timeout: 30))
        XCTAssertTrue(app.staticTexts["Nothing changed. herdr 0.9.3 is still running, and your terminals are fine."].exists)
        XCTAssertTrue(app.staticTexts["The download stopped at 21 of 38 MB."].exists)
        record(app, "failed")
        app.buttons["server-update-copy-details"].tap()
        XCTAssertTrue(app.buttons["server-update-copy-details"].staticTexts["Copied"].waitForExistence(timeout: 5))
        app.buttons["server-update-retry"].tap()
        XCTAssertTrue(waitForTitle(app, "herdr 0.9.5 is running", timeout: 40), "the retry should succeed")
    }

    func testRolledBackCannotBeRetried() {
        let app = launch("rolledback")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app)
        XCTAssertTrue(waitForTitle(app, "Update didn't finish", timeout: 40))
        XCTAssertTrue(app.staticTexts["The new version didn't pass its checks, so herdr switched back to 0.9.3. Your terminals are fine."].exists)
        XCTAssertFalse(app.buttons["server-update-retry"].exists)
        record(app, "rolledback")
    }

    func testRestartNeededDownloadsForTheNextRestart() {
        let app = launch("restart")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr on mac-mini"))
        confirmUpdate(app, button: "Download")
        XCTAssertTrue(waitForTitle(app, "Downloaded. Finishes on next restart", timeout: 40))
        XCTAssertTrue(app.staticTexts["Restarting herdr closes terminals. Your layout comes back."].exists)
        record(app, "restart")
    }

    func testTooOldShowsTheCommandsToRunOnce() {
        let app = launch("old")
        openMachines(app)
        XCTAssertTrue(waitForTitle(app, "Update herdr once on mac-mini"))
        let handoff = app.buttons["Copy command: herdr update --handoff"]
        XCTAssertTrue(handoff.exists)
        handoff.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        record(app, "old")
    }

    /// A connection that is not the owner's is refused the check: no badge, no card.
    func testGuestSeesNothing() {
        let app = launch("guest")
        let tab = settingsTab(app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        sleep(3)
        XCTAssertFalse(settingsBadgeValue(app).contains("1"), "no badge for a non-owner")
        openMachines(app)
        sleep(3)
        XCTAssertFalse(card(app).exists, "no update card for a non-owner")
        record(app, "guest")
    }
}
