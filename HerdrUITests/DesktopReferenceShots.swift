import CryptoKit
import XCTest

/// Herdrup Desktop's pixel-parity references (herdrup-desktop#16): the Agents home on iPad,
/// landscape, over the desktop's fake herdr `agent.list`, in every state the list can show.
/// Each state is one attachment, `ref-<device>-<state>.png`, with its conditions beside it
/// in `ref-<device>-<state>.json`. design/reference/agent-list/README.md says how they
/// become the committed references.
///
/// CI pins the status bar (`simctl status_bar override`) before this class runs; the app
/// (`HERDR_SCREENSHOT_MOCK=desktopref`) holds every animation still and pins its clock.
final class DesktopReferenceShots: XCTestCase {
    /// jerryfane/herdrup-desktop cmd/fakeherdr/agents.json at 0b5111ed47fb2325f6caf4a383758209c6d6c9f6.
    static let fixtureName = "desktop-reference-agents"
    static let fixtureSHA256 = "f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2"
    static let clock = "2026-10-28T09:41:00Z"
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

    // MARK: Launch

    /// Launches the mock in landscape at the default text size and returns the app and
    /// the device name for the attachments. Fails unless the app runs full screen on one
    /// of the reference iPads at @2x, dark, with the clock pinned.
    private func launch(_ state: String) throws -> (XCUIApplication, String) {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("the desktop references are iPad screenshots")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = [
            "HERDR_SCREENSHOT_MOCK": "desktopref",
            "HERDR_DESKTOPREF_STATE": state,
            "HERDR_DESKTOPREF_AGENT_LIST": try fixture(),
            "HERDR_MOCK_NOW": Self.clock,
        ]
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
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: Self.fixtureName, withExtension: "json"),
                                "the vendored agent.list fixture should be in the test bundle")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.fixtureSHA256, "the vendored fixture is not the one the references name")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
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
        app.descendants(matching: .any)["agent-row-\(paneID)"]
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
        fields["fixtureSHA256"] = Self.fixtureSHA256
        fields["pixels"] = "\(pixels.0)x\(pixels.1)"
        let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let record = XCTAttachment(uniformTypeIdentifier: "public.json", name: "\(name).json",
                                   payload: json, userInfo: nil)
        record.lifetime = .keepAlways
        add(record)
    }
}
