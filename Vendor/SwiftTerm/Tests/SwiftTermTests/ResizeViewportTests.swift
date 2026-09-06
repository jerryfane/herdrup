//
//  ResizeViewportTests.swift
//  SwiftTermTests
//
//  Resizing must not change what a reader is reading. These tests pin the
//  *logical* text of the top visible row across widening, narrowing, height
//  changes, scrollback eviction, alternate-screen borrowing and repeated
//  sweeps -- the failure mode being fixed is a viewport that keeps its physical
//  row number (or its pixel offset) and therefore silently jumps to different
//  records when reflow collapses or splits wrapped lines.
//

import Testing
@testable import SwiftTerm

// MARK: - fixtures

/// One ~90 cell record: wide enough to wrap at 80 columns and to fit on one row
/// at 120, and self-identifying so a jump of even one record is visible.
private func record (_ n: Int, width: Int = 90) -> String {
    let head = "record \(String (format: "%03d", n)) "
    return head + String (repeating: "-", count: max (0, width - head.count))
}

private func seedRecords (_ terminal: Terminal, count: Int = 100, width: Int = 90) {
    for i in 0..<count {
        terminal.feed (text: record (i, width: width) + "\r\n")
    }
}

private func topRow (_ terminal: Terminal) -> String {
    TerminalTestHarness.lineText (buffer: terminal.buffer, row: 0) ?? ""
}

private func rowText (_ terminal: Terminal, _ row: Int) -> String {
    TerminalTestHarness.lineText (buffer: terminal.buffer, row: row) ?? ""
}

/// Column of the first cell in the top visible row holding `scalar`, or nil.
private func columnOfScalar (_ terminal: Terminal, _ scalar: UnicodeScalar, row: Int = 0) -> Int? {
    let buffer = terminal.buffer
    let index = buffer.yDisp + row
    guard index >= 0, index < buffer.lines.count else { return nil }
    let line = buffer.lines [index]
    for col in 0..<line.count {
        if line [col].code == Int32 (scalar.value) {
            return col
        }
    }
    return nil
}

private func isHistoryViewport (_ terminal: Terminal) -> Bool {
    let buffer = terminal.buffer
    return buffer.yDisp < buffer.yBase
}

// MARK: - tests

@Suite("resize viewport anchoring")
struct ResizeViewportTests {

