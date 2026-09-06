#if canImport(UIKit) && (os(iOS) || os(visionOS))
import UIKit
import XCTest
@testable import SwiftTerm

/// These exercise the view/font path, where an implicit soft reset used to erase
/// modes even when the emulator's grid did not change. Core resize tests alone
/// cannot catch that regression.
@MainActor
final class TerminalViewGeometryTests: XCTestCase {
    private let escape = "\u{1b}"

    private func makeView() -> TerminalView {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        view.sizeChangeRequestHandler = { _, _ in }
        view.applyTerminalSize(cols: 80, rows: 24)
        return view
    }

    private func installSessionState(in view: TerminalView) -> [Color] {
        let palette = (0..<16).map { index in
            Color(red: UInt16(0x1234 + index), green: 0x5678, blue: 0x9abc)
        }
        view.installColors(palette)
        // Include a running program's OSC override, not only the host palette.
        view.feed(text: "\(escape)]4;2;rgb:abcd/1234/5678\u{7}")
        view.feed(text: "\(escape)[4;20r\(escape)[?6h\(escape)[?1h\(escape)[?2004h")
        return Array(view.getTerminal().ansiColors.prefix(16))
    }

    private func assertSessionState(
        _ view: TerminalView, palette: [Color], file: StaticString = #filePath, line: UInt = #line
    ) {
        let terminal = view.getTerminal()
        XCTAssertTrue(terminal.bracketedPasteMode, "bracketed paste was reset", file: file, line: line)
        XCTAssertTrue(terminal.applicationCursor, "application cursor mode was reset", file: file, line: line)
        XCTAssertTrue(terminal.originMode, "origin mode was reset", file: file, line: line)
        XCTAssertEqual(Array(terminal.ansiColors.prefix(16)), palette, "ANSI palette was reset", file: file, line: line)
    }

    func testManagedLayoutDefersGridAndContentChangesUntilAuthoritativeCommit() throws {
        let view = makeView()
        let terminal = view.getTerminal()
        view.feed(text: "\(escape)[1;80HZ")
        var proposal: (cols: Int, rows: Int)?
        view.sizeChangeRequestHandler = { proposal = ($0, $1) }

        view.frame.size = CGSize(
            width: view.cellDimension.width * 120.25,
            height: view.cellDimension.height * 30.25
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let requested = try XCTUnwrap(proposal)
        XCTAssertEqual(requested.cols, 120)
        XCTAssertEqual(requested.rows, 30)
        XCTAssertEqual(terminal.cols, 80, "a proposal must not reinterpret incoming old-grid bytes")
        XCTAssertEqual(terminal.rows, 24)
        XCTAssertEqual(terminal.getCharacter(col: 79, row: 0), Character("Z"))

        // The stream can acknowledge a wider co-viewer grid, not the local fit.
        view.applyTerminalSize(cols: 132, rows: 32)
        XCTAssertEqual(terminal.cols, 132)
        XCTAssertEqual(terminal.rows, 32)
        XCTAssertEqual(terminal.getCharacter(col: 79, row: 0), Character("Z"))
    }

    func testSameGridFontChangesPreserveScrollRegionAndSessionModes() {
        let view = makeView()
        let terminal = view.getTerminal()
        let palette = installSessionState(in: view)

        view.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        XCTAssertEqual(terminal.cols, 80)
        XCTAssertEqual(terminal.rows, 24)
        view.applyTerminalSize(cols: 80, rows: 24)
        assertSessionState(view, palette: palette)
        XCTAssertEqual(terminal.buffer.scrollTop, 3)
        XCTAssertEqual(terminal.buffer.scrollBottom, 19)

        let normal = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        view.setFonts(normal: normal, bold: bold, italic: normal, boldItalic: bold)
        view.applyTerminalSize(cols: 80, rows: 24)
        assertSessionState(view, palette: palette)
        XCTAssertEqual(terminal.buffer.scrollTop, 3)
        XCTAssertEqual(terminal.buffer.scrollBottom, 19)

        // Origin-relative positioning must still obey DECSTBM after both font APIs.
        view.feed(text: "\(escape)[1;1HM")
        XCTAssertEqual(terminal.getCharacter(col: 0, row: 3), Character("M"))
    }

    func testAuthoritativeAndPublicResizeRetainModesWithoutFreezingOldMargins() {
        let view = makeView()
        let terminal = view.getTerminal()
        let palette = installSessionState(in: view)

        view.applyTerminalSize(cols: 120, rows: 30)
        assertSessionState(view, palette: palette)
        XCTAssertEqual(terminal.cols, 120)
        XCTAssertEqual(terminal.rows, 30)
        // Actual dimension changes retain the core's existing margin reset policy.
        XCTAssertEqual(terminal.buffer.scrollTop, 0)
        XCTAssertEqual(terminal.buffer.scrollBottom, 29)

        view.resize(cols: 100, rows: 26)
        assertSessionState(view, palette: palette)
        XCTAssertEqual(terminal.cols, 100)
        XCTAssertEqual(terminal.rows, 26)
        XCTAssertEqual(terminal.buffer.scrollBottom, 25)
    }

    func testViewGeometryAndFontDoNotCompleteSynchronizedOutput() {
        let view = makeView()
        let terminal = view.getTerminal()
        var synchronizationChanges: [Bool] = []
        view.synchronizedOutputChangeHandler = { synchronizationChanges.append($0) }
        view.feed(text: "\(escape)[?2026h")
        defer { view.feed(text: "\(escape)[?2026l") }

        view.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        view.applyTerminalSize(cols: 80, rows: 24)
        XCTAssertTrue(terminal.synchronizedOutputActive)
        view.applyTerminalSize(cols: 120, rows: 30)
        view.feed(text: "incomplete redraw")
        XCTAssertTrue(terminal.synchronizedOutputActive, "grid commit must not expose a partial synchronized frame")
        view.resize(cols: 100, rows: 26)
        XCTAssertTrue(terminal.synchronizedOutputActive)
        XCTAssertEqual(synchronizationChanges, [true], "resize/font must not announce completion")

        view.feed(text: "\(escape)[?2026l")
        XCTAssertFalse(terminal.synchronizedOutputActive)
        XCTAssertEqual(synchronizationChanges, [true, false])
    }
}
#endif
