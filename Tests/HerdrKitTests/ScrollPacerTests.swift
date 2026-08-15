import XCTest
@testable import HerdrKit

/// Pacing arithmetic for driven scroll.
///
/// Two of these are regression locks for shipped fixes, named in their doc comments. The
/// rest pin the new time-gate. All pure — no sleeping, time is injected.
final class ScrollPacerTests: XCTestCase {

    private let line: Double = 16
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: regression locks

    /// REGRESSION LOCK — "carry unemitted wheel ticks".
    ///
    /// A drag of 3.5 lines with a cap of 1 emits one tick, and the remaining 2.5 lines
    /// must SURVIVE rather than being thrown away, or a fast drag is silently truncated
    /// and the pane scrolls far less than the finger asked for.
    ///
    /// Mutation: consuming the full `ticks` instead of the emitted `count` must fail here.
    func testUnemittedTicksAreCarriedNotDiscarded() {
        var pacer = ScrollPacer(profile: .wheel)
        let e = pacer.drag(dy: 3.5 * line, lineHeight: line, now: t0)
        XCTAssertEqual(e, ScrollPacer.Emission(up: true, count: 1))
        // 3.5 lines in, 1 emitted, carry clamped to the profile's 1-line bound.
        XCTAssertEqual(pacer.carry, 1 * line, accuracy: 0.001)
    }

