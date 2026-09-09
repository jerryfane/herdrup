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

    private func openFind() {
        headerButton("terminal-find").tap()
        XCTAssertTrue(findField().waitForExistence(timeout: 5),
                      "tapping the magnifier must reveal the field")
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

        wait { probe in
            (probe["top"] as? String)?.contains("ANCHOR020") == true
        }
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    /// A term that is not in the buffer must say so rather than silently doing nothing,
    /// and must not move the reader.
    func testMissingTermReportsNoneAndDoesNotScroll() {
        launch("resize")
        openFind()
        // Captured AFTER the fixture has settled, not at launch: the seed is still
        // painting for a moment, and a viewport that moved on its own would look like
        // the search moved it.
        let before = probe()["top"] as? String

        findField().typeText("zzz-not-in-this-buffer")
        let count = findCount()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "none")
        XCTAssertEqual(probe()["top"] as? String, before,
                       "a failed search must leave the viewport where it was")
    }

    /// Closing search drops the highlight but KEEPS the reader where the search took them.
    /// Jumping back to the tail here would undo the entire point of having searched.
    func testClosingSearchKeepsThePosition() {
        launch("resize")
        openFind()
        findField().typeText("ANCHOR020")
        wait { ($0["top"] as? String)?.contains("ANCHOR020") == true }
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

        let first = probe()["top"] as? String
        headerButton("terminal-find-next").tap()
        wait { ($0["top"] as? String) != first }

        let second = probe()["top"] as? String
        headerButton("terminal-find-previous").tap()
        wait { ($0["top"] as? String) != second }
    }

    /// The refresh button keeps working with the magnifier beside it — a plain guard that
    /// the header edit did not break the control it was added next to.
    func testRefreshStillReconnects() {
        launch("resize")
        headerButton("terminal-refresh").tap()
        wait { ($0["opens"] as? Int ?? 0) >= 2 }
    }
}
