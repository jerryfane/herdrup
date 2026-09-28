import XCTest

/// The owner's guest-access flow over the stateful `share` / `sharedaccess` mocks: sharing an
/// agent from its ••• menu, the invite that results, and revoking or cancelling from
/// Settings → Shared access. Each case also attaches a screenshot of the screen it proves.
final class GuestShareTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    /// `still` makes llm-opt idle: the WORKING pill's endless pulse keeps the app from ever
    /// going idle, which costs a minute per XCUITest action. Only the screenshot keeps it.
    private func launch(_ mode: String, ownerName: String = "Jerry", pendingInvite: Bool = false,
                        still: Bool = true, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mode
        app.launchEnvironment["HERDR_MOCK_OWNER_NAME"] = ownerName
        app.launchEnvironment.merge(environment) { _, new in new }
        if still { app.launchEnvironment["HERDR_MOCK_STILL"] = "1" }
        if pendingInvite { app.launchEnvironment["HERDR_MOCK_GUEST_INVITE"] = "1" }
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", needle)).firstMatch
    }

    private func shoot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)   // let sheet and row animations settle
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openShareSheet() {
        let menu = element("terminal-actions")
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the pane header never rendered")
        let item = app.buttons["Share with someone"]
        for _ in 0..<3 where !item.exists {
            menu.tap()
            _ = item.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(item.exists, "••• should offer Share with someone")
        item.tap()
        XCTAssertTrue(element("guest-share-name").waitForExistence(timeout: 5), "share sheet did not open")
    }

    private func typeGuestName(_ name: String) {
        let field = element("guest-share-name")
        field.tap()
        field.typeText(name)
    }

    // MARK: Share + invite

    /// The design's frames (mock row 1) with llm-opt WORKING, for the owner-*.png screenshots.
    /// Slow on purpose: every action waits out the pulse.
    func testCaptureShareScreens() {
        launch("share", still: false)
        XCTAssertTrue(text(containing: "Shared with plotarmordev").waitForExistence(timeout: 30))
        shoot("owner-4-chip")
        openShareSheet()
        typeGuestName("plotarmordev\n")
        shoot("owner-1-share")
        element("guest-share-create").tap()
        XCTAssertTrue(element("guest-invite-qr").waitForExistence(timeout: 30))
        shoot("owner-2-invite")
    }

    func testShareShowsTheLabelThenCreatesAnInviteWithQRAndLinks() {
        launch("share")
        // The chip names the guest who already holds llm-opt.
        XCTAssertTrue(text(containing: "Shared with plotarmordev").waitForExistence(timeout: 20),
                      "the pane header should say who the agent is shared with")

        openShareSheet()
        XCTAssertFalse(element("guest-owner-name").exists, "a known owner name must not be asked again")
        let create = element("guest-share-create")
        XCTAssertFalse(create.isEnabled, "Create invite needs a name first")

        typeGuestName("plotarmordev")
        XCTAssertTrue(text(containing: "plotarmordev (via HerdrUp):").waitForExistence(timeout: 5),
                      "the preview must show the exact label the agent will see")
        XCTAssertTrue(text(containing: "Type into the terminal").exists)
        XCTAssertTrue(text(containing: "keystrokes can't carry a name").exists)
        XCTAssertTrue(create.isEnabled)

        create.tap()
        XCTAssertTrue(element("guest-invite-qr").waitForExistence(timeout: 10), "no QR code after Create invite")
        XCTAssertTrue(app.staticTexts["Invite for plotarmordev"].exists)
        XCTAssertTrue(text(containing: "Works once · expires in 24 h").exists)
        XCTAssertTrue(text(containing: "Jerry's Mac Studio").exists)
        XCTAssertTrue(element("guest-invite-send").exists, "Send… (share sheet) is missing")
        let copy = element("guest-invite-copy")
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3), "Copy link gave no feedback")
    }

    func testAnInvalidNameIsRejectedBeforeAnythingIsSent() {
        launch("share")
        openShareSheet()
        typeGuestName("-bad name")
        XCTAssertTrue(element("guest-share-name-error").waitForExistence(timeout: 3),
                      "a name the daemon would reject must be flagged")
        XCTAssertFalse(element("guest-share-create").isEnabled)

        // 33 characters: one over the daemon's limit.
        let field = element("guest-share-name")
        field.clearAndType(String(repeating: "a", count: 33))
        XCTAssertFalse(element("guest-share-create").isEnabled, "33 characters exceeds the name rule")
        field.clearAndType(String(repeating: "a", count: 32))
        XCTAssertTrue(element("guest-share-create").isEnabled, "32 characters is allowed")
        XCTAssertFalse(element("guest-share-name-error").exists)
    }

    func testFirstShareAsksForTheOwnersNameOnce() {
        launch("share", ownerName: "-")
        openShareSheet()
        let owner = element("guest-owner-name")
        XCTAssertTrue(owner.exists, "the first share must ask for Your name")
        typeGuestName("plotarmordev")
        XCTAssertFalse(element("guest-share-create").isEnabled, "the invite needs the owner's name")

        owner.tap()
        owner.typeText("Jerry")
        let create = element("guest-share-create")
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(element("guest-invite-qr").waitForExistence(timeout: 10))

        // Close and share again: the name is remembered.
        app.swipeDown(velocity: .fast)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("guest-invite-qr"))
        waitForExpectations(timeout: 10)
        openShareSheet()
        XCTAssertFalse(element("guest-owner-name").exists, "Your name must only be asked the first time")
    }

    // MARK: Shared access

    private func openSharedAccess() {
        let row = app.staticTexts["Shared access"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Settings should list Shared access")
        row.tap()
        XCTAssertTrue(text(containing: "PEOPLE").waitForExistence(timeout: 10), "Shared access did not open")
    }

    func testSharedAccessListsPeopleAndTheActivityLog() {
        launch("sharedaccess")
        openSharedAccess()
        XCTAssertTrue(element("guest-revoke-plotarmordev").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "llm-opt on Jerry's Mac Studio").exists)
        XCTAssertTrue(text(containing: "active · 2 min ago").exists)
        XCTAssertTrue(text(containing: "SHA256:9f3a·e71c·04bd·c21e").exists, "the key fingerprint must be shown")

        // The log, newest first: upload, prompt, joined.
        let entries = app.descendants(matching: .any).matching(identifier: "guest-log-entry")
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.element(boundBy: 0).label.contains("prompt-set-v2.jsonl"))
        XCTAssertTrue(entries.element(boundBy: 1).label.contains("rerun the TensorFold bench"))
        XCTAssertTrue(entries.element(boundBy: 2).label.contains("Accepted your invite"))
        shoot("owner-3-shared-access")
    }

    func testRevokeAsksFirstThenRemovesThePersonAndLogsIt() {
        launch("sharedaccess")
        openSharedAccess()
        let revoke = element("guest-revoke-plotarmordev")
        XCTAssertTrue(revoke.waitForExistence(timeout: 10))
        revoke.tap()

        let confirm = app.buttons["Revoke"].firstMatch
        XCTAssertTrue(app.staticTexts["Revoke plotarmordev?"].waitForExistence(timeout: 5),
                      "revoking must ask for confirmation")
        shoot("owner-5-revoke-confirm")
        XCTAssertTrue(revoke.exists, "nothing is revoked before the confirmation")
        confirm.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("guest-revoke-plotarmordev"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(text(containing: "Nobody has access").exists)
        XCTAssertTrue(text(containing: "Access revoked").waitForExistence(timeout: 5),
                      "the revoke must show up in the activity log")
    }

    func testCancellingAPendingInviteRemovesIt() {
        launch("sharedaccess", pendingInvite: true)
        openSharedAccess()
        let cancel = element("guest-cancel-sam")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the pending invite should be listed")
        XCTAssertTrue(text(containing: "PENDING INVITES").exists)
        shoot("owner-6-pending-invite")
        cancel.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: cancel)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(text(containing: "PENDING INVITES").exists)
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "cancelling an invite must not touch guests")
    }

    /// mcb-air is a saved machine with no agents, so nothing in the agent list names it. Its
    /// guest must still be listed, from its own daemon, and be revocable there.
    func testAGuestOnASavedMachineWithoutAgentsIsListedAndRevocable() {
        launch("sharedaccess", environment: ["HERDR_MOCK_SAVED_PEER_GUEST": "1"])
        openSharedAccess()
        let revoke = element("guest-revoke-sam")
        XCTAssertTrue(revoke.waitForExistence(timeout: 15),
                      "a guest on an agent-less saved machine must be listed")
        XCTAssertTrue(text(containing: "notes on mcb-air").exists, "the row must name the machine that holds it")
        revoke.tap()
        XCTAssertTrue(app.staticTexts["Revoke sam?"].waitForExistence(timeout: 5))
        app.buttons["Revoke"].firstMatch.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: revoke)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "only sam is revoked")
    }

    /// A failed guest.audit must read as a failure, not as a guest who did nothing, and must
    /// not hide the people and invites that did load.
    func testAFailedAuditSaysSoInsteadOfAnEmptyLog() {
        launch("sharedaccess", pendingInvite: true, environment: ["HERDR_MOCK_AUDIT_FAIL": "1"])
        openSharedAccess()
        let failure = element("guest-log-failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "the audit failure must be shown")
        XCTAssertTrue(failure.label.contains("Couldn't load the activity log"))
        XCTAssertTrue(failure.label.contains("audit.jsonl is unreadable"), "the reason must be shown: \(failure.label)")
        XCTAssertFalse(text(containing: "Nothing yet").exists, "a failed log is not an empty one")
        XCTAssertTrue(element("guest-revoke-plotarmordev").exists, "people still load")
        XCTAssertTrue(element("guest-cancel-sam").exists, "invites still load")
        shoot("owner-7-audit-failed")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
