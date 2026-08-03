import XCTest
@testable import HerdrKit

final class TerminalWrapTests: XCTestCase {

    /// The load-bearing invariant: folding never invents or destroys content.
    ///
    /// Compared with whitespace stripped, because a fold legitimately consumes
    /// the space it breaks at and legitimately drops leading space on a
    /// continuation line. Everything that is not whitespace must survive, in
    /// order. This is the property that makes the rest of the wrap safe to
    /// trust — a wrap that silently eats a character is invisible against a wall
    /// of log output and corrupts exactly the thing the user came to read.
    private func assertLossless(
        _ input: String, width: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let folded = TerminalWrap.fold(line: input, width: width)
        let strip = { (s: String) in s.filter { !$0.isWhitespace } }
        XCTAssertEqual(strip(folded.lines.joined()), strip(input),
                       "content changed while folding at width \(width)", file: file, line: line)
    }

    // MARK: - losslessness

    func testFoldingNeverLosesContent() {
        let cases = [
            "the quick brown fox jumps over the lazy dog",
            "/Users/herdrbuild/herdr-ios/Sources/HerdrKit/SessionRecovery.swift:418:29",
            "Executed 161 tests, with 2 tests skipped and 0 failures (0 unexpected)",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "short",
            "a b c d e f g h i j k l m n o p q r s t u v w x y z",
            "  indented output with a trailing space ",
            "tabs\tbetween\twords",
            "mixed 🙂 graphemes é and ﬁ ligatures",
        ]
        // COUNT WHAT WAS ACTUALLY EXERCISED. Written as a bare loop, this test
        // SURVIVED having its case list emptied — zero iterations, zero
        // assertions, green. A property test that asserts nothing is worse than
        // no property test, because it reads in the diff as thorough coverage.
        //
        // Counting FOLDS rather than iterations is the stronger check: it proves
        // the inputs were wide enough to make the wrap do work, not merely that
        // the function was called on strings that already fit.
        var foldsProducingMultipleLines = 0
        for input in cases {
            for width in [1, 2, 3, 7, 12, 40, 200] {
                assertLossless(input, width: width)
                if TerminalWrap.fold(line: input, width: width).lines.count > 1 {
                    foldsProducingMultipleLines += 1
                }
            }
        }
        XCTAssertGreaterThan(cases.count, 0, "no inputs; every assertion above was skipped")
        XCTAssertGreaterThan(foldsProducingMultipleLines, 20,
                             "the inputs barely folded; losslessness was proven mostly against "
                             + "strings that already fit, which is not the property under test")
    }

    // MARK: - termination

    /// AXIS: a token far wider than the line cannot spin the loop.
    ///
    /// The dangerous shape is "flush the line and retry the token", which makes
    /// no progress when the token never fits. Width 1 is the sharpest case.
    func testATokenWiderThanTheLineTerminatesAndBreaks() {
        let long = String(repeating: "x", count: 500)
        let folded = TerminalWrap.fold(line: long, width: 1)
        XCTAssertEqual(folded.lines.count, 500, "width-1 fold did not produce one column per character")
        XCTAssertTrue(folded.hardBroke, "a mid-token break was not reported")
        XCTAssertEqual(folded.lines.joined(), long, "characters were lost or reordered")
    }

    /// Multi-scalar graphemes are indivisible, so at width 1 a line MAY exceed
    /// the width. That is the one named exception, and it must be a deliberate
    /// overflow rather than a stall or a dropped character.
    func testAnIndivisibleGraphemeOverflowsRatherThanStalling() {
        let flags = "🇬🇧🇯🇵🇮🇹"
        let folded = TerminalWrap.fold(line: flags, width: 1)
        XCTAssertEqual(folded.lines.count, 3, "one grapheme per line was not produced")
        XCTAssertEqual(folded.lines.joined(), flags, "a grapheme was split or lost")
    }

    // MARK: - width discipline

