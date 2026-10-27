import XCTest

/// TEMPORARY, REMOVE BEFORE MERGE: which part of the folders list hangs the app on its first
/// vertical scroll (#552). Each case scrolls the folders mock once with one thing changed and
/// checks the app still answers. A hung app fails its case after XCTest's ~60 s idle wait.
final class FoldersHangProbeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func scrollOnceAndAnswer(_ environment: [String: String], firstRow: String = "w1:p1") {
        let app = XCUIApplication.launched(mock: "folders", environment: environment)
        let first = app.descendants(matching: .any)["agent-row-\(firstRow)"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "the roster did not load")
        // Let the ping and the folders document land first.
        _ = app.descendants(matching: .any)["agent-folder-enyo"].waitForExistence(timeout: 5)
        let start = Date()
        app.scrollViews["agent-roster-scroll"].swipeUp()
        let late = app.descendants(matching: .any)["agent-row-w2:p11"]
        XCTAssertTrue(late.waitForExistence(timeout: 10), "a lower row is in the tree")
        let seconds = Date().timeIntervalSince(start)
        print("PROBE \(environment) answered after \(String(format: "%.1f", seconds)) s")
        XCTAssertLessThan(seconds, 30, "the app hung after one scroll")
    }

    func test1FoldersAsShipped() { scrollOnceAndAnswer([:]) }
    func test2NoCapability() { scrollOnceAndAnswer(["HERDR_MOCK_GROUPS": "off"]) }
    func test3NoSwipeActions() { scrollOnceAndAnswer(["HERDR_PROBE_NO_SWIPE": "1"]) }
    func test4NoIdleSection() { scrollOnceAndAnswer(["HERDR_PROBE_NO_IDLE": "1"]) }
    func test5EagerStack() { scrollOnceAndAnswer(["HERDR_PROBE_EAGER": "1"]) }
}
