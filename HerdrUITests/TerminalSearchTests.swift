import XCTest

/// Search receipts against the REAL pane surface.
///
/// The `resize` fixture seeds a hundred numbered ~90-cell records, so a search for a
/// known record has exactly one match at a known place in history — which is what makes
/// "did it actually find and reveal it" checkable rather than "did a field accept text".
final class TerminalSearchTests: TerminalInteractionTestCase {
    /// The `resize` fixture mounts TWO panes (`livePaneIDs: ["ix:a", "ix:b"]`) and
    /// PaneKeepAliveContainer keeps the offscreen one alive, so a bare identifier query
    /// matches more than one header. The VISIBLE pane is the hittable one — tree order is
    /// not a contract, hittability is.
    private func headerButton(_ id: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: id)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "no \(id) in the header")
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    private func findField() -> XCUIElement {
        let fields = app.textFields.matching(identifier: "terminal-find-field")
        return fields.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? fields.firstMatch
    }

    private func findCount() -> XCUIElement {
        let labels = app.staticTexts.matching(identifier: "terminal-find-count")
        return labels.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? labels.firstMatch
    }

    /// Two identical reads a beat apart: the fixture paints for a while after launch, so a
    /// single sample is not evidence that the viewport is still.
    private func settledTop() -> String? {
        var last = probe()["top"] as? String
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = probe()["top"] as? String
            if now == last { return now }
            last = now
        }
        return last
    }

    private func waitForLabelChange(_ element: XCUIElement, from: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label != from { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func openFind() {
        headerButton("terminal-find").tap()
        XCTAssertTrue(findField().waitForExistence(timeout: 5),
                      "tapping the magnifier must reveal the field")
    }

    /// Which half is broken, if either. `engineMatches` asks SwiftTerm directly on the
    /// live fixture buffer; the counter is what the app's wiring produced. Running both in
    /// one test means a failure names the culprit instead of just failing.
    func testEngineAndWiringAgree() {
        launch("resize")
        wait { ($0["engineMatches"] as? Int ?? 0) > 0 }
        let engine = probe()["engineMatches"] as? Int ?? 0

        openFind()
        findField().typeText("RECORD")
        let count = findCount()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.label, "none",
                          "SwiftTerm reports \(engine) matches for RECORD, so an empty counter is the app's wiring")
    }

    /// The core contract: a term that exists is found, counted, and REVEALED — the match
    /// has to be on screen afterwards, not merely counted. `top` is the fixture's actual
    /// painted top row, so it can only be right if the view really scrolled.
    func testFindRevealsAMatchInHistory() {
        launch("resize")
        openFind()
        // ANCHOR020 is the fixture's UNIQUE marker (TerminalInteractionHarness.swift:197):
        // one match, at a known point in history, so "did it reveal it" is checkable.
        findField().typeText("ANCHOR020")

        let count = findCount()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.label, "none", "the seeded anchor must be findable")

        // REVEALED, not scrolled-to-top: SwiftTerm's scrollToReveal brings the match into
        // the viewport and leaves it wherever it lands. `markerRow` is the fixture's own
        // measurement of ANCHOR020 relative to the visible top, so a value inside the
        // viewport is the honest assertion; requiring row 0 asserted an intent the API
        // never had (the previous run reported markerRow 12 — visible, and failing).
        wait { probe in
            guard let row = probe["markerRow"] as? Int, let rows = probe["rows"] as? Int else { return false }
            return row >= 0 && row < rows
        }
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    /// A term that is not in the buffer must say so rather than silently doing nothing,
    /// and must not move the reader.
    func testMissingTermReportsNoneAndDoesNotScroll() {
        launch("resize")
        openFind()
        // Captured once the viewport has actually STOPPED moving. The fixture keeps
        // painting for a while after launch, and a single read taken mid-seed made normal
        // painting look like the search had scrolled.
        let before = settledTop()

        findField().typeText("zzz-not-in-this-buffer")
        let count = findCount()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "none")
        XCTAssertEqual(settledTop(), before,
                       "a failed search must leave the viewport where it was")
    }

    /// Closing search drops the highlight but KEEPS the reader where the search took them.
    /// Jumping back to the tail here would undo the entire point of having searched.
    func testClosingSearchKeepsThePosition() {
        launch("resize")
        openFind()
        findField().typeText("ANCHOR020")
        wait { probe in
            guard let row = probe["markerRow"] as? Int, let rows = probe["rows"] as? Int else { return false }
            return row >= 0 && row < rows
        }
        let atMatch = probe()["top"] as? String

        headerButton("terminal-find").tap()   // close
        XCTAssertFalse(findField().isHittable)
        XCTAssertEqual(probe()["top"] as? String, atMatch,
                       "closing the find bar must not jump back to the newest output")
    }

    /// Stepping with the chevrons moves between matches. The fixture's records share the
    /// word "record", so next/previous have somewhere to go.
    func testNextAndPreviousStepBetweenMatches() {
        launch("resize")
        openFind()
        // RECORD matches every seeded line, so next/previous have somewhere to go.
        findField().typeText("RECORD")

        let count = findCount()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.label, "none")

        // Stepping moves the CURRENT match, which the counter reports as "i/N". Asserting
        // on the counter rather than the top row keeps this about the interaction and not
        // about how far a particular match happened to be from the viewport edge.
        let first = count.label
        headerButton("terminal-find-next").tap()
        XCTAssertTrue(waitForLabelChange(count, from: first), "next must move to another match")

        let second = count.label
        headerButton("terminal-find-previous").tap()
        XCTAssertTrue(waitForLabelChange(count, from: second), "previous must move back")
    }

    /// The refresh button keeps working with the magnifier beside it — a plain guard that
    /// the header edit did not break the control it was added next to.
    func testRefreshStillReconnects() {
        launch("resize")
        headerButton("terminal-refresh").tap()
        wait { ($0["opens"] as? Int ?? 0) >= 2 }
    }
}
