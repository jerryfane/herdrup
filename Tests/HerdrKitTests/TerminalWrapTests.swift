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

        // CANARY. This helper is called from several tests, so if its comparison
        // were degenerate — both sides normalising to "" — every caller would
        // pass and the suite would report thorough coverage of nothing. A
        // reviewer probe confirmed that exact mutation survived. These two lines
        // make the helper prove it can still tell content apart before it is
        // trusted to say two things are equal.
        XCTAssertEqual(strip("a b\tc"), "abc", "the normaliser is not preserving content")
        XCTAssertNotEqual(strip("abc"), strip("abd"), "the normaliser cannot distinguish content")

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
        XCTAssertFalse(text.isEmpty, "empty text; every assertion below is vacuous")
        XCTAssertTrue(text.split(separator: " ").allSatisfy { $0.count <= width },
                      "a token is wider than the width; an overflow below would not be the folder's fault")

        let folded = TerminalWrap.fold(line: text, width: width)
        XCTAssertGreaterThan(folded.lines.count, 1,
                             "the text did not fold; a width check over one line proves nothing")
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
        var widthsChecked = 0
        for width in [0, -1, -80] {
            widthsChecked += 1
            let folded = TerminalWrap.fold(input, width: width)
            XCTAssertEqual(folded.map(\.lines), [["first line"], ["second line"]],
                           "width \(width) did not return the input unfolded")
            XCTAssertFalse(folded.contains { $0.hardBroke })
        }
        XCTAssertEqual(widthsChecked, 3, "the width loop did not run; nothing above was asserted")
    }

    // MARK: - interior spacing

    /// AXIS: interior whitespace runs survive a fold that does not break there.
    ///
    /// Column alignment in terminal output — tables, tree output, diff gutters —
    /// is made of exactly these runs. Collapsing them turns aligned output into
    /// prose, which is a silent corruption of meaning rather than of characters.
    func testInteriorSpacingIsPreservedWhenTheLineFits() {
        let aligned = "name    status    age"
        XCTAssertTrue(aligned.contains("  "),
                      "the fixture has no interior run to preserve; this test is about nothing")
        let folded = TerminalWrap.fold(line: aligned, width: 80)
        XCTAssertEqual(folded.lines, [aligned], "interior spacing was collapsed")
    }

    // MARK: - the two round-one defects

    /// AXIS: leading indentation is CONTENT and survives a fold that does not
    /// even happen.
    ///
    /// The first version skipped any whitespace token at column zero, so
    /// `fold("    child", width: 80)` returned `"child"` — indentation deleted
    /// with no fold occurring. Code, tree output, YAML and stack traces are all
    /// structured by exactly that indentation. The comment then sitting at the
    /// defect claimed tokenise folded leading spaces into the first word, which
    /// it never did: prose describing a behaviour the code did not have.
    func testLeadingIndentationIsPreserved() {
        XCTAssertEqual(TerminalWrap.fold(line: "    child", width: 80).lines, ["    child"],
                       "leading indentation was deleted")
        XCTAssertEqual(TerminalWrap.fold(line: "\tdeeper", width: 80).lines, ["\tdeeper"],
                       "a leading tab was deleted")

        // And it must survive a real fold, not just the no-fold case.
        let folded = TerminalWrap.fold(line: "    alpha beta gamma", width: 12)
        XCTAssertGreaterThan(folded.lines.count, 1, "the premise: this must actually fold")
        XCTAssertTrue(folded.lines[0].hasPrefix("    "),
                      "indentation was lost on a line that folded")
    }

    /// AXIS: leading indentation survives even when the first word cannot join
    /// it — the NARROW-WIDTH case the first indentation fix missed.
    ///
    /// fold("    child", width: 6) stored the indent, then flushed it alone when
    /// "child" would not fit beside it, and flush() stripped the indent to an
    /// empty line. The losslessness helper is blind to this by construction (it
    /// strips whitespace), so it took a reviewer's compiled probe. This is the
    /// same class as the original width-80 defect, one width narrower — I fixed
    /// the instance and not the class the first time.
    func testLeadingIndentationSurvivesWhenTheFirstWordCannotJoinIt() {
        let folded = TerminalWrap.fold(line: "    child", width: 6)
        XCTAssertEqual(folded.lines.first, "    ",
                       "the leading indent was stripped when flushed alone at a narrow width")
        XCTAssertEqual(folded.lines.joined(), "    child", "content changed")
    }

    /// AXIS: leading indentation WIDER THAN THE SCREEN is split to width, not
    /// emitted as one over-width line.
    ///
    /// The fast path stored the whole indent token and bypassed the oversized
    /// splitter: ten leading spaces at width 6 produced a ten-cell line.
    /// Whitespace is divisible, so it must fold like any oversized token — only
    /// an indivisible glyph (a tab) may overflow.
    func testOversizedLeadingIndentIsSplitToWidth() {
        let input = "          child"  // 10 spaces
        let width = 6
        // PRECONDITION: the leading run must actually exceed width, or the
        // oversized branch is never taken and this test proves nothing.
        let leadingRun = input.prefix { $0 == " " }
        XCTAssertGreaterThan(leadingRun.count, width,
                             "the fixture's indent does not exceed width; the test is vacuous")

        let folded = TerminalWrap.fold(line: input, width: width)
        for l in folded.lines {
            XCTAssertLessThanOrEqual(TerminalWrap.columns(of: l, startingAt: 0), width,
                                     "line '\(l)' exceeds width \(width)")
        }
        // EXACT join, not whitespace-stripped. The earlier version stripped
        // whitespace before comparing to "child", so deleting the entire indent
        // — in the fixture OR in production — produced the same observable and
        // survived. The split lines must rejoin to the original byte-for-byte.
        XCTAssertEqual(folded.lines.joined(), input,
                       "joined output does not equal the input exactly; indentation was lost or altered")
    }

    /// AXIS: the flag-clear half of the indentation fix is guarded.
    ///
    /// Deleting `currentIsLeadingIndent = false` (set when a word joins the
    /// indent) built green against all prior tests — an unguarded fix, exactly
    /// the revert-mutation I am meant to run on my own work. With it deleted,
    /// `fold("    a b c", width: 6)` keeps the fold-point space as "    a ".
    func testFoldPointSpaceIsDroppedAfterIndentJoinsAWord() {
        XCTAssertEqual(TerminalWrap.fold(line: "    a b c", width: 6).lines, ["    a", "b c"],
                       "a fold-point space survived after the indent joined a word")
    }

    /// A continuation line's leading space IS an artefact and is still dropped.
    /// Without this the fix above would over-correct into padding every folded
    /// line with the space it broke at.
    func testContinuationLinesDoNotInheritABreakSpace() {
        let folded = TerminalWrap.fold(line: "alpha beta gamma", width: 11)
        XCTAssertEqual(folded.lines, ["alpha beta", "gamma"],
                       "a continuation line kept the space the fold broke at")
    }

    /// AXIS: width is counted in TERMINAL CELLS, not Swift Characters.
    ///
    /// A reviewer probe folded three double-width CJK glyphs at width 4 and got
    /// one six-column line, because `String.count` said 3. A function whose
    /// purpose is fitting text to a terminal width cannot measure in a unit the
    /// terminal does not use.
    func testDoubleWidthGlyphsAreCountedAsTwoColumns() {
        XCTAssertEqual(TerminalWrap.columns(of: "界", at: 0), 2, "a CJK glyph measured as one column")
        XCTAssertEqual(TerminalWrap.columns(of: "a", at: 0), 1)

        let folded = TerminalWrap.fold(line: "界界界", width: 4)
        XCTAssertEqual(folded.lines, ["界界", "界"],
                       "three double-width glyphs did not fold at four columns")
    }

    /// AXIS: double-width EMOJI outside the CJK planes count as two cells.
    ///
    /// The first width table hand-listed 0x1F300+ and measured ✅ (U+2705),
    /// ⌚ (U+231A) and the keycap 1️⃣ as one cell — a reviewer probe folded
    /// ✅✅✅ into a single line at width 4. Deferring to Unicode.Scalar
    /// .Properties (isEmojiPresentation, plus the VS16 in a keycap) is the
    /// "complete table" answer rather than widening a hand-list, which is the
    /// fix-the-class move I keep failing to make on the first pass.
    func testBmpEmojiAreCountedAsTwoColumns() {
        XCTAssertEqual(TerminalWrap.columns(of: "✅", at: 0), 2, "U+2705 measured as one cell")
        XCTAssertEqual(TerminalWrap.columns(of: "⌚", at: 0), 2, "U+231A measured as one cell")
        XCTAssertEqual(TerminalWrap.columns(of: "1️⃣", at: 0), 2, "a keycap (VS16) measured as one cell")

        let folded = TerminalWrap.fold(line: "✅✅✅", width: 4)
        XCTAssertEqual(folded.lines, ["✅✅", "✅"],
                       "three double-width emoji did not fold at four columns")
    }

    /// A text-default symbol WITHOUT emoji presentation stays one cell — the
    /// negative half, so the fix does not just call everything wide.
    func testTextDefaultSymbolsStayOneColumn() {
        XCTAssertEqual(TerminalWrap.columns(of: "a", at: 0), 1)
        XCTAssertEqual(TerminalWrap.columns(of: "±", at: 0), 1, "a plain sign was widened")
    }

    /// A tab advances to the next multiple of 8, so its width depends on where
    /// it sits. Counting it as one character makes every column figure after it
    /// wrong.
    func testATabAdvancesToTheNextEightColumnStop() {
        XCTAssertEqual(TerminalWrap.columns(of: "\t", at: 0), 8)
        XCTAssertEqual(TerminalWrap.columns(of: "\t", at: 5), 3)
        XCTAssertEqual(TerminalWrap.columns(of: "\t", at: 8), 8)
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
