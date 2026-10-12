import XCTest
@testable import HerdrKit

/// Instant typing: `PredictionEngine` against a fake screen and a hand-advanced clock, so
/// every acknowledgment, echo and threshold is exact.
final class PredictiveEchoTests: XCTestCase {

    private final class Clock {
        var now: TimeInterval = 100
    }

    /// A terminal grid whose echo the test writes by hand.
    private final class FakeScreen: PredictionScreen {
        private(set) var columns: Int
        private(set) var rows: Int
        var cursor: (col: Int, row: Int) = (0, 0)
        private var grid: [[String]]

        init(columns: Int = 40, rows: Int = 6, prompt: String = "$ ") {
            self.columns = columns
            self.rows = rows
            grid = Array(repeating: Array(repeating: " ", count: columns), count: rows)
            write(prompt)
        }

        func text(col: Int, row: Int) -> String {
            guard row >= 0, row < rows, col >= 0, col < columns else { return " " }
            return grid[row][col]
        }

        /// Prints at the cursor, as the shell's echo would.
        func write(_ text: String) {
            for character in text {
                grid[cursor.row][cursor.col] = String(character)
                cursor.col = min(cursor.col + 1, columns - 1)
            }
        }

        func put(_ text: String, col: Int, row: Int) {
            for (offset, character) in text.enumerated() { grid[row][col + offset] = String(character) }
        }

        /// Long typing runs: a fresh prompt on the row once the line is nearly full.
        var autoPrompt = false

        func newPromptIfFull() {
            guard autoPrompt, cursor.col > columns - 6 else { return }
            grid[cursor.row] = Array(repeating: " ", count: columns)
            cursor = (0, cursor.row)
            write("$ ")
        }

        func resize(columns: Int) {
            grid = grid.map { row in
                Array(row.prefix(columns)) + Array(repeating: " ", count: max(0, columns - row.count))
            }
            self.columns = columns
            cursor.col = min(cursor.col, columns - 1)
        }
    }

    private let clock = Clock()
    private var batch: UInt64 = 0

    private func makeEngine(_ mode: PredictionEngine.Mode) -> PredictionEngine {
        let clock = self.clock
        return PredictionEngine(mode: mode, clock: { clock.now })
    }

    private func advance(ms: Double) { clock.now += ms / 1000 }

    @discardableResult
    private func type(_ engine: PredictionEngine, _ screen: FakeScreen, _ text: String) -> UInt64 {
        batch += 1
        engine.userBytes(Array(text.utf8), screen: screen, batch: batch)
        return batch
    }

    /// Types `text`, then the server acks it after `rttMS` and echoes it in the same
    /// instant. Returns the overlay right after the key, before any echo.
    @discardableResult
    private func roundTrip(_ engine: PredictionEngine, _ screen: FakeScreen, _ text: String,
                           rttMS: Double) -> PredictionOverlay {
        let sent = type(engine, screen, text)
        let seen = engine.overlay
        advance(ms: rttMS)
        engine.batchAcked(sent)
        screen.write(text)
        engine.outputArrived(screen: screen)
        screen.newPromptIfFull()
        return seen
    }

    private func cell(_ col: Int, _ row: Int, _ text: String?, underlined: Bool = false) -> PredictionOverlay.Cell {
        PredictionOverlay.Cell(col: col, row: row, text: text, underlined: underlined)
    }

    private func at(_ col: Int, _ row: Int) -> PredictionOverlay.Position {
        PredictionOverlay.Position(col: col, row: row)
    }

    // MARK: - Echo, confirmation, no echo

    func testEchoingShellConfirmsTheEpochThenShowsKeysAtOnce() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()

        let first = type(engine, screen, "l")
        XCTAssertTrue(engine.overlay.isEmpty, "the first key of an epoch is tentative until the screen confirms it")
        advance(ms: 10)
        engine.batchAcked(first)
        advance(ms: 5)
        screen.write("l")
        engine.outputArrived(screen: screen)
        XCTAssertTrue(engine.overlay.isEmpty, "a confirmed echo leaves nothing to draw")

