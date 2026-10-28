import XCTest
@testable import Herdr

/// Gram's bubble width cap (`GramCardMetrics.bubbleCap`): on iPad/Mac an agent's bubble takes
/// up to 80 % of the width its row offers and yours 66 %, never under 520; a phone keeps 295.
final class GramBubbleCapTests: XCTestCase {
    func testAWideColumnGrowsTheBubbles() {
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 1200, incoming: true, regular: true), 960, accuracy: 0.001)
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 1200, incoming: false, regular: true), 792, accuracy: 0.001)
    }

    func testANarrowColumnKeepsTheFloor() {
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 600, incoming: true, regular: true), 520)
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 600, incoming: false, regular: true), 520)
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: .infinity, incoming: true, regular: true), 520,
                       "an unbounded offer gets the floor")
    }

    func testThePhoneKeepsItsFixedCap() {
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 1200, incoming: true, regular: false), 295)
        XCTAssertEqual(GramCardMetrics.bubbleCap(column: 390, incoming: false, regular: false), 295)
    }
}
