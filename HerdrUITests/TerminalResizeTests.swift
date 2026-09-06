import XCTest
import UIKit

/// Shared-surface receipts. The probe is populated only by actual CoreText draws;
/// screenshots retain the independent visual evidence in each result bundle.
class TerminalInteractionTestCase: XCTestCase {
    var app: XCUIApplication!
    override func setUp() { super.setUp(); continueAfterFailure = false }
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        super.tearDown()
    }

    func launch(_ mode: String) {
        app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = mode
        app.launch()
        XCTAssertTrue(app.staticTexts["terminal-interaction-probe"].waitForExistence(timeout: 15))
        wait {
            ($0["opens"] as? Int) == 1 && ($0["requests"] as? Int ?? 0) > 0
                && ($0["covered"] as? Bool) == false && $0["top"] != nil
        }
    }

    func probe() -> [String: Any] {
        let label = app.staticTexts["terminal-interaction-probe"].label
        return (try? JSONSerialization.jsonObject(with: Data(label.utf8))) as? [String: Any] ?? [:]
    }

    @discardableResult
    func wait(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
              _ condition: @escaping ([String: Any]) -> Bool) -> [String: Any] {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return condition(self.probe())
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Last painted receipt: \(probe())", file: file, line: line)
        return probe()
    }

    /// A usable element, chosen and checked by GEOMETRY.
    ///
    /// `isHittable` is not usable here: on an element parked outside its scroll
    /// viewport it raises "Activation point invalid" instead of returning false, which
    /// failed eight cases outright. Two mounted panes also publish the same pane
    /// identifiers, so a bare query can match a hidden twin ("Multiple matching
    /// elements found"). Both are answered by taking the first match whose frame lies
    /// inside the APPLICATION frame — the screen. A window query can return a window
    /// that is not the main one, which would reject every element on the screen.
    func onscreen(_ identifier: String, timeout: TimeInterval = 10) -> XCUIElement? {
        // Identifier OR label: production keycaps carry only an accessibility label.
        let matches = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       identifier, identifier))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let visible = app.frame.insetBy(dx: -1, dy: -1)
            for index in 0..<matches.count {
                let candidate = matches.element(boundBy: index)
                let frame = candidate.frame
                if frame.width > 0, frame.height > 0, visible.contains(frame) { return candidate }
            }
        } while Date() < deadline
        return nil
    }

    /// Every button with its identifier, label and frame. Attached to a reachability
    /// failure so the next run explains itself instead of costing another CI round.
    func elementDump() -> String {
        let rows = app.buttons.allElementsBoundByIndex.map {
            "\($0.identifier.isEmpty ? "-" : $0.identifier)|\($0.label)|\($0.frame)"
        }
        return "app=\(app.frame) buttons=[" + rows.joined(separator: " ") + "]"
    }

    /// Fixture commands are plain buttons in the harness bar, so one laid-out tap is
    /// enough — no popover to present and nothing to scroll.
    func command(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let item = onscreen("fixture-" + name) else {
            XCTFail("Fixture command \(name) never became usable", file: file, line: line)
            return
        }
        item.tap()
    }

    /// Opens a real menu and taps one of its items. A menu item that has not been
    /// presented sits in the tree with an infinite frame, so this waits for actual
    /// geometry and re-opens once rather than tapping into nothing.
    func menuItem(_ menu: String, _ item: String,
                  file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 0..<2 {
            guard let control = onscreen(menu) else { continue }
            control.tap()
            if let entry = onscreen(item, timeout: 5) {
                entry.tap()
                return
            }
            if attempt == 0 {
                // Dismiss a popover that opened without usable items.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
            }
        }
        XCTFail("menu \(menu) never offered a usable \(item)", file: file, line: line)
    }

    func settled(cols: Int? = nil, rows: Int? = nil) {
        var stableSince: Date?
        wait {
            let matches = ($0["covered"] as? Bool) == false && ($0["complete"] as? Bool) == true
                && (cols == nil || ($0["cols"] as? Int) == cols)
                && (rows == nil || ($0["rows"] as? Int) == rows)
            guard matches else { stableSince = nil; return false }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) >= 0.4
        }
    }

    func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func anchor(file: StaticString = #filePath, line: UInt = #line) {
        let state = wait { ($0["markerRow"] as? Int) == 0 && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(state["markerText"] as? String, "ANCHOR020", file: file, line: line)
        XCTAssertGreaterThanOrEqual(state["markerColumn"] as? Int ?? -1, 0, file: file, line: line)
        XCTAssertEqual(state["tail"] as? Bool, false, file: file, line: line)
    }

    var terminal: XCUIElement { app.descendants(matching: .any)["terminal-surface"].firstMatch }
}

