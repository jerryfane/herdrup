import Foundation

/// Folds unwrapped terminal output to a narrow display width.
///
/// The pane this text came from is sized for a desktop — commonly 120 columns —
/// and the phone cannot change that: `pane.resize` grows a pane against its
/// neighbours in the DESKTOP layout, so there is no "make this pane 40 columns"
/// without disturbing the machine the user is sitting at. `ReadSource
/// .recentUnwrapped` is the way out. herdr returns logical lines with no hard
/// wrapping, and the client folds them to whatever width it actually has.
///
/// This is a pure function over strings: no I/O, no UIKit, and fully exercised
/// by the Linux test suite.
public enum TerminalWrap {

    /// The result of folding one logical line.
    public struct Folded: Equatable, Sendable {
        /// Display lines, in order. Never empty — a blank input line folds to
        /// one blank output line, because terminal output uses blank lines
        /// structurally and collapsing them reflows meaning.
        public let lines: [String]
        /// True when at least one break was forced mid-token because the token
        /// could not fit the width. Surfaced rather than hidden: it is the
        /// signal that the width is too narrow for the content, and a caller
        /// showing a "content is wider than the screen" affordance needs it.
        public let hardBroke: Bool
    }

    /// Folds `lines` to `width` columns.
    ///
    /// NON-POSITIVE WIDTH RETURNS THE INPUT UNFOLDED, deliberately. A width of
    /// zero or less is a caller bug — a layout that has not measured yet, a
    /// misplaced inset — not a statement about the data. The tempting responses
    /// are to return `[]` or to trap; both destroy the user's terminal output in
    /// service of a layout mistake, and the empty case does it silently. An
    /// unfolded line is visibly wrong and recoverable on the next layout pass.
    /// Losing output is neither.
    public static func fold(_ lines: [String], width: Int) -> [Folded] {
        guard width > 0 else {
            return lines.map { Folded(lines: [$0], hardBroke: false) }
        }
        return lines.map { fold(line: $0, width: width) }
    }

    static func fold(line: String, width: Int) -> Folded {
        // A BLANK LINE IS ONE BLANK LINE, not zero. Returning [] here would make
        // the output shorter than the input and quietly close up the paragraph
        // breaks that make agent output readable.
        guard !line.isEmpty else { return Folded(lines: [""], hardBroke: false) }

        var out: [String] = []
        var current = ""
        var currentCount = 0
        var hardBroke = false

        /// Emits `current` and resets. Kept as one operation so no path can
        /// append without also clearing the counter.
        ///
        /// TRAILING WHITESPACE IS TRIMMED HERE AND NOWHERE ELSE. flush() is
        /// called only at fold points — where the next token did not fit — so
        /// the space being removed is one the fold created, exactly like the
        /// leading space dropped from a continuation line. Symmetry matters:
        /// keeping it produced lines that were visually short of the width by an
        /// invisible character. The FINAL line does not go through flush(), so a
        /// line genuinely ending in spaces keeps them; that is content, not an
        /// artefact, and the two cases must not be conflated.
        func flush() {
            while let last = current.last, last.isWhitespace { current.removeLast() }
            out.append(current)
            current = ""
            currentCount = 0
        }

        for token in tokenise(line) {
            let tokenCount = token.count

            // A token that cannot fit ANY line must be split, whatever the
            // current state. Trying to place it whole would either overflow the
            // width or, if the loop instead flushed and retried, spin forever on
            // a token that never fits.
            if tokenCount > width {
                if currentCount > 0 { flush() }
                var rest = Substring(token)
                while !rest.isEmpty {
                    // TERMINATION. `width` is > 0 here, so `prefix(width)` takes
                    // at least one Character on every pass and `rest` strictly
                    // shrinks. There is no input for which this does not finish,
                    // including width 1 against a multi-scalar grapheme — Swift
                    // Characters are indivisible, so one is taken and the line
                    // exceeds the width rather than the loop stalling.
                    let chunk = rest.prefix(width)
                    rest = rest.dropFirst(chunk.count)
                    if rest.isEmpty {
                        current = String(chunk)
                        currentCount = chunk.count
                    } else {
                        out.append(String(chunk))
                        hardBroke = true
                    }
                }
                continue
            }

            if currentCount == 0 {
                // Leading whitespace on a fresh line is dropped: it is an
                // artefact of the fold, not content. A run of spaces at the
                // START of a logical line is preserved by tokenise, which emits
                // it as part of the first token.
                if token.allSatisfy(\.isWhitespace) { continue }
                current = token
                currentCount = tokenCount
            } else if currentCount + tokenCount <= width {
                current += token
                currentCount += tokenCount
            } else {
                flush()
                if token.allSatisfy(\.isWhitespace) { continue }
                current = token
                currentCount = tokenCount
            }
        }

        if currentCount > 0 || out.isEmpty { out.append(current) }
        return Folded(lines: out, hardBroke: hardBroke)
    }

    /// Splits a line into alternating word and whitespace runs, preserving both.
    ///
    /// Whitespace is kept as its own token rather than discarded, so interior
    /// spacing survives a fold that does not happen to break there. Column
    /// alignment in terminal output — tables, tree output, diff gutters — is
    /// made of exactly those runs, and eating them turns aligned output into
    /// prose.
    static func tokenise(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?

        for ch in line {
            let isSpace = ch.isWhitespace
            if currentIsSpace == nil || isSpace == currentIsSpace {
                current.append(ch)
                currentIsSpace = isSpace
            } else {
                tokens.append(current)
                current = String(ch)
                currentIsSpace = isSpace
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
