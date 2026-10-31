import XCTest
import UIKit

/// One running home tree crosses the cover/inner layout boundary; no app relaunch.
final class DuoTransitionTests: TerminalInteractionTestCase {
    private func start() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Needs room for the regular layout and a 390-point compact viewport")
        }
        launch("resize", environment: ["HERDR_LAYOUT_TRANSITIONS": "1", "HERDR_TRACE_SEARCH": "1"])
    }

    private func transition(_ layout: String) {
        app.buttons["fixture-layout-\(layout)"].tap()
        XCTAssertTrue(poll(5, every: 0.1) {
            self.app.staticTexts["fixture-layout-state"].label == layout
        })
    }

    private func editor(_ identifier: String) throws -> XCUIElement {
        let candidates = app.textViews.matching(identifier: identifier)
        XCTAssertTrue(poll(10, every: 0.1) {
            candidates.allElementsBoundByIndex.contains { $0.isHittable }
        })
        return try XCTUnwrap(candidates.allElementsBoundByIndex.first { $0.isHittable })
    }

    func testTerminalDraftAndStreamSurviveCompactRegularTransitions() throws {
        try start()
        let draft = "Keep this unsent terminal reply"
        let input = try editor("terminal-reply-input")
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        let originalOpens = try XCTUnwrap(probe()["opens"] as? Int)
        XCTAssertEqual(originalOpens, 1)
        attach("terminal-before-layout-transition")

        for layout in ["compact", "regular", "compact", "regular"] {
            transition(layout)
            let retained = try editor("terminal-reply-input")
            XCTAssertEqual(retained.value as? String, draft, "Draft lost entering \(layout)")
            wait { ($0["covered"] as? Bool) == false && ($0["top"] as? String) != nil }
            XCTAssertEqual(probe()["opens"] as? Int, originalOpens,
                           "The selected pane must not remount or reopen its stream")
            attach("terminal-\(layout)")
        }
    }

    func testGramDraftSurvivesCompactRegularTransitions() throws {
        try start()
        let gram = try XCTUnwrap(onscreen("Gram", requiringHittable: true))
        gram.tap()
        let draft = "Keep this unsent Gram reply"
        let input = try editor("gram-composer-input")
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        attach("gram-before-layout-transition")

        for layout in ["compact", "regular", "compact", "regular"] {
            transition(layout)
            XCTAssertEqual(try editor("gram-composer-input").value as? String, draft,
                           "Gram draft lost entering \(layout)")
            attach("gram-\(layout)")
        }
    }

    func testGramSearchRemainsEditableAcrossCompactRegularTransitions() throws {
        try start()
        try XCTUnwrap(onscreen("Gram", requiringHittable: true)).tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 10))

        let sidebarField = app.textFields["gram-search-field"]
        XCTAssertTrue(sidebarField.waitForExistence(timeout: 5))
        sidebarField.tap()
        sidebarField.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["clientloop"].waitForNonExistence(timeout: 5))

        transition("compact")
        let compactField = app.textFields.matching(identifier: "gram-search-field")
        XCTAssertTrue(poll(5, every: 0.1) {
            compactField.allElementsBoundByIndex.contains { $0.isHittable }
        })
        let retained = try XCTUnwrap(compactField.allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertEqual(retained.value as? String, "zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].exists)
        attach("gram-search-compact")

        let toggle = app.buttons["gram-search"]
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5))
        XCTAssertFalse(compactField.allElementsBoundByIndex.contains { $0.isHittable })

        toggle.tap()
        if !compactField.allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            app.buttons["fixture-search-inspect"].tap()
            let diagnostic = XCTAttachment(string: app.staticTexts["fixture-search-trace"].label
                + "\n" + app.debugDescription)
            diagnostic.name = "search-reopen-native-trace"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            XCTFail("Reopened search field was not hittable before diagnostics")
        }
        let reopened = try XCTUnwrap(compactField.allElementsBoundByIndex.first { $0.isHittable })
        reopened.tap()
        reopened.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        transition("regular")
        XCTAssertEqual(sidebarField.value as? String, "zzzz")
        XCTAssertTrue(sidebarField.isHittable)
        app.buttons["Clear search"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["clientloop"].waitForExistence(timeout: 5))
        attach("gram-search-regular")
    }
}