final class TerminalResizeTests: TerminalInteractionTestCase {
    // Three painted cycles here; the vendored core suite drives ten inside a long
    // wrapped line, where a cycle costs microseconds instead of two app launches'
    // worth of accessibility round trips.
    func testLogicalHistorySurvivesWidthCyclesAndHeightChange() {
        launch("resize")
        command("history"); anchor()
        let original = probe()["top"] as? String
        attach("history-before-80")
        for cycle in 0..<3 {
            command("120x24"); settled(cols: 120, rows: 24); anchor()
            command("80x24"); settled(cols: 80, rows: 24); anchor()
            XCTAssertEqual(probe()["top"] as? String, original, "Cycle \(cycle) drifted to another logical cell")
        }
        command("80x32"); settled(cols: 80, rows: 32); anchor()
        command("80x24"); settled(cols: 80, rows: 24); anchor()
        XCTAssertEqual(probe()["top"] as? String, original)
        XCTAssertEqual(probe()["opens"] as? Int, 1, "A resize must not replay/reset the stream")
        attach("history-after-cycles-and-height")
    }

    func testRealSidebarOrientationAndFontPreserveHistory() throws {
        launch("resize")
        guard probe()["iPad"] as? Bool == true else {
            throw XCTSkip("Actual sidebar/orientation receipt runs on the iPad destination; iPhone uses exact-grid sweeps")
        }
        XCTAssertNotNil(onscreen("terminal-sidebar-toggle", timeout: 5),
                        "The iPad receipt must exercise the actual sidebar")
        command("natural"); settled()
        command("history"); anchor()
        let opens = probe()["opens"] as? Int
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            onscreen("terminal-sidebar-toggle")?.tap()
            settled(); anchor(); attach("sidebar-\(orientation.rawValue)")
            XCUIDevice.shared.orientation = orientation
            settled(); anchor(); attach("orientation-\(orientation.rawValue)")
            onscreen("terminal-sidebar-toggle")?.tap()
            settled(); anchor()
        }
        menuItem("terminal-actions", "terminal-font-increase")
        settled(); anchor(); attach("larger-font-history")
        menuItem("terminal-actions", "terminal-font-decrease")
        settled(); anchor()
        XCTAssertEqual(probe()["opens"] as? Int, opens)
    }

    func testReturningToEarlierTargetStillUsesLatestQuietWindow() {
        launch("resize")
        command("history"); anchor()
        let before = probe()["requests"] as? Int ?? 0
        command("bounce")
        let until = Date().addingTimeInterval(0.6)
        repeat {
            XCTAssertEqual(probe()["markerRow"] as? Int, 0,
                           "The painted history marker moved during the geometry sweep")
        } while Date() < until
        settled(cols: 120); anchor()
        XCTAssertEqual(probe()["requests"] as? Int, before + 1)
        attach("bounce-coalesced-without-intermediate-reflow")
    }

    func testStationaryTargetAndSupersededInflightRequests() {
        launch("resize")
        let initial = probe()["requests"] as? Int ?? 0
        command("120x24"); settled(cols: 120)
        XCTAssertEqual(probe()["requests"] as? Int, initial + 1)
        command("delayed")
        command("80x24")
        wait { ($0["requests"] as? Int ?? 0) > initial + 1 }
        command("120x24")
        settled(cols: 120)
        wait { ($0["requests"] as? Int ?? 0) == initial + 3 }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("superseded-request-final-grid")
    }

    func testOrderedGeometryResponseAndWiderViewerDoNotReconnect() {
        launch("resize")
        command("history"); anchor()
        for scenario in ["beforeMarker", "afterResponse", "delayed", "wider"] {
            command(scenario)
            command("120x24")
            settled(cols: scenario == "wider" ? 140 : 120)
            anchor(); attach("ordered-\(scenario)")
            XCTAssertEqual(probe()["opens"] as? Int, 1)
            command("quiet")
            command("80x24"); settled(cols: 80); anchor()
        }
        command("server"); settled(cols: 120); anchor()
        attach("unsolicited-authoritative-resize")
    }

    func testSplitSynchronizedAlternateFrameStaysHidden() {
        launch("resize")
        command("history"); anchor()
        command("synchronized")
        command("120x24")
        // Sample the actual presentation across the fixture's split redraw, retaining
        // transition screenshots. A hidden incomplete backing draw may occur, but it
        // must never be published as live. Fixed sampling: a spin loop attached dozens
        // of full screenshots for one assertion.
        for index in 0..<6 {
            let state = probe()
            XCTAssertFalse((state["visible"] as? String ?? "").contains("INCOMPLETE"))
            attach("split-frame-\(index)")
            if index < 5 { Thread.sleep(forTimeInterval: 0.15) }
        }
        settled(cols: 120); anchor()
        XCTAssertEqual(probe()["alternate"] as? Bool, false)
        attach("normal-buffer-restored")
    }

    func testFailureAndNoRedrawReleaseCoverAtAuthoritativeGrid() {
        launch("resize")
        command("history"); anchor()
        command("failure"); command("120x24")
        wait { ($0["failures"] as? Int ?? 0) > 0 }
        settled(cols: 80); anchor()
        XCTAssertEqual(probe()["effectiveCols"] as? Int, 80)
        attach("failed-request-real-grid-no-frozen-cover")
        command("quiet"); command("80x32")
        settled(cols: 80, rows: 32); anchor()
        attach("no-output-height-resize-revealed")
    }

    func testLiveTailBusyOutputAndExplicitReturnToTail() {
        launch("resize")
        command("busy")
        wait { ($0["appended"] as? Int ?? 0) >= 3 }
        command("120x24"); settled(cols: 120)
        wait { ($0["tail"] as? Bool) == true && ($0["visible"] as? String ?? "").contains("APPENDED") }
        command("history"); anchor()
        command("80x24"); settled(cols: 80); anchor()
        command("tail")
        wait { ($0["tail"] as? Bool) == true && ($0["visible"] as? String ?? "").contains("fixture>") }
        command("quiet")
        let receipt = wait {
            ($0["appendedRecords"] as? [Int])?.last == ($0["appended"] as? Int)
        }
        let appended = receipt["appended"] as? Int ?? 0
        XCTAssertEqual(receipt["records"] as? [Int], Array(0..<100), "Seed records were lost or replayed")
        XCTAssertEqual(receipt["appendedRecords"] as? [Int], Array(1...max(1, appended)),
                       "Live records were duplicated, reordered or dropped")
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("busy-output-tail-restored")
    }

    func testMountedPaneSwitchResetAndCloseDuringResize() {
        launch("resize")
        wait { ($0["mounted"] as? Int) == 2 }
        command("history"); anchor()
        command("delayed"); command("120x24")
        command("switch")
        wait { ($0["pane"] as? String) == "ix:b" && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        settled(cols: 120); anchor()
        command("reset")
        wait { ($0["epoch"] as? Int) == 8 && ($0["covered"] as? Bool) == false }
        // Reset replaces the visible seed, not the reader's decision to follow.
        // Returning explicitly must expose the new epoch rather than an old cover.
        command("tail")
        wait { ($0["visible"] as? String ?? "").contains("RESET-EPOCH8") }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        command("80x24"); command("close")
        wait { ($0["mounted"] as? Int) == 1 && ($0["pane"] as? String) == "ix:b" && ($0["covered"] as? Bool) == false }
        XCTAssertEqual(probe()["opens"] as? Int, 1)
        attach("close-inflight-surviving-pane")
    }

    func testDraggingDuringCoveredResizeTakesControl() {
        launch("resize")
        command("history"); anchor()
        command("delayed"); command("120x24")
        // Three drags with a beat between them, the gesture ScrollTests already proves
        // moves this terminal; one flick can land inside the scroll view's slop.
        for _ in 0..<3 {
            let from = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35))
            let to = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.75))
            from.press(forDuration: 0.05, thenDragTo: to)
            Thread.sleep(forTimeInterval: 0.2)
        }
        wait { ($0["covered"] as? Bool) == false && ($0["markerRow"] as? Int) != 0 }
        settled(cols: 120)
        XCTAssertNotEqual(probe()["markerRow"] as? Int, 0, "Late reveal restored the stale history anchor")
        attach("gesture-cancels-covered-resize")
    }
}
