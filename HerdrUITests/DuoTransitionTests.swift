import XCTest
import UIKit

/// One running home tree crosses the cover/inner layout boundary; no app relaunch.
final class DuoTransitionTests: TerminalInteractionTestCase {
    private func start() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Needs room for the regular layout and a 390-point compact viewport")
        }
        launch("resize", environment: ["HERDR_LAYOUT_TRANSITIONS": "1"])
    }

    private func transition(_ layout: String) {
        app.buttons["fixture-layout-\(layout)"].tap()
        XCTAssertTrue(poll(5, every: 0.1) {
            self.app.staticTexts["fixture-layout-state"].label == layout
        })
    }

    private func editor(_ identifier: String) throws -> XCUIElement {
        let candidates = app.textViews.matching(identifier: identifier)
        let hittable = poll(10, every: 0.1) {
            candidates.allElementsBoundByIndex.contains { $0.isHittable }
        }
        if !hittable {
            app.buttons["fixture-inspect-editors"].tap()
            let native = app.staticTexts["fixture-layout-state"].value as? String ?? "missing"
            let receipt = XCTAttachment(string: native + "\n\n" + app.debugDescription)
            receipt.name = "composer-hit-test-diagnostics"
            receipt.lifetime = .keepAlways
            add(receipt)
            attach("composer-not-hittable")
        }
        XCTAssertTrue(hittable)
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
}
