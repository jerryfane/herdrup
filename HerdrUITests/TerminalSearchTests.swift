import XCTest

/// Search receipts against the REAL pane surface.
///
/// The `resize` fixture seeds a hundred numbered ~90-cell records, so a search for a
/// known record has exactly one match at a known place in history — which is what makes
/// "did it actually find and reveal it" checkable rather than "did a field accept text".
final class TerminalSearchTests: TerminalInteractionTestCase {
    private func openFind() {
        let find = app.buttons["terminal-find"]
        XCTAssertTrue(find.waitForExistence(timeout: 10), "the header must offer search")
        find.tap()
        XCTAssertTrue(app.textFields["terminal-find-field"].waitForExistence(timeout: 5),
                      "tapping the magnifier must reveal the field")
    }

    /// The core contract: a term that exists is found, counted, and REVEALED — the match
    /// has to be on screen afterwards, not merely counted. `top` is the fixture's actual
    /// painted top row, so it can only be right if the view really scrolled.
    func testFindRevealsAMatchInHistory() {
        launch("resize")
        openFind()
        app.textFields["terminal-find-field"].typeText("record 20")

        let count = app.staticTexts["terminal-find-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.label, "none", "a seeded record must be findable")

        wait { probe in
            guard let top = probe["top"] as? String else { return false }
            return top.contains("record 2")
        }
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    /// A term that is not in the buffer must say so rather than silently doing nothing,
    /// and must not move the reader.
    func testMissingTermReportsNoneAndDoesNotScroll() {
        launch("resize")
        let before = probe()["top"] as? String
        openFind()
        app.textFields["terminal-find-field"].typeText("zzz-not-in-this-buffer")

        let count = app.staticTexts["terminal-find-count"]
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
        app.textFields["terminal-find-field"].typeText("record 20")
        wait { ($0["top"] as? String)?.contains("record 2") == true }
        let atMatch = probe()["top"] as? String

        app.buttons["terminal-find"].tap()   // close
        XCTAssertFalse(app.textFields["terminal-find-field"].exists)
        XCTAssertEqual(probe()["top"] as? String, atMatch,
                       "closing the find bar must not jump back to the newest output")
    }

    /// Stepping with the chevrons moves between matches. The fixture's records share the
    /// word "record", so next/previous have somewhere to go.
    func testNextAndPreviousStepBetweenMatches() {
        launch("resize")
        openFind()
        app.textFields["terminal-find-field"].typeText("record")

        let count = app.staticTexts["terminal-find-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertNotEqual(count.label, "none")

        let first = probe()["top"] as? String
        app.buttons["terminal-find-next"].tap()
        wait { ($0["top"] as? String) != first }

        let second = probe()["top"] as? String
        app.buttons["terminal-find-previous"].tap()
        wait { ($0["top"] as? String) != second }
    }

    /// The refresh button keeps working with the magnifier beside it — a plain guard that
    /// the header edit did not break the control it was added next to.
    func testRefreshStillReconnects() {
        launch("resize")
        let refresh = app.buttons["terminal-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        refresh.tap()
        wait { ($0["opens"] as? Int ?? 0) >= 2 }
    }
}
