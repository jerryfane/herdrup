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

    func command(_ name: String) {
        app.buttons["terminal-fixture-menu"].tap()
        let item = app.buttons["fixture-" + name]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing fixture command \(name)")
        item.tap()
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
    func testLogicalHistorySurvivesTenWidthCyclesAndHeightChange() {
        launch("resize")
        command("history"); anchor()
        let original = probe()["top"] as? String
        attach("history-before-80")
        for cycle in 0..<10 {
            command("120x24"); settled(cols: 120, rows: 24); anchor()
            command("80x24"); settled(cols: 80, rows: 24); anchor()
            XCTAssertEqual(probe()["top"] as? String, original, "Cycle \(cycle) drifted to another logical cell")
        }
        command("80x32"); settled(cols: 80, rows: 32); anchor()
        command("80x24"); settled(cols: 80, rows: 24); anchor()
        XCTAssertEqual(probe()["top"] as? String, original)
        XCTAssertEqual(probe()["opens"] as? Int, 1, "A resize must not replay/reset the stream")
        attach("history-after-ten-cycles-and-height")
    }

    func testRealSidebarOrientationAndFontPreserveHistory() throws {
        launch("resize")
        guard probe()["iPad"] as? Bool == true else {
            throw XCTSkip("Actual sidebar/orientation receipt runs on the iPad destination; iPhone uses exact-grid sweeps")
        }
        XCTAssertTrue(app.buttons["terminal-sidebar-toggle"].firstMatch.exists,
                      "The iPad receipt must exercise the actual sidebar")
        command("natural"); settled()
        command("history"); anchor()
        let opens = probe()["opens"] as? Int
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            app.buttons["terminal-sidebar-toggle"].firstMatch.tap()
            settled(); anchor(); attach("sidebar-\(orientation.rawValue)")
            XCUIDevice.shared.orientation = orientation
            settled(); anchor(); attach("orientation-\(orientation.rawValue)")
            app.buttons["terminal-sidebar-toggle"].firstMatch.tap()
            settled(); anchor()
        }
        app.buttons["terminal-actions"].tap()
        app.buttons["terminal-font-increase"].tap()
        settled(); anchor(); attach("larger-font-history")
        app.buttons["terminal-actions"].tap()
        app.buttons["terminal-font-decrease"].tap()
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
        // Poll the actual presentation, retaining transition screenshots. A hidden
        // incomplete backing draw may occur, but it must never be published as live.
        let until = Date().addingTimeInterval(1.2)
        var index = 0
        repeat {
            let state = probe()
            XCTAssertFalse((state["visible"] as? String ?? "").contains("INCOMPLETE"))
            attach("split-frame-\(index)")
            index += 1
        } while Date() < until
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
        let from = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35))
        let to = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: to)
        wait { ($0["covered"] as? Bool) == false && ($0["markerRow"] as? Int) != 0 }
        settled(cols: 120)
        XCTAssertNotEqual(probe()["markerRow"] as? Int, 0, "Late reveal restored the stale history anchor")
        attach("gesture-cancels-covered-resize")
    }
}
