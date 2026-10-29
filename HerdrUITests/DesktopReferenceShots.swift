import CryptoKit
import XCTest

/// Herdrup Desktop's pixel-parity references (herdrup-desktop#16): the Agents home on iPad,
/// landscape, over the desktop's fake herdr, in every state the list can show. Each state is
/// one attachment, `ref-<device>-<state>.png`, with its conditions beside it in
/// `ref-<device>-<state>.json`. design/reference/agent-list/README.md says how they become
/// the committed references.
///
/// `populated` and its expansions serve the desktop's own cmd/fakeherdr/agents.json. The
/// served states (folders, avatars, sessions, federated, needs you) serve
/// HerdrUITests/Fixtures/desktop-reference-<state>.json, which the desktop's fake herdr
/// serves too.
///
/// CI pins the status bar (`simctl status_bar override`) before this class runs; the app
/// (`HERDR_SCREENSHOT_MOCK=desktopref`) holds every animation still and pins its clock.
final class DesktopReferenceShots: XCTestCase {
    /// jerryfane/herdrup-desktop cmd/fakeherdr/agents.json at 0b5111ed47fb2325f6caf4a383758209c6d6c9f6.
    static let fixtureName = "desktop-reference-agents"
    static let fixtureSHA256 = "f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2"
    static let clock = "2026-10-28T09:41:00Z"

    /// The served states' fixtures (HerdrUITests/Fixtures/desktop-reference-<name>.json), by
    /// name, with their sha256.
    static let servedSHA256: [String: String] = [
        "folders": "3caf0afb562d97779d07a4080dd4a92d1be414f308370baea9de2e5e226823b0",
        "avatars": "c4db4b975cd231e89d95c711048089a5055769ef05c3386f7038472a2aa28514",
        "sessions": "a7e1acbcb2de2be2d29309e7976e6d7bab2ac89a7123e8804a6d40ad3018cdd5",
        "federated": "cbad3a2d6115309845b70d9d7a1db6793c356bb943dc4c754b7727b74405ebcf",
        "needs-you": "851d7f7e03f8b31f8a932aa24f83cecbe0677184ed4afc2aacef6ff8f903df2e",
    ]
    /// The uploaded picture the avatars state serves (HerdrUITests/Fixtures/desktop-reference-avatar.png).
    static let avatarSHA256 = "e4d4139d5914062cd06d5b6cbd8ade1d5fddf83c20ee575d4d83b8d81de38a4a"
    static let contentSize = "UICTContentSizeCategoryL"

    /// The two reference iPads, by their landscape window in points.
    static let devices: [String: String] = [
        "1376x1032": "ipad-pro-13",
        "1180x820": "ipad-11",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Hands the device back in portrait, as GramColumnTests does: AgentListChromeTests runs
    /// next on the same iPad and measures its window chrome in portrait (run 40702149432).
    override func tearDown() {
        XCUIApplication().terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testLoading() throws {
        let (app, device) = try launch("loading")
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 20),
                      "the sidebar should show its spinner while agent.list has not answered")
        capture(app, device: device, state: "loading")
    }

    func testEmpty() throws {
        let (app, device) = try launch("empty")
        XCTAssertTrue(app.staticTexts["no agents"].waitForExistence(timeout: 20),
                      "an empty agent.list should say so")
        capture(app, device: device, state: "empty")
    }

