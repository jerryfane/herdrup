import XCTest

/// The SWIPE-BETWEEN-AGENTS receipt (JARVIS-commissioned under standing rule 47814/47874:
/// a gesture change ships with an on-simulator gesture proof, not static review alone).
///
/// Launches the keep-mounted paging harness (`HERDR_SCREENSHOT_MOCK=paging`) — three
/// distinctively-named agents (ALFA / BRAVO / CHARLIE) in the real `PaneKeepAliveContainer`.
/// A horizontal swipe fronts the neighbour, and the header heading changes accordingly. Only
/// the FRONT pane is in the accessibility tree (`.accessibilityHidden(!isFront)`), so an
/// existence assertion genuinely proves which pane is on screen: after swiping to BRAVO the
/// ALFA header is GONE, and swiping back makes it reappear (a warm keep-mounted hit).
///
/// If the swipe never registered, the front pane would not change and the target header would
/// never appear → this fails. So a PASS proves the discrete swipe recognizers page the panes.
final class PagingTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testSwipeBetweenAgents() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "paging"
        app.launch()
        Thread.sleep(forTimeInterval: 2.0)   // let the first pane mount + its stream seed

        // Opens on ALFA (heading "ALFA · ALFA").
        XCTAssertTrue(frontHeader(app, contains: "ALFA"),
            "Paging harness did not open on the first agent (ALFA).")
        attach(app, "01-alfa")

        // Swipe LEFT → next agent (BRAVO). ALFA leaves the a11y tree; BRAVO enters.
        swipe(app, .left)
        XCTAssertTrue(frontHeader(app, contains: "BRAVO"),
            "Swipe-left did not page to the next agent (BRAVO).")
        XCTAssertFalse(frontHeader(app, contains: "ALFA", timeout: 1),
            "ALFA is still on screen after paging to BRAVO — the swap did not front BRAVO.")
        attach(app, "02-bravo")

        // Swipe RIGHT → previous agent (back to ALFA), a warm keep-mounted hit.
        swipe(app, .right)
        XCTAssertTrue(frontHeader(app, contains: "ALFA"),
            "Swipe-right did not page back to the previous agent (ALFA).")
        attach(app, "03-alfa-again")
    }

    // MARK: helpers

    /// The front pane's header heading rendered as a SwiftUI Text (staticText). Non-front panes
    /// are `.accessibilityHidden`, so a match means that pane is the one on screen.
    private func frontHeader(_ app: XCUIApplication, contains name: String, timeout: TimeInterval = 6) -> Bool {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", name)
        return app.staticTexts.containing(pred).firstMatch.waitForExistence(timeout: timeout)
    }

    private enum Dir { case left, right }

    /// A firm, FAST horizontal flick on the terminal body at mid-height. The discrete
    /// `UISwipeGestureRecognizer` fires only on real velocity — a plain drag is read as the
    /// scroll pan and never pages — so we drive the drag at `.fast` velocity explicitly. Both
    /// directions start well clear of the left screen edge (dx ≥ 0.45 ≫ the ~44pt edge-back
    /// zone), so the previous-agent (rightward) swipe is never ceded to the edge-back gesture.
    private func swipe(_ app: XCUIApplication, _ dir: Dir) {
        let startX: CGFloat = dir == .left ? 0.85 : 0.45
        let endX:   CGFloat = dir == .left ? 0.15 : 0.95
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
        start.press(forDuration: 0.0, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.0)
        Thread.sleep(forTimeInterval: 1.2)   // let the front swap + repaint
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
