//
//  HistoryPrependTests.swift
//  SwiftTermTests
//
//  herdr: older history paged in above the scrollback. What the reader is looking
//  at must not move, the inserted rows must read in order directly above the old
//  top, the cap must hold, and the alternate screen has no scrollback to extend.
//

import Testing
@testable import SwiftTerm

private func text (_ terminal: Terminal, _ index: Int) -> String {
    terminal.normalBuffer.translateBufferLineToString (
        lineIndex: index, trimRight: true, skipNullCellsFollowingWide: true,
        characterProvider: { terminal.getCharacter (for: $0) })
}

private func visible (_ terminal: Terminal) -> [String] {
    let buffer = terminal.normalBuffer
    return (buffer.yDisp..<(buffer.yDisp + buffer.rows)).map { text (terminal, $0) }
}

private func allLines (_ terminal: Terminal) -> [String] {
    (0..<terminal.normalBuffer.lines.count).map { text (terminal, $0) }
}

/// `count` numbered rows as a server page sends them: CR LF between rows.
private func page (_ prefix: String, _ range: ClosedRange<Int>, trailingNewline: Bool = false) -> ArraySlice<UInt8> {
    let rows = range.map { "\(prefix) \($0)" }.joined (separator: "\r\n")
    return ArraySlice ((rows + (trailingNewline ? "\r\n" : "")).utf8)
}

private func makeLive (rows: Int = 10, scrollback: Int = 500, lines: Int = 100) -> Terminal {
    let (terminal, _) = TerminalTestHarness.makeTerminal (cols: 40, rows: rows, scrollback: scrollback)
    for i in 1...lines {
        terminal.feed (text: "live \(i)\r\n")
    }
    terminal.feed (text: "$ ")
    return terminal
}

@Suite("herdr history prepend")
struct HistoryPrependTests {

    @Test("a reader in the scrollback keeps the same rows on screen")
    func scrolledReaderDoesNotMove () {
        let terminal = makeLive ()
        let buffer = terminal.normalBuffer
        terminal.userScrolling = true
        buffer.yDisp = 30
        let before = visible (terminal)
        let oldTop = text (terminal, 0)
        let yBase = buffer.yBase

        let inserted = terminal.prependHistory (page ("old", 1...50), maxScrollback: 1000)

        #expect (inserted == 50)
        #expect (visible (terminal) == before)
        #expect (buffer.yDisp == 80)
        #expect (buffer.yBase == yBase + 50)
        #expect ((0..<50).map { text (terminal, $0) } == (1...50).map { "old \($0)" })
        #expect (text (terminal, 50) == oldTop)
    }

    @Test("a reader following the tail keeps the live screen and cursor")
    func tailFollowerDoesNotMove () {
        let terminal = makeLive ()
        let buffer = terminal.normalBuffer
        #expect (buffer.yDisp == buffer.yBase)
        let screen = visible (terminal)
        let cursor = (buffer.x, buffer.y)

        terminal.prependHistory (page ("old", 1...20), maxScrollback: 1000)

        #expect (buffer.yDisp == buffer.yBase)
        #expect (visible (terminal) == screen)
        #expect ((buffer.x, buffer.y) == cursor)
        // Output after the insert lands on the live screen, not inside the history.
        terminal.feed (text: "echo next\r\nnext")
        #expect (visible (terminal).last == "next")
        #expect (text (terminal, 0) == "old 1")
    }