    /// AXIS: no line exceeds the width, given content that can fit.
    ///
    /// The premise matters: every token here is shorter than the width, so any
    /// overflow is the folder's fault and not an indivisible token.
    func testNoLineExceedsTheWidthWhenEveryTokenFits() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        let width = 12
        XCTAssertTrue(text.split(separator: " ").allSatisfy { $0.count <= width },
                      "a token is wider than the width; an overflow below would not be the folder's fault")

        let folded = TerminalWrap.fold(line: text, width: width)
        for line in folded.lines {
            XCTAssertLessThanOrEqual(line.count, width, "line '\(line)' exceeds width \(width)")
        }
        XCTAssertFalse(folded.hardBroke, "a mid-token break was reported where every token fits")
    }

    func testBreaksHappenAtSpacesWhenPossible() {
        let folded = TerminalWrap.fold(line: "alpha beta gamma", width: 11)
        XCTAssertEqual(folded.lines, ["alpha beta", "gamma"])
    }

    // MARK: - blank lines

    /// AXIS: a blank line folds to exactly one blank line.
    ///
    /// Returning [] would shorten the output and close up the paragraph breaks
    /// that make agent output readable.
    func testABlankLineSurvivesAsOneBlankLine() {
        XCTAssertEqual(TerminalWrap.fold(line: "", width: 40).lines, [""])
        let folded = TerminalWrap.fold(["a", "", "b"], width: 40)
        XCTAssertEqual(folded.map(\.lines), [["a"], [""], ["b"]],
                       "a blank line between two lines was dropped or merged")
    }

    // MARK: - the fail-closed width case

    /// AXIS: a non-positive width returns the input UNFOLDED, not empty.
    ///
    /// Width 0 is a caller bug — an unmeasured layout — not a statement about
    /// the data. Returning [] would delete the user's terminal output silently
    /// in service of a layout mistake. An unfolded line is visibly wrong and
    /// recovers on the next layout pass; lost output does not.
    func testANonPositiveWidthReturnsInputUnfoldedRatherThanEmpty() {
        let input = ["first line", "second line"]
        for width in [0, -1, -80] {
            let folded = TerminalWrap.fold(input, width: width)
            XCTAssertEqual(folded.map(\.lines), [["first line"], ["second line"]],
                           "width \(width) did not return the input unfolded")
            XCTAssertFalse(folded.contains { $0.hardBroke })
        }
    }

    // MARK: - interior spacing

    /// AXIS: interior whitespace runs survive a fold that does not break there.
    ///
    /// Column alignment in terminal output — tables, tree output, diff gutters —
    /// is made of exactly these runs. Collapsing them turns aligned output into
    /// prose, which is a silent corruption of meaning rather than of characters.
    func testInteriorSpacingIsPreservedWhenTheLineFits() {
        let aligned = "name    status    age"
        let folded = TerminalWrap.fold(line: aligned, width: 80)
        XCTAssertEqual(folded.lines, [aligned], "interior spacing was collapsed")
    }

    func testTokeniseAlternatesWordsAndWhitespaceRuns() {
        XCTAssertEqual(TerminalWrap.tokenise("ab  cd"), ["ab", "  ", "cd"])
        XCTAssertEqual(TerminalWrap.tokenise("  lead"), ["  ", "lead"])
        XCTAssertEqual(TerminalWrap.tokenise(""), [])
    }

    // MARK: - realistic input

    /// A real herdr pane line at a real phone width, end to end.
    func testARealLogLineFoldsSensibly() {
        let line = "Test Case '-[HerdrKitTests.AgentListTests testAnAbsentStatusSurfaces]' passed (0.001 seconds)"
        let folded = TerminalWrap.fold(line: line, width: 38)

        XCTAssertGreaterThan(folded.lines.count, 1, "the premise: this line must actually need folding")
        for l in folded.lines where l.count > 38 {
            XCTAssertTrue(folded.hardBroke, "line '\(l)' overflows but no hard break was reported")
        }
        let strip = { (s: String) in s.filter { !$0.isWhitespace } }
        XCTAssertEqual(strip(folded.lines.joined()), strip(line))
    }
}
