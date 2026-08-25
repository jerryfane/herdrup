import XCTest
@testable import HerdrKit

final class TerminalGraphicsFilterTests: XCTestCase {

    // MARK: byte helpers

    private let ESC: UInt8 = 0x1b
    private let BEL: UInt8 = 0x07
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private var ST: [UInt8] { [ESC, 0x5c] }                       // ESC \
    private func apcOpen() -> [UInt8] { [ESC, 0x5f] }             // ESC _
    private func dcsOpen() -> [UInt8] { [ESC, 0x50] }             // ESC P

    /// A realistic kitty graphics APC: `ESC _ G <control> ; <base64 payload> ESC \`.
    private func kitty(payload: Int) -> [UInt8] {
        var seq = apcOpen()
        seq += bytes("Gf=100,a=T,s=64,v=64;")
        seq += Array(repeating: UInt8(ascii: "Q"), count: payload)  // stand-in base64 body
        seq += ST
        return seq
    }

    /// Feed a whole byte array through a fresh filter in one chunk.
    private func filterWhole(_ input: [UInt8]) -> [UInt8] {
        var f = TerminalGraphicsFilter()
        return f.filter(input[...])
    }

    /// Feed `input` split at every boundary in `cuts`, concatenating the outputs —
    /// proves state carries across chunks.
    private func filterChunked(_ input: [UInt8], cuts: [Int]) -> [UInt8] {
        var f = TerminalGraphicsFilter()
        var out: [UInt8] = []
        var start = 0
        for cut in (cuts + [input.count]) {
            out += f.filter(input[start..<cut])
            start = cut
        }
        return out
    }

    // MARK: passthrough — nothing that is not a graphics string may change

    func testPlainTextUnchanged() {
        let input = bytes("hello world\r\n$ ls -la\r\n")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testCsiSgrUnchanged() {
        let input = bytes("\u{1b}[31mred\u{1b}[0m and \u{1b}[1;32mbold green\u{1b}[0m\r\n")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testOscTitleUnchanged_ST() {
        // OSC is used by SwiftTerm for the window title/colours — must pass through.
        let input: [UInt8] = [ESC, 0x5d] + bytes("0;my title") + ST + bytes("body")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testOscTitleUnchanged_BEL() {
        let input: [UInt8] = [ESC, 0x5d] + bytes("0;my title") + [BEL] + bytes("body")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testEscEscPreserved() {
        let input: [UInt8] = [ESC, ESC] + bytes("[0m") + bytes("x")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testLosslessForNonGraphicsByteByByte() {
        // Text + CSI + OSC fed one byte at a time must reassemble byte-identical
        // (ESC emission is deferred one chunk, but concatenation is unchanged).
        var input: [UInt8] = bytes("\u{1b}[2J\u{1b}[H")
        input += [ESC, 0x5d] + bytes("0;title") + [BEL]
        input += bytes("\u{1b}[38;5;213mcolour\u{1b}[0m\r\nplain\r\n")
        XCTAssertEqual(filterChunked(input, cuts: Array(1..<input.count)), input)
    }

    // MARK: APC / kitty — dropped

    func testKittyApcDropped_ST() {
        let input = bytes("before ") + kitty(payload: 500) + bytes(" after")
        XCTAssertEqual(filterWhole(input), bytes("before  after"))
    }

    func testApcDropped_BEL() {
        let input: [UInt8] = bytes("a") + apcOpen() + bytes("Gf=1;PAYLOAD") + [BEL] + bytes("b")
        XCTAssertEqual(filterWhole(input), bytes("ab"))
    }

    func testApcWithEmbeddedNonTerminatorEscDropped() {
        // An ESC inside the APC that is NOT a valid ST must not end the drop early.
        var apc: [UInt8] = apcOpen()
        apc += bytes("G;AA")
        apc += [ESC, 0x58]        // ESC X — not a valid ST
        apc += bytes("BB")
        apc += ST
        let input: [UInt8] = bytes("x") + apc + bytes("y")
        XCTAssertEqual(filterWhole(input), bytes("xy"))
    }

    func testKittyApcSplitAcrossChunks() {
        let input = bytes("L") + kitty(payload: 800) + bytes("R")
        // Cut mid-payload and again right between the ESC and the '\' of the ST.
        let mid = 1 + 6 + 300
        let escOfST = input.count - 1 - 1   // index of the ESC in the trailing ST
        XCTAssertEqual(filterChunked(input, cuts: [1, mid, escOfST, escOfST + 1]), bytes("LR"))
    }

    func testEscAtChunkBoundaryBeginsApc() {
        // Chunk 1 ends on a lone ESC that opens an APC in chunk 2.
        let input = bytes("A") + kitty(payload: 200) + bytes("B")
        XCTAssertEqual(filterChunked(input, cuts: [2]), bytes("AB"))  // cut right after the ESC of ESC_
    }

    func testMultipleKittyFramesWithText() {
        let input = bytes("row1\r\n") + kitty(payload: 300) + bytes("row2\r\n") + kitty(payload: 300) + bytes("row3")
        XCTAssertEqual(filterWhole(input), bytes("row1\r\nrow2\r\nrow3"))
    }

    // MARK: DCS — size-gated

    func testSmallDcsPassesVerbatim() {
        // DECRQSS-shaped small DCS: ESC P $ q m ESC \  — legit, must survive.
        let dcs = dcsOpen() + bytes("$qm") + ST
        let input = bytes("p") + dcs + bytes("q")
        XCTAssertEqual(filterWhole(input), input)
    }

    func testLargeDcsDropped() {
        var dcs = dcsOpen() + bytes("q")   // sixel-ish intro
        dcs += Array(repeating: UInt8(ascii: "#"), count: TerminalGraphicsFilter.dcsPassThroughLimit + 100)
        dcs += ST
        let input = bytes("[") + dcs + bytes("]")
        XCTAssertEqual(filterWhole(input), bytes("[]"))
    }

    func testLargeDcsSplitAcrossChunksDropped() {
        var dcs = dcsOpen() + bytes("q")
        dcs += Array(repeating: UInt8(ascii: "#"), count: TerminalGraphicsFilter.dcsPassThroughLimit * 2)
        dcs += ST
        let input = bytes("(") + dcs + bytes(")")
        let cuts = [1, 1 + 2000, 1 + 5000, input.count - 3]
        XCTAssertEqual(filterChunked(input, cuts: cuts), bytes("()"))
    }

    func testSmallDcsBoundaryAtLimitPasses() {
        // Exactly at the limit still passes (limit is inclusive).
        let bodyLen = TerminalGraphicsFilter.dcsPassThroughLimit - 2 /*ESC P*/ - 2 /*ESC \*/
        let dcs = dcsOpen() + Array(repeating: UInt8(ascii: "z"), count: bodyLen) + ST
        XCTAssertEqual(dcs.count, TerminalGraphicsFilter.dcsPassThroughLimit)
        XCTAssertEqual(filterWhole(dcs), dcs)
    }

    // MARK: reset

    func testResetAbandonsPartialSequence() {
        var f = TerminalGraphicsFilter()
        // Feed the opening of a kitty APC, then a keyframe reset, then plain text.
        _ = f.filter((apcOpen() + bytes("Gf=1;PARTIAL"))[...])
        f.reset()
        XCTAssertEqual(f.filter(bytes("clean")[...]), bytes("clean"))
    }
}