    func testPopulated() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        capture(app, device: device, state: "populated")
    }

    func testIdleExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        expand(app, "Idle, 2", showing: [row(app, "w2:p2"), row(app, "w2:p3")])
        capture(app, device: device, state: "idle-expanded")
    }

    func testArchivedExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        expand(app, "Archived, 1", showing: [app.staticTexts["old-spike"]])
        capture(app, device: device, state: "archived-expanded")
    }

    func testAllExpanded() throws {
        let (app, device) = try launch("populated")
        assertDefaultRoster(app)
        // Archived first: it is the last row, so opening Idle first could push it below
        // the 11-inch fold before it is tapped.
        expand(app, "Archived, 1", showing: [app.staticTexts["old-spike"]])
        expand(app, "Idle, 2", showing: [row(app, "w2:p2"), row(app, "w2:p3")])
        capture(app, device: device, state: "all-expanded")
    }

    /// Folders and stars (`agent_groups`): Herdr open with its two agents, Enyo closed, and
    /// vetrina starred.
    func testFolders() throws {
        let (app, device) = try launch("folders", served: "folders")
        let herdr = element(app, "agent-folder-herdr"), enyo = element(app, "agent-folder-enyo")
        XCTAssertTrue(herdr.waitForExistence(timeout: 20), "the folders document should load")
        XCTAssertTrue(enyo.waitForExistence(timeout: 10), "Enyo should be listed")
        XCTAssertTrue(row(app, "w1:p1").waitForExistence(timeout: 10), "vetrina should be listed")
        XCTAssertTrue(row(app, "w1:p1").label.contains("starred"), "vetrina should show its star, got \(row(app, "w1:p1").label)")
        XCTAssertEqual(herdr.value as? String, "collapsed, 1 waiting, 0 stopped", "folders start closed")
        herdr.tap()
        if !poll(3, every: 0.25, { (herdr.value as? String)?.hasPrefix("expanded") == true }) { herdr.tap() }
        XCTAssertTrue(poll(10, every: 0.25) { (herdr.value as? String)?.hasPrefix("expanded") == true },
                      "tapping Herdr should open it")
        for pane in ["w1:p2", "w1:p3"] {
            XCTAssertTrue(row(app, pane).waitForExistence(timeout: 10), "open Herdr should show \(pane)")
        }
        XCTAssertTrue((enyo.value as? String)?.hasPrefix("collapsed") == true, "Enyo should stay closed")
        XCTAssertFalse(row(app, "w2:p1").exists, "closed Enyo should hide enyo-review")
        capture(app, device: device, state: "folders")
    }

    /// Avatars (`agent_avatar`): atlas's uploaded picture, nova's mascot, quill's initial tile.
    func testAvatars() throws {
        let (app, device) = try launch("avatars", served: "avatars")
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            XCTAssertTrue(row(app, pane).waitForExistence(timeout: 20), "\(pane) should be listed")
        }
        XCTAssertTrue(avatar(app, in: row(app, "w1:p1"), "image", named: "Photo"), "atlas should show its picture")
        XCTAssertTrue(avatar(app, in: row(app, "w1:p2"), "cub", named: "Cub"), "nova should show the Cub mascot")
        XCTAssertTrue(avatar(app, in: row(app, "w1:p3"), "initial", named: "Initial Q"), "quill should show its initial tile")
        capture(app, device: device, state: "avatars")
    }

    /// Session pills: default (this one), personal and work running, work with 2 waiting.
    func testSessions() throws {
        let (app, device) = try launch("sessions", served: "sessions")
        XCTAssertTrue(row(app, "w1:p1").waitForExistence(timeout: 20), "the roster should load")
        XCTAssertTrue(app.buttons["work, 2 need you"].waitForExistence(timeout: 20),
                      "work's pill should count its 2 waiting agents")
        XCTAssertTrue(app.buttons["personal"].exists, "personal should have a pill with no count")
        XCTAssertTrue(app.buttons["default"].exists, "the default session should have a pill")
        XCTAssertTrue(app.buttons["default"].isSelected, "the home is on the default session")
        XCTAssertFalse(app.buttons["scratch"].exists, "a stopped session has no pill")
        capture(app, device: device, state: "sessions")
    }

    /// Federated rows: mcb-air/scout reachable, mac-studio/render offline, homelab/backup
    /// unconfirmed (degraded peer, last known blocked).
    func testFederated() throws {
        let (app, device) = try launch("federated", served: "federated")
        for pane in ["w1:p1", "air/w1:p2", "studio/w1:p4", "nas/w2:p1"] {
            XCTAssertTrue(row(app, pane).waitForExistence(timeout: 20), "\(pane) should be listed")
        }
        XCTAssertTrue(row(app, "air/w1:p2").label.contains("mcb-air/scout"),
                      "a federated agent is named by its machine label, got \(row(app, "air/w1:p2").label)")
        XCTAssertTrue(element(app, "agent-row-stale-marker").waitForExistence(timeout: 10),
                      "the degraded peer's row should be marked stale")
        capture(app, device: device, state: "federated")
    }

    /// The needs-you pill: scrolled to the end of the list, the 3 waiting rows are out of
    /// sight and the pill under the top bar counts them.
    func testNeedsYouPill() throws {
        let (app, device) = try launch("needs-you", served: "needs-you")
        XCTAssertTrue(row(app, "w1:p1").waitForExistence(timeout: 20), "the roster should load")
        let pill = element(app, "needs-you-pill")
        XCTAssertFalse(pill.exists, "no pill while the waiting rows are on screen")
        // The end of the list, not a drag distance: the one scroll position every run, and
        // the desktop, can reach exactly. Working rows sort by pane id as strings (no
        // completed turns), so the last row is auth, w2:p9. Once it is on screen, three more
        // swipes pin the list against its end.
        let roster = app.scrollViews["agent-roster-scroll"]
        let last = row(app, "w2:p9")
        for _ in 0..<12 where !(last.exists && last.isHittable) { roster.swipeUp() }
        for _ in 0..<3 { roster.swipeUp() }
        XCTAssertTrue(last.waitForHittable(timeout: 5), "the last row should be on screen")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the pill should show once the waiting rows are out of sight")
        XCTAssertEqual(pill.label, "3 agents need you")
        capture(app, device: device, state: "needs-you-pill")
    }

    /// The minimised sidebar: the rail's needs-you and working counts.
    func testNeedsYouRail() throws {
        let (app, device) = try launch("needs-you", served: "needs-you")
        XCTAssertTrue(row(app, "w1:p1").waitForExistence(timeout: 20), "the roster should load")
        let toggle = app.buttons["terminal-sidebar-toggle"]
        XCTAssertTrue(toggle.waitForHittable(timeout: 10), "the sidebar's Minimise button should be on screen")
        toggle.tap()
        let count = app.descendants(matching: .any)["3 need you"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the rail should count 3 agents that need you")
        XCTAssertTrue(app.descendants(matching: .any)["20 working"].exists, "the rail should count 20 working")
        capture(app, device: device, state: "needs-you-rail")
    }

    // MARK: Launch

    /// The fixture the launched state serves and its sha256, for the capture's record.
    private var served: (name: String, sha256: String)?

    /// Launches the mock in landscape at the default text size and returns the app and
    /// the device name for the attachments. Fails unless the app runs full screen on one
    /// of the reference iPads at @2x, dark, with the clock pinned. `served` names the
    /// state's fixture, desktop-reference-<served>.json; nil serves the desktop's agents.json.
    private func launch(_ state: String, served name: String? = nil) throws -> (XCUIApplication, String) {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the desktop references are iPad screenshots")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = [
            "HERDR_SCREENSHOT_MOCK": "desktopref",
            "HERDR_DESKTOPREF_STATE": state,
            "HERDR_MOCK_NOW": Self.clock,
        ]
        if let name {
            let sha256 = try XCTUnwrap(Self.servedSHA256[name], "no sha256 recorded for \(name)")
            app.launchEnvironment["HERDR_DESKTOPREF_SERVED"] = try vendored("desktop-reference-\(name)", "json", sha256: sha256)
            served = (name, sha256)
        } else {
            app.launchEnvironment["HERDR_DESKTOPREF_AGENT_LIST"] = try fixture()
            served = nil
        }
        if name == "avatars" { try assertServedAvatarIsTheAsset() }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", Self.contentSize]
        app.launch()

        let probe = app.otherElements["desktopref-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the desktopref probe should be on screen")
        let fields = conditions(probe)
        let window = fields["window"] ?? "?"
        let device = try XCTUnwrap(Self.devices[window],
                                   "window \(window) is not a reference iPad in landscape full screen (probe: \(fields))")
        XCTAssertEqual(fields["scale"], "2", "references are @2x")
        XCTAssertEqual(fields["style"], "dark")
        XCTAssertEqual(fields["contentSize"], Self.contentSize)
        XCTAssertEqual(fields["now"], Self.clock)
        return (app, device)
    }

    /// The vendored fixture, checked against the sha256 the references record.
    private func fixture() throws -> String {
        try vendored(Self.fixtureName, "json", sha256: Self.fixtureSHA256)
    }

    /// A vendored file's bytes as UTF-8, checked against the sha256 the references record.
    private func vendored(_ name: String, _ ext: String, sha256: String) throws -> String {
        try XCTUnwrap(String(data: vendoredData(name, ext, sha256: sha256), encoding: .utf8))
    }

    private func vendoredData(_ name: String, _ ext: String, sha256: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                                "\(name).\(ext) should be in the test bundle")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Self.sha256(data), sha256, "the vendored \(name).\(ext) is not the one the references name")
        return data
    }

    /// The avatars fixture serves exactly the committed picture, under its own sha256.
    private func assertServedAvatarIsTheAsset() throws {
        let png = try vendoredData("desktop-reference-avatar", "png", sha256: Self.avatarSHA256)
        let served = try vendoredData("desktop-reference-avatars", "json",
                                      sha256: try XCTUnwrap(Self.servedSHA256["avatars"]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: served) as? [String: Any])
        let images = try XCTUnwrap(object["agent.avatar.get"] as? [String: Any])
        let image = try XCTUnwrap(images[Self.avatarSHA256] as? [String: Any], "the picture is not served by its sha256")
        let base64 = try XCTUnwrap(image["data_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64), png, "the served picture is not desktop-reference-avatar.png")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The probe's `key=value;…` accessibility value.
    private func conditions(_ probe: XCUIElement) -> [String: String] {
        let value = probe.value as? String ?? ""
        var fields: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    // MARK: Roster

    private func row(_ app: XCUIApplication, _ paneID: String) -> XCUIElement {
        element(app, "agent-row-\(paneID)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Whether `row` draws the avatar `kind` (`agent-avatar-<kind>`, labelled `named`): by
    /// that avatar inside the row, or, where the row merges its children into one element,
    /// by the row's label (as AgentAvatarUITests checks). Waits for a picture to load.
    private func avatar(_ app: XCUIApplication, in row: XCUIElement, _ kind: String, named: String) -> Bool {
        poll(15, every: 0.25) {
            guard row.exists else { return false }
            let frame = row.frame
            let inside = app.descendants(matching: .any).matching(identifier: "agent-avatar-\(kind)")
                .allElementsBoundByIndex
                .contains { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) && $0.label.contains(named) }
            let loading = app.descendants(matching: .any)["agent-avatar-loading"].exists
            return inside || (!loading && row.label.contains(named))
        }
    }

    /// The fixture as the roster first draws it: needs you (api-review, docs), the
    /// unreachable studio/render, working (web, infra), then Idle and Archived closed.
    private func assertDefaultRoster(_ app: XCUIApplication) {
        let roster = app.descendants(matching: .any)["agent-roster-scroll"]
        XCTAssertTrue(roster.waitForExistence(timeout: 20), "the roster should load")
        for pane in ["w1:p1", "w1:p2", "studio/w1:p4", "w1:p3", "w2:p1"] {
            XCTAssertTrue(row(app, pane).waitForExistence(timeout: 10), "\(pane) should be listed")
        }
        XCTAssertTrue(app.buttons["Idle, 2"].exists, "Idle should be a closed row of two")
        XCTAssertEqual(app.buttons["Idle, 2"].value as? String, "collapsed")
        XCTAssertTrue(app.buttons["Archived, 1"].exists, "Archived should be a closed row of one")
        XCTAssertEqual(app.buttons["Archived, 1"].value as? String, "collapsed")
        XCTAssertFalse(row(app, "w2:p2").exists, "closed Idle should hide release")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists, "a loaded roster shows no spinner")
    }

    private func expand(_ app: XCUIApplication, _ label: String, showing rows: [XCUIElement]) {
        let toggle = app.buttons[label]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "\(label) should be listed")
        toggle.tap()
        // One more tap if the first never reached the row (seen once on the 11-inch, run
        // 40685403456): the row reports its state, so a second tap cannot close it again.
        if !rows[0].waitForExistence(timeout: 3), toggle.value as? String == "collapsed" { toggle.tap() }
        for row in rows {
            XCTAssertTrue(row.waitForExistence(timeout: 10), "opening \(label) should show its agents")
        }
        XCTAssertEqual(toggle.value as? String, "expanded")
    }

    // MARK: Capture

    /// Waits until three screenshots half a second apart are byte-identical, then keeps the
    /// last as `ref-<device>-<state>.png` with its conditions as `ref-<device>-<state>.json`.
    private func capture(_ app: XCUIApplication, device: String, state: String) {
        let name = "ref-\(device)-\(state)"
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        var identical = 0
        let deadline = Date().addingTimeInterval(30)
        var settled: XCUIScreenshot?
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let shot = XCUIScreen.main.screenshot()
            let png = shot.pngRepresentation
            identical = png == previous ? identical + 1 : 0
            previous = png
            if identical >= 2 {
                settled = shot
                break
            }
        }
        guard let settled else {
            attach(XCUIScreen.main.screenshot(), "\(name)-unsettled")
            XCTFail("\(name): the screen never held still for a second")
            return
        }
        // The screenshot's bitmap is the panel's native portrait; its image carries the
        // rotation. Drawn upright at the same scale (a quarter turn, no resampling), in sRGB.
        let image = settled.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(at: .zero)
        }
        let pixels = (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        XCTAssertTrue(pixels.0 > pixels.1, "\(name) should be landscape, not \(pixels.0)x\(pixels.1)")

        let shot = XCTAttachment(uniformTypeIdentifier: "public.png", name: "\(name).png",
                                 payload: upright, userInfo: nil)
        shot.lifetime = .keepAlways
        add(shot)

        var fields = conditions(app.otherElements["desktopref-probe"])
        fields["state"] = state
        fields["device"] = device
        fields["fixture"] = served.map { "desktop-reference-\($0.name).json" } ?? "\(Self.fixtureName).json"
        fields["fixtureSHA256"] = served?.sha256 ?? Self.fixtureSHA256
        fields["pixels"] = "\(pixels.0)x\(pixels.1)"
        let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let record = XCTAttachment(uniformTypeIdentifier: "public.json", name: "\(name).json",
                                   payload: json, userInfo: nil)
        record.lifetime = .keepAlways
        add(record)
    }
}