    @Test("pages stack: each one goes above the previous")
    func successivePagesStack () {
        let terminal = makeLive (lines: 20)
        terminal.prependHistory (page ("b", 1...5), maxScrollback: 1000)
        terminal.prependHistory (page ("a", 1...5), maxScrollback: 1000)
        let lines = allLines (terminal)
        #expect (Array (lines.prefix (11)) == ["a 1", "a 2", "a 3", "a 4", "a 5",
                                               "b 1", "b 2", "b 3", "b 4", "b 5", "live 1"])
    }

    @Test("a trailing newline ends the last row instead of adding a blank one")
    func trailingNewline () {
        let terminal = makeLive (lines: 20)
        let inserted = terminal.prependHistory (page ("old", 1...3, trailingNewline: true), maxScrollback: 1000)
        #expect (inserted == 3)
        #expect (text (terminal, 2) == "old 3")
        #expect (text (terminal, 3) == "live 1")
    }

    @Test("the ring grows so nothing already held is trimmed")
    func ringGrowsInsteadOfTrimming () {
        let terminal = makeLive (rows: 10, scrollback: 50, lines: 100)
        let buffer = terminal.normalBuffer
        #expect (buffer.lines.count == 60)
        let held = allLines (terminal)

        let inserted = terminal.prependHistory (page ("old", 1...100), maxScrollback: 1000)

        #expect (inserted == 100)
        #expect (buffer.lines.count == 160)
        #expect (Array (allLines (terminal).suffix (60)) == held)
        // Room was made up to the cap, so new output does not push the paged rows out.
        terminal.feed (text: "\r\nmore 1\r\nmore 2")
        #expect (text (terminal, 0) == "old 1")
    }

    @Test("the cap keeps the newest rows of a page and then refuses more")
    func capRespected () {
        let terminal = makeLive (rows: 10, scrollback: 500, lines: 100)
        let buffer = terminal.normalBuffer
        // A cap that leaves exactly 30 rows of headroom.
        let cap = buffer.lines.count - buffer.rows + 30

        let inserted = terminal.prependHistory (page ("old", 1...100), maxScrollback: cap)

        #expect (inserted == 30)
        #expect (buffer.lines.count == cap + buffer.rows)
        // The rows dropped are the OLDEST: what was inserted adjoins the previous top.
        #expect (text (terminal, 0) == "old 71")
        #expect (text (terminal, 29) == "old 100")
        #expect (text (terminal, 30) == "live 1")
        #expect (terminal.prependHistory (page ("older", 1...10), maxScrollback: cap) == 0)
        #expect (text (terminal, 0) == "old 71")
    }

    @Test("the alternate screen has no scrollback to extend")
    func alternateScreenIsNoOp () {
        let terminal = makeLive ()
        let normal = allLines (terminal)
        terminal.feed (text: "\u{1b}[?1049h")
        #expect (terminal.isCurrentBufferAlternate)

        #expect (terminal.prependHistory (page ("old", 1...10), maxScrollback: 1000) == 0)

        terminal.feed (text: "\u{1b}[?1049l")
        #expect (allLines (terminal) == normal)
    }

    @Test("styles and grapheme clusters render as if fed")
    func stylesAndGraphemes () {
        let terminal = makeLive (lines: 20)
        // Intern a different cluster here first, so the first cluster code of this
        // terminal and of a fresh scratch parser name different text.
        terminal.feed (text: "👨‍👩‍👧\r\n")
        let thumbs = "👍🏽"
        let bytes = ArraySlice ("\u{1b}[31mred\u{1b}[0m \(thumbs)\r\nplain".utf8)

        #expect (terminal.prependHistory (bytes, maxScrollback: 1000) == 2)

        let (reference, _) = TerminalTestHarness.makeTerminal (cols: 40, rows: 10)
        reference.feed (byteArray: Array (bytes))
        let line = terminal.normalBuffer.lines [0]
        let expected = reference.buffer.lines [0]
        #expect (line [0].attribute == expected [0].attribute)
        #expect (line [3].attribute == expected [3].attribute)
        #expect (line [0].attribute != line [3].attribute)
        // The cluster was interned by the scratch parser; it must read back here.
        #expect (text (terminal, 0) == "red \(thumbs)")
        #expect (text (terminal, 1) == "plain")
    }

    @Test("a selection keeps covering the same text")
    func selectionFollowsItsText () {
        let terminal = makeLive ()
        let selection = SelectionService (terminal: terminal)
        selection.setSelection (start: Position (col: 0, row: 5), end: Position (col: 3, row: 6))
        let selected = selection.getSelectedText ()

        let inserted = terminal.prependHistory (page ("old", 1...40), maxScrollback: 1000)
        selection.shiftRows (by: inserted)

        #expect (selection.start == Position (col: 0, row: 45))
        #expect (selection.getSelectedText () == selected)
    }
}