        let second = type(engine, screen, "s")
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [cell(3, 0, "s")], cursor: at(4, 0)),
                       "after a confirmation the next key is drawn before any round trip")
        XCTAssertEqual(engine.shown, 1)

        advance(ms: 10)
        engine.batchAcked(second)
        advance(ms: 5)
        screen.write("s")
        engine.outputArrived(screen: screen)
        XCTAssertTrue(engine.overlay.isEmpty)
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertEqual(engine.confirmed, 1)
        XCTAssertEqual(engine.wrong, 0)
    }

    func testPasswordPromptThatDoesNotEchoNeverShowsAPrediction() {
        let engine = makeEngine(.always)
        let screen = FakeScreen(prompt: "Password: ")
        for character in "secret" {
            let sent = type(engine, screen, String(character))
            XCTAssertTrue(engine.overlay.isEmpty, "no echo was ever confirmed: \(character) must stay hidden")
            advance(ms: 100)
            engine.batchAcked(sent)
            advance(ms: 100)
            screen.put("spinner", col: 0, row: 3)   // unrelated output, no echo
            engine.outputArrived(screen: screen)
            XCTAssertTrue(engine.overlay.isEmpty)
        }
        XCTAssertEqual(engine.shown, 0)
        XCTAssertEqual(engine.wrong, 0, "hidden guesses are never counted wrong")
    }

    func testSilentPromptExpiresWithoutAnyOutput() {
        let engine = makeEngine(.always)
        let screen = FakeScreen(prompt: "Password: ")
        let sent = type(engine, screen, "x")
        advance(ms: 100)
        engine.batchAcked(sent)
        XCTAssertTrue(engine.needsTick)
        advance(ms: 500)
        engine.tick(screen: screen)
        XCTAssertTrue(engine.needsTick, "half a second after the ack is not yet an expiry")
        advance(ms: 600)
        engine.tick(screen: screen)
        XCTAssertFalse(engine.needsTick, "a second after the ack with no output, the guess is dropped")
        XCTAssertTrue(engine.overlay.isEmpty)
    }

    func testApplicationMovingTheCursorElsewhereWithdrawsTheShownKey() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)

        let sent = type(engine, screen, "x")
        XCTAssertEqual(engine.overlay.cells, [cell(3, 0, "x")])

        // The application did not echo: it redrew elsewhere and parked the cursor there.
        screen.put("> ", col: 0, row: 3)
        screen.cursor = (2, 3)
        advance(ms: 100)
        engine.batchAcked(sent)
        advance(ms: 10)
        engine.outputArrived(screen: screen)
        XCTAssertEqual(engine.overlay.cells, [cell(3, 0, "x")],
                       "output only 10 ms after the ack may still be ahead of the echo")
        advance(ms: 50)
        engine.outputArrived(screen: screen)
        XCTAssertTrue(engine.overlay.isEmpty, "output 60 ms after the ack without the echo: the guess was wrong")
        XCTAssertEqual(engine.wrong, 1)

        type(engine, screen, "y")
        XCTAssertTrue(engine.overlay.isEmpty, "after a wrong guess the next key is tentative again")
    }

    func testEchoThatArrivesBeforeTheAckConfirmsWhenTheAckComes() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)

        let sent = type(engine, screen, "x")
        advance(ms: 5)
        screen.write("x")
        engine.outputArrived(screen: screen)
        XCTAssertTrue(engine.hasPredictions, "not acked yet: nothing is checked")
        XCTAssertEqual(engine.overlay.cells, [], "the screen already shows the key, so it is not drawn again")
        advance(ms: 100)
        engine.batchAcked(sent, screen: screen)
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertEqual(engine.confirmed, 1)
        XCTAssertEqual(engine.wrong, 0)
    }

    func testFailedSendDropsEveryPredictionWithoutCountingItWrong() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)
        let sent = type(engine, screen, "x")
        XCTAssertFalse(engine.overlay.isEmpty)
        engine.batchAcked(sent, failed: true)
        XCTAssertTrue(engine.overlay.isEmpty)
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertEqual(engine.wrong, 0)
    }

    // MARK: - Editing keys

    func testBackspaceErasesAtOnceAndIsCheckedAgainstTheScreen() {
        let engine = makeEngine(.always)
        let screen = FakeScreen(prompt: "$ ab")
        roundTrip(engine, screen, "c", rttMS: 10)

        let sent = type(engine, screen, "\u{7f}")
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [cell(4, 0, " ")], cursor: at(4, 0)))

        // The shell's echo: back, blank, back.
        screen.put(" ", col: 4, row: 0)
        screen.cursor = (4, 0)
        advance(ms: 10)
        engine.batchAcked(sent)
        engine.outputArrived(screen: screen)
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [], cursor: at(4, 0)))
        advance(ms: 60)
        engine.outputArrived(screen: screen)
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertEqual(engine.wrong, 0)
    }

    func testArrowsMoveThePredictedCursorAndTypingInsertsMidLine() {
        let engine = makeEngine(.always)
        let screen = FakeScreen(prompt: "$ a")
        roundTrip(engine, screen, "c", rttMS: 10)

        type(engine, screen, "\u{1b}[D")
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [], cursor: at(3, 0)))
        let sent = type(engine, screen, "b")
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [cell(3, 0, "b"), cell(4, 0, "c")], cursor: at(4, 0)),
                       "the rest of the row shifts right")

        screen.put("abc", col: 2, row: 0)
        screen.cursor = (4, 0)
        advance(ms: 10)
        engine.batchAcked(sent, screen: screen)
        XCTAssertFalse(engine.hasPredictions)

        type(engine, screen, "\u{1b}OD")
        XCTAssertEqual(engine.overlay.cursor, at(3, 0), "application-mode Left")
        type(engine, screen, "\u{1b}[C")
        XCTAssertEqual(engine.overlay.cursor, at(4, 0), "Right")

        type(engine, screen, "\u{1b}[1;5D")
        type(engine, screen, "z")
        XCTAssertEqual(engine.overlay.cells, [], "a key after Ctrl+Left is tentative")
        XCTAssertEqual(engine.overlay.cursor, at(4, 0), "and the cursor stays where it was last predicted")
    }

    func testEnterMakesEverythingAfterItTentative() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)

        type(engine, screen, "\r")
        XCTAssertTrue(engine.overlay.isEmpty, "the next line is not shown until something on it is confirmed")
        type(engine, screen, "x")
        XCTAssertTrue(engine.overlay.isEmpty)
    }

    func testTheLastColumnIsTentative() {
        let engine = makeEngine(.always)
        let screen = FakeScreen(columns: 10, prompt: "$ abcde")
        roundTrip(engine, screen, "f", rttMS: 10)

        let sent = type(engine, screen, "g")
        XCTAssertEqual(engine.overlay, PredictionOverlay(cells: [cell(8, 0, "g")], cursor: at(9, 0)))
        advance(ms: 10)
        engine.batchAcked(sent)
        screen.write("g")
        engine.outputArrived(screen: screen)
        XCTAssertFalse(engine.hasPredictions)

        type(engine, screen, "h")
        XCTAssertEqual(engine.overlay.cells, [], "a key in the last column may wrap or not: not shown")
        XCTAssertNotEqual(engine.overlay.cursor, at(0, 1), "nor the wrap it might cause")
    }

    func testWideCharactersAreNotPredictedButAccentedLatinIs() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)

        let sent = type(engine, screen, "é")
        XCTAssertEqual(engine.overlay.cells, [cell(3, 0, "é")])
        advance(ms: 10)
        engine.batchAcked(sent)
        screen.write("é")
        engine.outputArrived(screen: screen)

        type(engine, screen, "界")
        XCTAssertTrue(engine.overlay.isEmpty)
        type(engine, screen, "x")
        XCTAssertTrue(engine.overlay.isEmpty, "everything after a wide character is tentative")
    }

    // MARK: - Resets and modes

    func testResizeDropsPredictionsWithoutCountingThemWrong() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)
        type(engine, screen, "x")
        XCTAssertFalse(engine.overlay.isEmpty)

        screen.resize(columns: 30)
        engine.outputArrived(screen: screen)
        XCTAssertTrue(engine.overlay.isEmpty)
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertEqual(engine.wrong, 0)
        type(engine, screen, "y")
        XCTAssertTrue(engine.overlay.isEmpty, "a resized screen must confirm again before anything shows")
    }

    func testExplicitResetHidesAtOnce() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)
        type(engine, screen, "x")
        engine.reset()
        XCTAssertTrue(engine.overlay.isEmpty)
        XCTAssertFalse(engine.hasPredictions)
        type(engine, screen, "y")
        XCTAssertTrue(engine.overlay.isEmpty)
    }

    func testOffNeverPredicts() {
        let engine = makeEngine(.off)
        let screen = FakeScreen()
        for character in "hello" {
            let shown = roundTrip(engine, screen, String(character), rttMS: 200)
            XCTAssertTrue(shown.isEmpty)
        }
        XCTAssertFalse(engine.hasPredictions)
        XCTAssertNil(engine.srtt)

        let always = makeEngine(.always)
        roundTrip(always, screen, "l", rttMS: 10)
        type(always, screen, "x")
        XCTAssertFalse(always.overlay.isEmpty)
        always.setMode(.off)
        XCTAssertTrue(always.overlay.isEmpty, "turning it off hides what is drawn")
        XCTAssertFalse(always.hasPredictions)
    }

    // MARK: - Thresholds

    func testAutoShowsAbove30msAndHidesOnlyAtOrBelow20ms() throws {
        let engine = makeEngine(.auto)
        let screen = FakeScreen()
        screen.autoPrompt = true
        XCTAssertTrue(roundTrip(engine, screen, "a", rttMS: 10).isEmpty, "no round trip measured yet")
        for _ in 0..<3 { XCTAssertTrue(roundTrip(engine, screen, "a", rttMS: 10).isEmpty) }
        XCTAssertEqual(try XCTUnwrap(engine.srtt), 0.010, accuracy: 0.0001)

        var turnedOn = false
        for _ in 0..<20 {
            let before = try XCTUnwrap(engine.srtt)
            let shown = !roundTrip(engine, screen, "b", rttMS: 40).isEmpty
            XCTAssertEqual(shown, before > PredictionEngine.srttTriggerHigh, "srtt \(before)")
            if shown { turnedOn = true; break }
        }
        XCTAssertTrue(turnedOn)

        for _ in 0..<15 {
            XCTAssertFalse(roundTrip(engine, screen, "c", rttMS: 25).isEmpty, "between the thresholds it stays on")
        }
        XCTAssertLessThan(try XCTUnwrap(engine.srtt), PredictionEngine.srttTriggerHigh)

        var turnedOff = false
        for _ in 0..<20 {
            let before = try XCTUnwrap(engine.srtt)
            let shown = !roundTrip(engine, screen, "d", rttMS: 5).isEmpty
            XCTAssertEqual(shown, before > PredictionEngine.srttTriggerLow, "srtt \(before)")
            if !shown { turnedOff = true; break }
        }
        XCTAssertTrue(turnedOff)
    }

    func testUnderlineAbove80msUntilBackAtOrBelow50ms() throws {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        screen.autoPrompt = true
        func underlined(_ character: String, rttMS: Double) throws -> Bool {
            let seen = roundTrip(engine, screen, character, rttMS: rttMS)
            return try XCTUnwrap(seen.cells.first { $0.text == character }).underlined
        }
        roundTrip(engine, screen, "a", rttMS: 60)
        XCTAssertFalse(try underlined("b", rttMS: 60), "60 ms is under the 80 ms trigger")

        var turnedOn = false
        for _ in 0..<20 {
            let before = try XCTUnwrap(engine.srtt)
            let flag = try underlined("c", rttMS: 100)
            XCTAssertEqual(flag, before > PredictionEngine.flagTriggerHigh, "srtt \(before)")
            if flag { turnedOn = true; break }
        }
        XCTAssertTrue(turnedOn)

        for _ in 0..<10 { XCTAssertTrue(try underlined("d", rttMS: 60), "above 50 ms it stays underlined") }

        var turnedOff = false
        for _ in 0..<20 {
            let before = try XCTUnwrap(engine.srtt)
            let flag = try underlined("e", rttMS: 20)
            XCTAssertEqual(flag, before > PredictionEngine.flagTriggerLow, "srtt \(before)")
            if !flag { turnedOff = true; break }
        }
        XCTAssertTrue(turnedOff)
    }

    func testGlitchShowsOnAFastLinkThenUnderlinesThenRepairs() throws {
        let engine = makeEngine(.auto)
        let screen = FakeScreen()
        screen.autoPrompt = true
        for _ in 0..<3 { roundTrip(engine, screen, "a", rttMS: 10) }

        let slow = type(engine, screen, "k")
        XCTAssertTrue(engine.overlay.isEmpty, "10 ms round trip: auto hides")
        advance(ms: 100)
        engine.tick(screen: screen)
        XCTAssertTrue(engine.overlay.isEmpty)
        advance(ms: 200)
        engine.tick(screen: screen)
        let shownKey = try XCTUnwrap(engine.overlay.cells.first { $0.text == "k" }, "pending 300 ms: a glitch shows it")
        XCTAssertFalse(shownKey.underlined)
        advance(ms: 4_800)
        engine.tick(screen: screen)
        XCTAssertEqual(engine.overlay.cells.first { $0.text == "k" }?.underlined, true,
                       "pending 5 s: underlined as well")

        advance(ms: 10)
        engine.batchAcked(slow)
        screen.write("k")
        engine.outputArrived(screen: screen)

        // Each quick confirmation, at most one per 150 ms, takes one off the glitch count (20).
        for _ in 0..<9 {
            advance(ms: 150)
            roundTrip(engine, screen, "q", rttMS: 10)
        }
        advance(ms: 150)
        XCTAssertEqual(roundTrip(engine, screen, "u", rttMS: 10).cells.first?.underlined, true, "11 left: underlined")
        advance(ms: 150)
        XCTAssertEqual(roundTrip(engine, screen, "v", rttMS: 10).cells.first?.underlined, false,
                       "10 left: shown, no longer underlined")
        for _ in 0..<9 {
            advance(ms: 150)
            XCTAssertFalse(roundTrip(engine, screen, "w", rttMS: 10).isEmpty)
        }
        advance(ms: 150)
        XCTAssertTrue(roundTrip(engine, screen, "x", rttMS: 10).isEmpty, "repaired: a fast link hides again")
    }

    func testConfirmationsCloserThan150msDoNotRepairFaster() {
        let engine = makeEngine(.auto)
        let screen = FakeScreen()
        screen.autoPrompt = true
        for _ in 0..<3 { roundTrip(engine, screen, "a", rttMS: 10) }
        let slow = type(engine, screen, "k")
        advance(ms: 300)
        engine.tick(screen: screen)                  // glitch: 10
        advance(ms: 10)
        engine.batchAcked(slow)
        screen.write("k")
        engine.outputArrived(screen: screen)
        for _ in 0..<15 { roundTrip(engine, screen, "q", rttMS: 10) }   // 10 ms apart
        XCTAssertFalse(roundTrip(engine, screen, "r", rttMS: 10).isEmpty,
                       "a burst of confirmations repairs at most one step per 150 ms")
    }

    // MARK: - Measurement

    func testFirstPaintIsReportedOncePerShownKey() {
        let engine = makeEngine(.always)
        let screen = FakeScreen()
        roundTrip(engine, screen, "l", rttMS: 10)
        XCTAssertEqual(engine.takeFirstPaints(), [], "a tentative key was never shown")

        advance(ms: 3)
        let pressed = clock.now
        type(engine, screen, "x")
        XCTAssertEqual(engine.takeFirstPaints(), [PredictionEngine.FirstPaint(pressedAt: pressed, shownAt: pressed)])
        engine.outputArrived(screen: screen)
        XCTAssertEqual(engine.takeFirstPaints(), [], "a key is reported once")
    }

    func testRoundTripSamplesAckWhenOutputCameFirst() throws {
        let engine = makeEngine(.auto)
        let screen = FakeScreen()
        let sent = type(engine, screen, "a")
        advance(ms: 30)
        screen.write("a")
        engine.outputArrived(screen: screen)
        XCTAssertNil(engine.srtt, "no sample before the ack")
        advance(ms: 90)
        engine.batchAcked(sent)
        XCTAssertEqual(try XCTUnwrap(engine.srtt), 0.120, accuracy: 0.0001,
                       "output was already in: the sample ends at the ack")
    }
}
