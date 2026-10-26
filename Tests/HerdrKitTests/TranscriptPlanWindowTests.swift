import XCTest
@testable import HerdrKit

final class TranscriptPlanWindowTests: XCTestCase {
    private func plan(_ statuses: [TranscriptTaskStatus]) -> [TranscriptPlanItem] {
        statuses.enumerated().map { TranscriptPlanItem(text: "Item \($0.offset)", done: $0.element == .completed, status: $0.element) }
    }

    func testInProgressInTheMiddleShowsItAndTheNextTwo() {
        let items = plan([.completed, .completed, .inProgress, .pending, .pending, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [2, 3, 4])
    }

    func testNearTheEndBackFillsWithTheNearestDoneItems() {
        let items = plan([.completed, .completed, .completed, .inProgress, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [2, 3, 4])
        let last = plan([.completed, .completed, .completed, .inProgress])
        XCTAssertEqual(TranscriptPlanWindow.visible(last), [1, 2, 3])
    }

    func testWithoutAnInProgressItemStartsAtTheFirstNotDone() {
        let items = plan([.completed, .pending, .blocked, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [1, 2, 3])
        let unknown = [TranscriptPlanItem(text: "A", done: true), TranscriptPlanItem(text: "B", done: false),
                       TranscriptPlanItem(text: "C", done: true)]
        XCTAssertEqual(TranscriptPlanWindow.visible(unknown), [0, 1])
    }

    func testInProgressWinsOverAnEarlierPendingItem() {
        let items = plan([.pending, .completed, .inProgress, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [1, 2, 3])
    }

    func testForwardFillSkipsDoneItemsAfterTheStart() {
        let items = plan([.inProgress, .completed, .pending, .pending, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [0, 2, 3])
    }

    func testShortPlanShowsEverything() {
        let items = plan([.inProgress, .blocked])
        XCTAssertEqual(TranscriptPlanWindow.visible(items), [0, 1])
    }

    func testAllDoneOrEmptyShowsNoRows() {
        XCTAssertEqual(TranscriptPlanWindow.visible(plan([.completed, .completed, .completed, .completed])), [])
        XCTAssertEqual(TranscriptPlanWindow.visible([]), [])
    }

    func testLimitBoundsTheWindow() {
        let items = plan([.completed, .inProgress, .pending, .pending])
        XCTAssertEqual(TranscriptPlanWindow.visible(items, limit: 1), [1])
        XCTAssertEqual(TranscriptPlanWindow.visible(items, limit: 4), [0, 1, 2, 3])
        XCTAssertEqual(TranscriptPlanWindow.visible(items, limit: 0), [])
    }
}