    /// REGRESSION LOCK — "bound wheel carry to one frame".
    ///
    /// Reversing direction inside a single touch must start scrolling the OTHER way
    /// promptly. Without a bounded carry, an opposite backlog keeps firing the old
    /// direction for many frames and the pane scrolls backwards under the finger.
    func testDirectionReversalEmitsTheNewDirectionPromptly() {
        var pacer = ScrollPacer(profile: .arrows)   // unpaced, so timing cannot mask this
        _ = pacer.drag(dy: 10 * line, lineHeight: line, now: t0)
        XCTAssertLessThanOrEqual(abs(pacer.carry), 4 * line + 0.001, "carry must stay bounded")

        // Now drag hard the other way; the very next emission must be downward.
        let e = pacer.drag(dy: -6 * line, lineHeight: line, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(e?.up, false, "a reversal must not keep emitting the old direction")
    }

    /// A flick cannot bank unbounded travel that keeps scrolling after lift-off.
    func testHugeSingleCallbackCannotBankUnboundedCarry() {
        var pacer = ScrollPacer(profile: .wheel)
        _ = pacer.drag(dy: 400 * line, lineHeight: line, now: t0)
        XCTAssertLessThanOrEqual(abs(pacer.carry), 1 * line + 0.001)
    }

    // MARK: the time gate

    /// Inside `minGap`, emission is refused — however fast the callbacks arrive. This is
    /// the whole point: spacing must not depend on gesture frequency or link speed.
    func testEmissionIsRefusedInsideTheMinimumGap() {
        var pacer = ScrollPacer(profile: .wheel)
        XCTAssertNotNil(pacer.drag(dy: 2 * line, lineHeight: line, now: t0))
        XCTAssertNil(pacer.drag(dy: 2 * line, lineHeight: line, now: t0.addingTimeInterval(0.010)),
                     "10ms after an emission is inside the 30ms gap")
    }

    /// Once the gap has elapsed the withheld travel is still there and emits — the gate
    /// delays, it does not drop.
    func testTravelWithheldByTheGateEmitsOnceItElapses() {
        var pacer = ScrollPacer(profile: .wheel)
        _ = pacer.drag(dy: 2 * line, lineHeight: line, now: t0)
        XCTAssertNil(pacer.drag(dy: 0.2 * line, lineHeight: line, now: t0.addingTimeInterval(0.005)))
        let e = pacer.drag(dy: 0.2 * line, lineHeight: line, now: t0.addingTimeInterval(0.040))
        XCTAssertEqual(e, ScrollPacer.Emission(up: true, count: 1),
                       "travel accumulated during the gate must not be lost")
    }

    /// A long stall must not let travel pile into a burst that replays on resume — the
    /// clamp applies while gated, too.
    func testStallDoesNotBuildABurst() {
        var pacer = ScrollPacer(profile: .wheel)
        _ = pacer.drag(dy: line, lineHeight: line, now: t0)
        for i in 1...50 {
            _ = pacer.drag(dy: 3 * line, lineHeight: line, now: t0.addingTimeInterval(0.001 * Double(i)))
        }
        XCTAssertLessThanOrEqual(abs(pacer.carry), 1 * line + 0.001)
        let e = pacer.drag(dy: 0, lineHeight: line, now: t0.addingTimeInterval(5))
        XCTAssertEqual(e?.count, 1, "resume emits one tick, not a banked burst")
    }

    // MARK: the arrow channel must be unchanged

    /// The alt-screen cursor-key path is numerically identical to the previous inline
    /// arithmetic: cap 4, no time gate, consume-only-emitted, carry clamped to 4 lines.
    /// If this drifts, vim and less regress.
    func testArrowProfileReproducesThePreviousArithmetic() {
        var pacer = ScrollPacer(profile: .arrows)
        // 6 lines of travel, cap 4 -> emit 4, carry 2.
        let e = pacer.drag(dy: 6 * line, lineHeight: line, now: t0)
        XCTAssertEqual(e, ScrollPacer.Emission(up: true, count: 4))
        XCTAssertEqual(pacer.carry, 2 * line, accuracy: 0.001)
        // No gate: a callback 1ms later still emits.
        XCTAssertNotNil(pacer.drag(dy: 3 * line, lineHeight: line, now: t0.addingTimeInterval(0.001)))
    }

    /// Sub-tick travel emits nothing and is banked.
    func testSubTickTravelEmitsNothing() {
        var pacer = ScrollPacer(profile: .wheel)
        XCTAssertNil(pacer.drag(dy: 0.4 * line, lineHeight: line, now: t0))
        XCTAssertEqual(pacer.carry, 0.4 * line, accuracy: 0.001)
    }

    /// Sign convention: a downward drag reveals older content.
    func testDownwardDragScrollsTowardOlderContent() {
        var pacer = ScrollPacer(profile: .wheel)
        XCTAssertEqual(pacer.drag(dy: 2 * line, lineHeight: line, now: t0)?.up, true)
        var down = ScrollPacer(profile: .wheel)
        XCTAssertEqual(down.drag(dy: -2 * line, lineHeight: line, now: t0)?.up, false)
    }

    // MARK: robustness

    /// Degenerate geometry must not divide by zero or synthesise an unbounded tick count.
    func testNonPositiveLineHeightIsGuarded() {
        var pacer = ScrollPacer(profile: .wheel)
        let e = pacer.drag(dy: 40, lineHeight: 0, now: t0)
        XCTAssertEqual(e?.count, 1)
        XCTAssertTrue(pacer.carry.isFinite)
    }

    /// Switching channel drops the carry, so travel banked for the wheel cannot leak out
    /// as a burst of cursor keys when the emulator's mode changes under a live pane.
    func testChangingProfileDropsCarry() {
        var pacer = ScrollPacer(profile: .wheel)
        _ = pacer.drag(dy: 0.9 * line, lineHeight: line, now: t0)
        XCTAssertGreaterThan(pacer.carry, 0)
        pacer.setProfile(.arrows)
        XCTAssertEqual(pacer.carry, 0)
    }

    /// `reset()` clears the gate as well as the carry, so a fresh gesture is not held back
    /// by the previous one's timestamp.
    func testResetClearsGateAndCarry() {
        var pacer = ScrollPacer(profile: .wheel)
        _ = pacer.drag(dy: 2 * line, lineHeight: line, now: t0)
        pacer.reset()
        XCTAssertEqual(pacer.carry, 0)
        XCTAssertNil(pacer.lastEmission)
        XCTAssertNotNil(pacer.drag(dy: 2 * line, lineHeight: line, now: t0.addingTimeInterval(0.001)))
    }
}
