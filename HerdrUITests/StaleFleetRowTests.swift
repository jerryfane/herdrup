import XCTest

/// THE RENDER RECEIPT for the degraded-peer staleness marker.
///
/// The unit tests pin the RULE (`AgentRow.showsUnconfirmedMarker`) but cannot see the
/// view, so a review mutant that disabled the card's condition entirely
/// (`if false && row.showsUnconfirmedMarker`) compiled and survived all 415 runnable
/// HerdrKit tests. That is the gap this file closes: it asserts the marker is actually
/// on screen, so the same mutant fails here instead of shipping green.
///
/// The `list` mock roster carries a federated `mcb-air/mcb-air` row whose live status the
/// daemon blanked to "unknown" after a missed poll, with the real state moved to
/// `last_known_status: "blocked"` and `reachability: "degraded"`. That row escalates into
/// NEEDS YOU on a last-known value, so it is exactly the row that must not read as a
/// confirmed one.
final class StaleFleetRowTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testDegradedFederatedRowRendersAStalenessMarker() {
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        app.launch()

        // Premise first: the roster actually rendered and the federated row is present.
        // Without this a missing marker could not be told apart from a missing screen.
        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].waitForExistence(timeout: 12),
                      "the degraded federated fixture row should be on the roster")

        // The marker itself. `staticTexts` rather than a label lookup, because the chip is
        // the thing a person sees; asserting the accessibility label alone would pass on a
        // view that renders nothing visible.
        XCTAssertTrue(app.staticTexts["stale"].waitForExistence(timeout: 4),
                      "a needs-you row resting on a last-known status must be marked stale")

        // And the marker is SCOPED: the two locally blocked rows are live, so exactly one
        // stale chip exists. A mutant that marked every row would pass the assertion above.
        XCTAssertEqual(app.staticTexts.matching(identifier: "stale").count, 1,
                       "only the unconfirmed row should carry the marker")

        // The row keeps its needs-you signal rather than being hidden or downgraded: the
        // whole point is to surface it AND qualify it.
        XCTAssertTrue(app.staticTexts["NEEDS YOU · 3"].exists
                        || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'NEEDS YOU'")).count > 0,
                      "the escalated row should still be counted in the needs-you section")
    }
}
