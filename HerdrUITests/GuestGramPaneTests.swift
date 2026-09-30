import XCTest

/// A guest's Gram tab and push for the shared agent (herdrup#338), over GuestMockTransport.
/// `HERDR_MOCK_GUEST_FEATURES` sets what the mock host's hello advertises. The DEBUG probes
/// `guest-host-calls` (the Gram and push calls the host answered, with their arguments) and
/// `guest-forbidden-calls` (calls it refused) are the host's side of each check.
final class GuestGramPaneTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// `HERDR_MOCK_STILL` keeps the agent idle: the WORKING pill's pulse never ends, and an
    /// app that never idles costs every XCUITest action its full idle timeout.
    private func launch(_ mock: String = "guestpane", features: String?,
                        environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mock
        app.launchEnvironment["HERDR_MOCK_STILL"] = "1"
        if let features { app.launchEnvironment["HERDR_MOCK_GUEST_FEATURES"] = features }
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func probe(_ app: XCUIApplication, _ id: String) -> String {
        let probe = element(app, id)
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the DEBUG probe \(id) should exist")
        return probe.label
    }

    /// Polls a probe until `condition` holds; fails with its last label otherwise.
    @discardableResult
    private func waitForProbe(_ app: XCUIApplication, _ id: String, _ what: String, timeout: TimeInterval = 10,
                              _ condition: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let probe = element(app, id)
            if probe.exists {
                last = probe.label
                if condition(last) { return last }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("\(what): \(id) = \(last)")
        return last
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openGramTab(_ app: XCUIApplication) {
        let tab = app.buttons["guest-tab-gram"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "a host that shares Gram should offer the Gram tab")
        let list = element(app, "guest-gram-list")
        for _ in 0..<3 where !list.exists {
            tab.tap()
            _ = list.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(list.exists, "the Gram tab should show the list")
    }

    // MARK: Gram tab

    /// The tab lists the agent's Grams and the guest's own post, newest first, and counts the
    /// unread ones until the guest looks: then they are marked read on the host, for this
    /// guest only.
    func testGramTabListsTheSharedAgentsGramsAndMarksThemReadWhenViewed() {
        let app = launch(features: "gram")
        let badge = element(app, "guest-gram-unread")
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "unread Grams should show a count before the tab opens")
        XCTAssertEqual(badge.label, "2")
        XCTAssertTrue(app.buttons["guest-tab-terminal"].exists)

        openGramTab(app)
        let rows = ["gm-4", "gm-3", "gm-2", "gm-1"].map { element(app, "guest-gram-row-\($0)") }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 5), "row \(row) should render") }
        XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY, "newest first")
        XCTAssertLessThan(rows[2].frame.minY, rows[3].frame.minY, "newest first")
        XCTAssertTrue(app.staticTexts["Here's the Q5 table: decode is up 36% over Q4, prefill flat."].exists)
        XCTAssertTrue(app.staticTexts["You → llm-opt"].exists, "the guest's own post is labelled as theirs")
        XCTAssertTrue(app.buttons["guest-gram-file-gm-4"].exists, "the agent's file is offered")

        waitForProbe(app, "guest-host-calls", "viewing the list should mark its unread Grams read") {
            $0.contains("gram.mark_read:gm-2,gm-4")
        }
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "nothing is unread once seen")
        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot(app, "guest-gram-tab")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "", "the Gram tab calls only what a guest may")
    }

    /// A file downloads from the host in its bounded pieces and opens.
    func testOpeningAGramFileDownloadsItInPiecesAndOpensIt() {
        let app = launch(features: "gram")
        openGramTab(app)
        let file = app.buttons["guest-gram-file-gm-4"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()

        // The viewer covers the pane; its probe reappears once the viewer is dismissed.
        let opened = { (calls: String) in calls.contains("opened:tensorfold-q5.md") }
        let deadline = Date().addingTimeInterval(20)
        var calls = ""
        while Date() < deadline {
            let probe = element(app, "guest-host-calls")
            if probe.exists { calls = probe.label; if opened(calls) { break } }
            for label in ["Done", "Close"] where app.buttons[label].exists {
                attachScreenshot(app, "guest-gram-file-open")
                app.buttons[label].tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(opened(calls), "the file should download and open: \(calls)")
        XCTAssertTrue(calls.contains("gram.get_file_chunk:gm-4@0"), calls)
        XCTAssertTrue(calls.contains("gram.get_file_chunk:gm-4@1024"), "later pieces start where the last ended: \(calls)")
        XCTAssertFalse(element(app, "guest-gram-file-error").exists, "the download should not fail")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// Without Gram sharing, or on a host older than the features object, there is no Gram
    /// tab and the app never asks for Gram.
    func testNoGramTabWhenTheHostDoesNotShareGram() {
        for features in ["none", nil] as [String?] {
            let app = launch(features: features)
            XCTAssertTrue(element(app, "guest-terminal").waitForExistence(timeout: 10))
            XCTAssertTrue(element(app, "guest-view-only-note").waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3)
            XCTAssertFalse(app.buttons["guest-tab-gram"].exists, "no Gram tab for features \(String(describing: features))")
            XCTAssertFalse(element(app, "guest-push-prompt").exists, "no push offer without push")
            XCTAssertEqual(probe(app, "guest-forbidden-calls"), "", "the app must not ask for Gram")
            XCTAssertEqual(probe(app, "guest-host-calls"), "")
            app.terminate()
        }
    }

    // MARK: Push

    /// The first open on a host that takes guest push explains why, then "Turn on" registers
    /// this device's token with every status kind on and Gram pushes as shared.
    func testTurningOnPushRegistersThisDeviceWithTheHost() {
        let app = launch(features: "gram,push")
        let prompt = element(app, "guest-push-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the first open should explain notifications")
        XCTAssertEqual(probe(app, "guest-host-calls").contains("notifications.register_device"), false,
                       "nothing registers before the guest says yes")
        attachScreenshot(app, "guest-push-prompt")
        app.buttons["guest-push-enable"].tap()

        waitForProbe(app, "guest-host-calls", "Turn on should register the device") {
            $0.contains("notifications.register_device:device_token=mock-apns-token-guest,platform=apns,"
                + "notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=true")
        }
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5), "the explanation goes once answered")
        XCTAssertEqual(probe(app, "guest-forbidden-calls"), "")
    }

    /// Where the owner doesn't share Gram, the device registers for status pushes only.
    func testPushWithoutGramRegistersStatusKindsOnly() {
        let app = launch(features: "push")
        let enable = app.buttons["guest-push-enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        enable.tap()
        waitForProbe(app, "guest-host-calls", "Turn on should register the device") {
            $0.contains("notify_needs_input=true,notify_dies=true,notify_finishes=true,notify_gram=false")
        }
        XCTAssertFalse(app.buttons["guest-tab-gram"].exists)
    }

    /// A tapped Gram push for the share opens its agent on the Gram tab; a status push opens
    /// the terminal. Neither lands on an owner screen.
    func testTappedGuestPushOpensTheSharesGramOrTerminal() {
        let payload = { (kind: String) in
            #"{"aps":{"alert":{"title":"llm-opt","body":"New Gram"}},"herdr_guest":{"host_id":"AAECAwQFBgcICQoLDA0ODw","guest_id":"g-7f2c","kind":"\#(kind)","gram_id":"gm-4"}}"#
        }
        var app = launch("guest", features: "gram", environment: ["HERDR_MOCK_PUSH_TAP": payload("gram")])
        XCTAssertTrue(element(app, "guest-gram-list").waitForExistence(timeout: 15),
                      "a Gram push should open the share's Gram tab")
        XCTAssertTrue(element(app, "guest-gram-row-gm-4").waitForExistence(timeout: 5))
        app.terminate()

        app = launch("guest", features: "gram", environment: ["HERDR_MOCK_PUSH_TAP": payload("status")])
        XCTAssertTrue(element(app, "guest-terminal").waitForExistence(timeout: 15),
                      "a status push should open the share's terminal")
        XCTAssertTrue(app.buttons["guest-tab-gram"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "guest-gram-list").exists, "a status push opens the terminal, not Gram")
    }
}
