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

    // MARK: - terminal columns

    /// Columns one character occupies in a terminal, at column `col`.
    ///
    /// WIDTH IS MEASURED IN TERMINAL CELLS, NOT SWIFT CHARACTERS. The first
    /// version of this file counted `String.count`, and a reviewer's probe
    /// folded `界界界` at width 4 into a single SIX-column line. A function whose
    /// entire purpose is fitting text to a phone's terminal width cannot
    /// measure in a unit the terminal does not use.
    ///
    /// This is an approximation of `wcwidth`, not a port of it — full fidelity
    /// needs the Unicode East Asian Width table. It covers the ranges that
    /// actually appear in agent output: CJK, Hangul, fullwidth forms and emoji.
    /// Stated as an approximation because a caller relying on exactness for,
    /// say, box-drawing alignment deserves to know it is not guaranteed.
    static func columns(of ch: Character, at col: Int) -> Int {
        // A tab advances to the next multiple of 8. It is the only character
        // whose width depends on where it sits, which is why every width
        // calculation here threads a starting column rather than summing
        // per-character widths in isolation.
        if ch == "\t" { return 8 - (col % 8) }

        guard let scalar = ch.unicodeScalars.first else { return 0 }
        let v = scalar.value

        // Control characters occupy no cells.
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }

        // EMOJI PRESENTATION IS ASKED OF THE STDLIB, NOT GUESSED WITH RANGES.
        // The first version hand-listed 0x1F300+ and missed every double-width
        // BMP emoji: a reviewer probe measured ✅ (U+2705), ⌚ (U+231A) and the
        // keycap 1️⃣ as ONE cell. wcwidth reports them as two. Rather than widen
        // a hand-list — which is the "fixed the instances, not the class" error
        // I keep making — this defers to Unicode.Scalar.Properties, which IS the
        // table:
        //   - a Variation-Selector-16 (U+FE0F) anywhere in the grapheme forces
        //     emoji (wide) presentation, which is exactly what 1️⃣ = 1 + FE0F +
        //     20E3 relies on;
        //   - isEmojiPresentation is true for scalars that default to the wide
        //     emoji glyph (✅, ⌚) and false for text-default symbols (☀ without
        //     FE0F), which is the precise distinction wcwidth makes.
        if ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        if scalar.properties.isEmojiPresentation { return 2 }

        // East Asian Wide / Fullwidth. The stdlib exposes emoji properties but
        // NOT East Asian Width, so these ranges remain hand-maintained — they
        // are stable Unicode blocks, unlike the sprawling emoji assignments the
        // property query above now covers.
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F,    // Hangul Jamo
            0x2E80...0x303E,    // CJK radicals, Kangxi
            0x3041...0x33FF,    // Hiragana, Katakana, CJK compatibility
            0x3400...0x4DBF,    // CJK Extension A
            0x4E00...0x9FFF,    // CJK Unified Ideographs
            0xA000...0xA4CF,    // Yi
            0xAC00...0xD7A3,    // Hangul syllables
            0xF900...0xFAFF,    // CJK compatibility ideographs
            0xFE30...0xFE6F,    // CJK compatibility forms
            0xFF00...0xFF60,    // Fullwidth forms
            0xFFE0...0xFFE6,
            0x20000...0x3FFFD,  // CJK Extension B+
        ]
        if wide.contains(where: { $0.contains(v) }) { return 2 }

        // A grapheme built from regional indicators — a flag — renders as one
        // double-width glyph even though its first scalar is not wide alone.
        if ch.unicodeScalars.count > 1,
           ch.unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            return 2
        }
        return 1
    }

    /// Columns a string occupies, starting from column `start`.
    static func columns(of s: some StringProtocol, startingAt start: Int = 0) -> Int {
        var col = start
        for ch in s { col += columns(of: ch, at: col) }
        return col - start
    }

    /// Takes the longest prefix of `s` fitting `width` columns from column 0.
    ///
    /// Always takes at least one Character when `s` is non-empty and
    /// `width > 0`, so a caller looping on the remainder always makes progress —
    /// including a double-width glyph at width 1, which OVERFLOWS rather than
    /// stalling. That is the one named exception to the width rule.
    static func prefixFitting(_ s: Substring, width: Int) -> Substring {
        var col = 0
        var end = s.startIndex
        while end < s.endIndex {
            let w = columns(of: s[end], at: col)
            if col + w > width && end != s.startIndex { break }
            col += w
            end = s.index(after: end)
            if col >= width { break }
        }
        return s[s.startIndex..<end]
    }

    // MARK: - folding

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
        var currentCols = 0
        var hardBroke = false
        // True only while `current` holds the ORIGINAL leading indentation of the
        // logical line and nothing else. That indentation is content; the trailing
        // whitespace flush() strips at every OTHER fold point is an artefact. The
        // two look identical (a buffer ending in spaces) and must not be treated
        // alike — conflating them is exactly the defect below.
        var currentIsLeadingIndent = false

        /// Emits `current` and resets.
        ///
        /// TRAILING WHITESPACE IS TRIMMED HERE — EXCEPT when the buffer is the
        /// logical line's leading indentation. flush() is called at fold points,
        /// where a trailing space is one the fold created; but a narrow width can
        /// force a flush while `current` still holds ONLY the leading indent (the
        /// first word could not join it), and stripping there deleted the
        /// indentation. fold("    child", width: 6) returned "child": a compiled
        /// regression the losslessness helper cannot see, because it strips
        /// whitespace by design. The indent is preserved as its own line instead.
        func flush() {
            if !currentIsLeadingIndent {
                while let last = current.last, last.isWhitespace { current.removeLast() }
            }
            out.append(current)
            current = ""
            currentCols = 0
            currentIsLeadingIndent = false
        }

        for (index, token) in tokenise(line).enumerated() {
            let isWhitespaceToken = token.allSatisfy(\.isWhitespace)

            // LEADING INDENTATION IS CONTENT AND SURVIVES.
            //
            // This branch is the fix for a real defect: the first version
            // skipped ANY whitespace token found at column zero, so
            // fold("    child", width: 80) returned "child" — indentation
            // deleted with no fold even occurring. Code, tree output, YAML and
            // stack traces are all structured by exactly that indentation, and
            // the comment sitting here previously claimed tokenise folded it
            // into the first word, which it never did.
            //
            // `index == 0` is what distinguishes the true start of a LOGICAL
            // line from a continuation the fold created. Only the latter's
            // leading space is an artefact.
            if index == 0 && isWhitespaceToken {
                current = token
                currentCols = columns(of: token, startingAt: 0)
                currentIsLeadingIndent = true
                continue
            }

            let tokenCols = columns(of: token, startingAt: currentCols)

            // A token that cannot fit ANY line must be split, whatever the
            // current state. Placing it whole would overflow; flushing and
            // retrying would spin forever on a token that never fits.
            if columns(of: token, startingAt: 0) > width {
                if !current.isEmpty { flush() }
                var rest = Substring(token)
                while !rest.isEmpty {
                    let chunk = prefixFitting(rest, width: width)
                    rest = rest[chunk.endIndex...]
                    if rest.isEmpty {
                        current = String(chunk)
                        currentCols = columns(of: chunk, startingAt: 0)
                    } else {
                        out.append(String(chunk))
                        hardBroke = true
                    }
                }
                continue
            }

            if current.isEmpty {
                // Leading whitespace on a CONTINUATION line is dropped: that
                // one is an artefact of the fold. See index == 0 above.
                if isWhitespaceToken { continue }
                current = token
                currentCols = tokenCols
            } else if currentCols + tokenCols <= width {
                current += token
                currentCols += tokenCols
                // Once anything joins the indent, `current` is no longer pure
                // leading indentation, so a later flush must resume trimming its
                // trailing whitespace as an artefact. Without this,
                // "    a b c" at a narrow width preserves the fold-point space.
                currentIsLeadingIndent = false
            } else {
                flush()
                if isWhitespaceToken { continue }
                current = token
                currentCols = columns(of: token, startingAt: 0)
            }
        }

        if !current.isEmpty || out.isEmpty { out.append(current) }
        return Folded(lines: out, hardBroke: hardBroke)
    }

    /// Splits a line into alternating word and whitespace runs, preserving both.
    ///
    /// Whitespace is kept as its own token rather than discarded, so interior
    /// spacing survives a fold that does not break there. Column alignment in
    /// terminal output — tables, tree output, diff gutters — is made of exactly
    /// those runs, and eating them turns aligned output into prose.
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
