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

        // Opens on ALFA (heading collapses to "ALFA" — name==kind==folder) — front, hittable.
        XCTAssertTrue(frontIs(app, "ALFA"),
            "Paging harness did not open on the first agent (ALFA).")
        attach(app, "01-alfa")

        // Swipe LEFT → next agent (BRAVO) becomes the FRONT (hittable) pane. The discrete swipe
        // recognizer is velocity-sensitive, so retry the flick until it lands (a swipe that never
        // fires leaves ALFA fronted; a swipe that pages makes BRAVO the hittable front). Retrying
        // can only ADVANCE when it actually fires, and stops the instant BRAVO is front, so it
        // cannot overshoot.
        XCTAssertTrue(pageUntilFront(app, .left, to: "BRAVO"),
            "Swipe-left did not page to the next agent (BRAVO).")
        XCTAssertFalse(frontIs(app, "ALFA", timeout: 1),
            "ALFA is still the front pane after paging to BRAVO — the swap did not front BRAVO.")
        attach(app, "02-bravo")

        // Swipe RIGHT → previous agent (back to ALFA), a warm keep-mounted hit that re-fronts it.
        XCTAssertTrue(pageUntilFront(app, .right, to: "ALFA"),
            "Swipe-right did not page back to the previous agent (ALFA).")
        attach(app, "03-alfa-again")
    }

    /// Flick in `dir` until the named agent is the hittable front pane, or give up after a few
    /// tries. Each attempt only pages when the discrete recognizer actually fires, and returns as
    /// soon as `to` is front — so it recovers a dropped flick without overshooting past the target.
    private func pageUntilFront(_ app: XCUIApplication, _ dir: Dir, to name: String) -> Bool {
        // A generous per-attempt wait (the neighbour's header renders within ~1s of a fired
        // flick), so a retry fires only when the flick genuinely dropped — never overshooting a
        // target that just hadn't rendered yet.
        for _ in 0..<3 {
            swipe(app, dir)
            if frontIs(app, name, timeout: 4) { return true }
        }
        return false
    }

    // MARK: helpers

    /// True when the named agent's header heading belongs to the FRONT pane — present AND
    /// HITTABLE. A backgrounded keep-mounted pane sits at opacity 0 with hit-testing off, so its
    /// header is not hittable; only the fronted pane's header is. This distinguishes "on screen"
    /// from "merely still mounted", without relying on accessibility hiding.
    private func frontIs(_ app: XCUIApplication, _ name: String, timeout: TimeInterval = 6) -> Bool {
        let el = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if el.exists && el.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return el.exists && el.isHittable
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
