import XCTest
@testable import HerdrKit

final class ChatColumnWidthTests: XCTestCase {
    private typealias W = ChatColumnWidth

    func testDefaultsAndStorageKey() {
        XCTAssertEqual(W.storageKey, "chat.columnWidth")
        XCTAssertEqual(W.defaultWidth, 1000)
        XCTAssertEqual(W.minimum, 560)
        XCTAssertEqual(W.readable, 720)
        XCTAssertEqual(W.wide, 1000)
        XCTAssertEqual(W.snapDistance, 12)
    }

    func testDisplayedIsTheStoredWidthUpToTheAvailableWidth() {
        XCTAssertEqual(W.displayed(stored: 820, available: 1200), 820)
        XCTAssertEqual(W.displayed(stored: 1000, available: 900), 900, "a narrower window shows Full")
        XCTAssertEqual(W.displayed(stored: W.full, available: 1366), 1366, "Full is the whole width")
        XCTAssertEqual(W.displayed(stored: 300, available: 1200), 560, "a stored width is held to the minimum")
        XCTAssertEqual(W.displayed(stored: .nan, available: 1200), 1000, "an unusable value shows the default")
        XCTAssertEqual(W.displayed(stored: -5, available: 1200), 1000)
        XCTAssertEqual(W.displayed(stored: 820, available: 400), 400, "a chat narrower than the minimum is shown whole")
    }

    func testClampHoldsTheWidthBetweenMinimumAndAvailable() {
        XCTAssertEqual(W.clamped(400, available: 1200), 560)
        XCTAssertEqual(W.clamped(1500, available: 1200), 1200)
        XCTAssertEqual(W.clamped(800, available: 1200), 800)
        XCTAssertEqual(W.clamped(800, available: 500), 500)
    }

    func testSnapsWithinTwelvePointsOfReadableWideAndFull() {
        XCTAssertEqual(W.snapped(709, available: 1400), 720)
        XCTAssertEqual(W.snapped(733, available: 1400), 733, "outside the 12 pt zone")
        XCTAssertEqual(W.snapped(707, available: 1400), 707)
        XCTAssertEqual(W.snapped(1012, available: 1400), 1000)
        XCTAssertEqual(W.snapped(1390, available: 1400), 1400, "Full")
        XCTAssertEqual(W.snapped(1100, available: 1400), 1100)
        XCTAssertEqual(W.snapped(1006, available: 1010), 1010, "the nearer of Wide and Full wins")
        XCTAssertEqual(W.snapped(1003, available: 1010), 1000)
        XCTAssertEqual(W.snapPoints(available: 900).map(\.snap), [.readable, .full], "Wide does not fit")
    }

    func testDraggingAnEdgeResizesSymmetrically() {
        XCTAssertEqual(W.dragged(from: 1000, translation: -50, edge: .trailing, available: 1400), 900,
                       "the right edge inwards narrows by twice the drag")
        XCTAssertEqual(W.dragged(from: 1000, translation: 50, edge: .leading, available: 1400), 900,
                       "the left edge inwards narrows by twice the drag")
        XCTAssertEqual(W.dragged(from: 800, translation: 30, edge: .trailing, available: 1400), 860)
        XCTAssertEqual(W.dragged(from: 800, translation: -30, edge: .leading, available: 1400), 860)
        XCTAssertEqual(W.dragged(from: 800, translation: -600, edge: .trailing, available: 1400), 560, "minimum")
        XCTAssertEqual(W.dragged(from: 800, translation: 600, edge: .trailing, available: 1400), 1400, "Full")
        XCTAssertEqual(W.dragged(from: 1000, translation: -143, edge: .trailing, available: 1400), 720,
                       "714 snaps to Readable")
        XCTAssertEqual(W.dragged(from: 1000, translation: -100.3, edge: .trailing, available: 1400), 799,
                       "whole points")
    }

    func testStoredValueForAChosenWidth() {
        XCTAssertEqual(W.stored(for: 720, available: 1400), 720)
        XCTAssertEqual(W.stored(for: 1000, available: 1400), 1000)
        XCTAssertEqual(W.stored(for: 1400, available: 1400), W.full, "Full follows a wider window")
        XCTAssertEqual(W.stored(for: 860, available: 1400), 860)
        XCTAssertEqual(W.stored(for: 1000, available: 1000), 1000, "Wide when Wide is also the whole width")
    }

    func testResetIsWideOrFullWhenNarrower() {
        XCTAssertEqual(W.resetWidth, 1000)
        XCTAssertEqual(W.displayed(stored: W.resetWidth, available: 1400), 1000)
        XCTAssertEqual(W.displayed(stored: W.resetWidth, available: 820), 820)
    }

    func testReadoutNamesTheSnapPoint() {
        XCTAssertEqual(W.readout(820, available: 1400), "820 pt")
        XCTAssertEqual(W.readout(720, available: 1400), "720 pt · Readable")
        XCTAssertEqual(W.readout(1000, available: 1400), "1000 pt · Wide")
        XCTAssertEqual(W.readout(1400, available: 1400), "1400 pt · Full")
        XCTAssertEqual(W.readout(820.4, available: 1400), "820 pt")
        XCTAssertEqual(W.accessibilityValue(820, available: 1400), "820 points")
        XCTAssertEqual(W.accessibilityValue(720, available: 1400), "720 points, Readable")
    }

    func testAccessibilityStepsAreFortyPointsAndStopOnSnapPoints() {
        XCTAssertEqual(W.incremented(800, available: 1400), 840)
        XCTAssertEqual(W.decremented(800, available: 1400), 760)
        XCTAssertEqual(W.decremented(750, available: 1400), 720, "stops on Readable")
        XCTAssertEqual(W.decremented(720, available: 1400), 680, "and moves on from it")
        XCTAssertEqual(W.incremented(700, available: 1400), 720)
        XCTAssertEqual(W.incremented(980, available: 1400), 1000, "stops on Wide")
        XCTAssertEqual(W.incremented(1380, available: 1400), 1400, "held to Full")
        XCTAssertEqual(W.incremented(1400, available: 1400), 1400)
        XCTAssertEqual(W.decremented(580, available: 1400), 560, "held to the minimum")
        XCTAssertEqual(W.decremented(560, available: 1400), 560)
    }
}