    /// The reproduction: 100 wrapped records at 80 columns, reader parked on
    /// record 20, widen to 120. Keeping `yDisp` at 40 shows record 40.
    @Test("widening keeps the record the reader is on")
    func wideningKeepsRecord () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal)

        terminal.buffer.yDisp = 40
        #expect (topRow (terminal) == String (record (20).prefix (80)))

        terminal.resize (cols: 120, rows: 24)

        #expect (topRow (terminal) == record (20))
        #expect (isHistoryViewport (terminal))
    }

    /// Narrowing is the same requirement in the other direction.
    @Test("narrowing keeps the record the reader is on")
    func narrowingKeepsRecord () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 120, rows: 24, scrollback: 500)
        seedRecords (terminal)

        terminal.buffer.yDisp = 20
        #expect (topRow (terminal) == record (20))

        terminal.resize (cols: 80, rows: 24)

        #expect (topRow (terminal) == String (record (20).prefix (80)))
        #expect (isHistoryViewport (terminal))
    }

    /// Ten sweeps must not drift: re-anchoring on "the first cell of the top
    /// row" every time walks the viewport backwards one row per cycle inside a
    /// long wrapped line, which is why the mapped cell is carried across
    /// resizes instead of recaptured.
    @Test("repeated 80-120-80 sweeps inside a long wrapped line do not drift")
    func repeatedSweepsDoNotDrift () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 1000)
        for i in 0..<20 {
            terminal.feed (text: record (i, width: 500) + "\r\n")
        }

        // Park inside the wrapped body of one record, not on its first row.
        terminal.buffer.yDisp = 7 * 5 + 3
        let expected = topRow (terminal)
        #expect (expected.isEmpty == false)

        for _ in 0..<10 {
            terminal.resize (cols: 120, rows: 24)
            terminal.resize (cols: 80, rows: 24)
            #expect (topRow (terminal) == expected)
        }
    }

    /// The anchored cell lives in a continuation row that widening deletes: it
    /// has to be followed into the row that absorbed it, and the reader must
    /// end up on that row rather than on the group head's neighbours or on the
    /// oldest history.
    @Test("an anchored cell survives deletion of its own wrapped row")
    func anchoredCellSurvivesRowDeletion () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 8, scrollback: 500)
        // Each record is exactly 3 rows at 80 columns, one row at 240.
        for i in 0..<60 {
            let text = "A\(i)-" + String (repeating: "a", count: 76)
                + "B\(i)-" + String (repeating: "b", count: 76)
                + "C\(i)-" + String (repeating: "c", count: 76)
            terminal.feed (text: text + "\r\n")
        }

        // Top row is the *second* row of record 10's group: it starts with B10.
        terminal.buffer.yDisp = 10 * 3 + 1
        #expect (topRow (terminal).hasPrefix ("B10-"))

        terminal.resize (cols: 240, rows: 8)

        let top = topRow (terminal)
        #expect (top.hasPrefix ("A10-"))
        #expect (top.contains ("B10-"))
        #expect (isHistoryViewport (terminal))
    }

    /// When the scrollback really does drop the anchored line, the viewport
    /// clamps to the oldest surviving history -- and does not silently start
    /// following the tail.
    @Test("actual eviction clamps to the oldest surviving history")
    func evictionClampsToOldestHistory () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 6, scrollback: 20)
        seedRecords (terminal, count: 40)

        terminal.buffer.yDisp = 0
        #expect (isHistoryViewport (terminal))

        // Narrowing hard inserts a row per wrapped record; the ring is already
        // full, so the top of the scrollback is trimmed away.
        terminal.resize (cols: 40, rows: 6)

        #expect (terminal.buffer.yDisp == 0)
        #expect (isHistoryViewport (terminal))
    }

    /// A blank wrapped continuation is exactly the row reflow merges away.
    /// Treating that as eviction teleports the reader to the oldest history.
    @Test("a blank wrapped continuation merging away does not jump to oldest history")
    func blankContinuationDoesNotJump () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        for i in 0..<40 {
            // 81 cells: wraps, then the continuation row is erased, leaving a
            // wrapped row with no content at all.
            terminal.feed (text: record (i, width: 81))
            terminal.feed (text: "\u{1b}[2K")
            terminal.feed (text: "\r\n")
        }

        terminal.buffer.yDisp = 10 * 2 + 1     // the blank continuation of record 10
        #expect (topRow (terminal).isEmpty)

        terminal.resize (cols: 120, rows: 24)

        // The erased continuation took the 81st cell with it, so the merged
        // line holds exactly the 80 cells that survived.
        #expect (topRow (terminal) == String (record (10, width: 81).prefix (80)))
        #expect (isHistoryViewport (terminal))
    }

    /// With a full ring, `CircularBufferLineList.recycle` hands old line objects
    /// to the tail. A cached anchor that trusted object identity alone would
    /// follow its line into the newest output and yank the reader to the bottom.
    @Test("recycled line objects do not drag the viewport to the tail")
    func recycledLinesDoNotDragViewport () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 6, scrollback: 30)
        seedRecords (terminal, count: 40)                 // fills the ring

        terminal.userScrolling = true                     // the reader holds position
        terminal.buffer.yDisp = 4
        terminal.resize (cols: 100, rows: 6)              // caches an anchor
        #expect (isHistoryViewport (terminal))

        // Fill the ring several times over: the very line objects the cached
        // anchor pointed at are recycled into brand new tail rows.
        seedRecords (terminal, count: 60)

        let buffer = terminal.buffer
        let anchored = buffer.lines [buffer.yDisp]
        terminal.resize (cols: 80, rows: 6)

        var landed: Int? = nil
        for i in 0..<buffer.lines.count where buffer.lines [i] === anchored {
            landed = i
            break
        }
        if let landed {
            #expect (buffer.yDisp == min (landed, buffer.yBase))
        } else {
            #expect (buffer.yDisp == 0)                   // genuinely evicted
        }
        #expect (buffer.yDisp != buffer.yBase)            // never dragged to the tail
    }

    /// Reflow deliberately skips the wrapped group holding the cursor, so that
    /// group is only truncated while every group above it is rewrapped and
    /// shifts. Row arithmetic breaks on that shift; line identity does not.
    @Test("a skipped cursor group does not move the reader")
    func skippedCursorGroupDoesNotMoveReader () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 8, scrollback: 500)
        seedRecords (terminal, count: 60)
        // A wrapped group holding the cursor: reflow leaves it alone.
        terminal.feed (text: "CURSOR-" + String (repeating: "z", count: 120))

        terminal.buffer.yDisp = 10 * 2             // record 10, first row
        #expect (topRow (terminal) == String (record (10).prefix (80)))

        terminal.resize (cols: 40, rows: 8)

        #expect (topRow (terminal) == String (record (10).prefix (40)))
        #expect (isHistoryViewport (terminal))
    }

    /// Height-only changes never reach `reflow`, but they do insert and remove
    /// rows and move `yBase`.
    @Test("a height-only resize keeps the top row")
    func heightOnlyResizeKeepsTopRow () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal)

        terminal.buffer.yDisp = 40
        let expected = topRow (terminal)

        terminal.resize (cols: 80, rows: 12)
        #expect (topRow (terminal) == expected)

        terminal.resize (cols: 80, rows: 30)
        #expect (topRow (terminal) == expected)
        #expect (isHistoryViewport (terminal))
    }

    /// An agent that borrows the alternate screen during a resize must not cost
    /// the reader their place in the normal buffer.
    @Test("reading position survives alternate-screen borrowing")
    func readingSurvivesAlternateScreen () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal)

        terminal.buffer.yDisp = 40
        let expected = topRow (terminal)

        terminal.feed (text: "\u{1b}[?1049h")       // alternate screen
        terminal.feed (text: "full screen redraw")
        terminal.resize (cols: 120, rows: 24)
        #expect (terminal.buffer.yDisp == terminal.buffer.yBase)   // alt screen has no history

        terminal.feed (text: "\u{1b}[?1049l")       // back to normal
        #expect (topRow (terminal) == record (20))
        #expect (expected.hasPrefix (String (record (20).prefix (80))))
        #expect (isHistoryViewport (terminal))
    }

    /// A tail follower stays on the newest output, at any size.
    @Test("tail following survives resizing")
    func tailFollowingSurvivesResize () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal)
        #expect (terminal.buffer.yDisp == terminal.buffer.yBase)

        terminal.resize (cols: 120, rows: 24)
        #expect (terminal.buffer.yDisp == terminal.buffer.yBase)
        #expect (rowText (terminal, 22) == record (99))

        terminal.resize (cols: 80, rows: 20)
        #expect (terminal.buffer.yDisp == terminal.buffer.yBase)
    }

    /// Returning to the tail explicitly must stick: the anchor cached by an
    /// earlier resize cannot pull the reader back into history.
    @Test("an explicit return to the tail is not undone by the next resize")
    func returnToTailSticks () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal)

        terminal.buffer.yDisp = 40
        terminal.resize (cols: 120, rows: 24)
        #expect (isHistoryViewport (terminal))

        terminal.buffer.yDisp = terminal.buffer.yBase          // jump to latest
        terminal.resize (cols: 80, rows: 24)

        #expect (terminal.buffer.yDisp == terminal.buffer.yBase)
    }

    /// A resize inside a DEC 2026 batch must not forge the batch's end: the
    /// application still owns when its frame is complete.
    @Test("resizing does not end synchronized output")
    func resizeDoesNotEndSynchronizedOutput () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 24, scrollback: 500)
        seedRecords (terminal, count: 10)

        terminal.feed (text: "\u{1b}[?2026h")
        #expect (terminal.synchronizedOutputActive)

        terminal.resize (cols: 120, rows: 24)
        #expect (terminal.synchronizedOutputActive)

        terminal.feed (text: "\u{1b}[?2026l")
        #expect (terminal.synchronizedOutputActive == false)
    }

    /// The mapped cell must be the *same cell*, not merely the same column: a
    /// three-row group narrowed to a non-divisor width with a wide glyph on a
    /// new row boundary moves it several times, including in place.
    @Test("the anchored cell itself lands in the new top row")
    func anchoredCellIdentityIsPreserved () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 10, scrollback: 500)
        let marker: UnicodeScalar = "\u{25C6}"          // unique in the fixture
        for i in 0..<12 {
            var text = String (repeating: "a", count: 80)      // row 0 of the group
            text += String (marker)                            // cell 80: the anchor
            text += String (repeating: "b", count: 29)         // cells 81...109
            text += "\u{6F22}"                                 // cells 110-111, wide
            text += String (repeating: "c", count: 88)         // cells 112...199
            terminal.feed (text: i == 5 ? text : String (repeating: "d", count: 200))
            terminal.feed (text: "\r\n")
        }

        terminal.buffer.yDisp = 5 * 3 + 1                      // the marker's row
        #expect (columnOfScalar (terminal, marker) == 0)
        let captured = TerminalTestHarness.charData (buffer: terminal.buffer, row: 0, col: 0)
        #expect (captured?.code == Int32 (marker.value))

        terminal.resize (cols: 37, rows: 10)

        guard let column = columnOfScalar (terminal, marker) else {
            Issue.record ("the anchored cell is no longer in the top visible row")
            return
        }
        let landed = TerminalTestHarness.charData (buffer: terminal.buffer, row: 0, col: column)
        #expect (landed?.code == captured?.code)
        #expect (landed?.width == captured?.width)
        #expect (landed?.attribute == captured?.attribute)
        #expect (isHistoryViewport (terminal))
    }

    /// Widening computed its first destination column from *buffer row zero*
    /// instead of from the group being reflowed. Row zero ending in a null cell
    /// while row one starts with a wide glyph makes that length 79 rather than
    /// the group head's 80, and every wrapped record then has its own tail
    /// spliced one cell into its text.
    @Test("widening starts at the group's own boundary, not row zero")
    func wideningUsesGroupBoundary () {
        let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 80, rows: 6, scrollback: 500)
        terminal.feed (text: "short\r\n")                    // row 0: ends in a null cell
        terminal.feed (text: "\u{6F22} wide first cell\r\n")  // row 1: starts wide
        for i in 0..<20 {
            terminal.feed (text: record (i) + "\r\n")        // 80 + 10 cells
        }

        terminal.resize (cols: 120, rows: 6)

        // Every record must read back exactly; a wrong destination column
        // splices the wrapped tail into the middle of its own head.
        let buffer = terminal.buffer
        for i in 0..<20 {
            let text = buffer.translateBufferLineToString (lineIndex: 2 + i, trimRight: true)
            #expect (text == record (i))
        }
    }
}
