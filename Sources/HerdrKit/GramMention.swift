import Foundation

/// `@name` tagging in the Gram composer: typing `@` lists the agents, picking one puts
/// `@name ` into the text, and sending resolves the first known mention to the post's `to`.
/// A message with no known mention goes to the shared queue.
///
/// The rules, kept deliberately small:
/// - A mention starts with `@` at the start of the text or after whitespace (a space or a
///   newline), so `me@vetrina.dev` is never one.
/// - A known mention matches a bare agent name case-insensitively and ends at the end of
///   the text or at a character that cannot continue a name: `@vetrina,` and `@vetrina.`
///   are mentions, `@vetrina2`, `@vetrina-ops` and `@vetrina.dev` are not. Names may hold
///   `-`, `_` and `.` (`trend-scout`, `ci-watch`); the longest known name wins.
/// - Only the first known mention addresses the post. A leading one (nothing but whitespace
///   before it) is the address, so it and the one whitespace character after it leave the
///   body; a mention later in the text is part of the message and stays.
public enum GramMention {
    /// The `@token` being typed: the run before `cursor` (the end of the text when nil) back
    /// to an `@` at the start of the text or after whitespace. `query` is the token without
    /// the `@` (empty right after typing `@`); `range` covers the `@` and the token.
    /// Nil when the run holds no such `@`, so `me@host` and `a b` have no query.
    public static func activeQuery(
        in text: String, cursor: String.Index? = nil
    ) -> (range: Range<String.Index>, query: String)? {
        let end = cursor ?? text.endIndex
        var index = end
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isWhitespace { return nil }
            if character == "@" {
                guard previous == text.startIndex || text[text.index(before: previous)].isWhitespace else {
                    return nil
                }
                return (previous..<end, String(text[text.index(after: previous)..<end]))
            }
            index = previous
        }
        return nil
    }

    /// `text` with `range` (an `activeQuery` range) replaced by `@name `, keeping the text
    /// before and after it as it was.
    public static func complete(
        _ text: String, replacing range: Range<String.Index>, with name: String
    ) -> String {
        String(text[..<range.lowerBound]) + "@" + name + " " + String(text[range.upperBound...])
    }

    /// Who a composed message goes to and what it says. The first known mention gives the
    /// recipient, spelled as in `knownNames`; a leading one is stripped from the body with
    /// the whitespace character after it (and any whitespace before it). No known mention:
    /// the recipient is nil (the shared queue) and the body is `text` unchanged.
    public static func resolve(
        _ text: String, knownNames: [String]
    ) -> (recipient: String?, body: String) {
        guard let first = mentions(in: text, knownNames: knownNames).first else { return (nil, text) }
        guard text[..<first.range.lowerBound].allSatisfy(\.isWhitespace) else {
            return (first.name, text)
        }
        var bodyStart = first.range.upperBound
        if bodyStart < text.endIndex, text[bodyStart].isWhitespace {
            bodyStart = text.index(after: bodyStart)
        }
        return (first.name, String(text[bodyStart...]))
    }

    /// The ranges of every known mention in `text` (each from its `@` to the end of the
    /// name), in order, for highlighting.
    public static func ranges(in text: String, knownNames: [String]) -> [Range<String.Index>] {
        mentions(in: text, knownNames: knownNames).map(\.range)
    }

    private static func mentions(
        in text: String, knownNames: [String]
    ) -> [(range: Range<String.Index>, name: String)] {
        let names = knownNames.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !names.isEmpty else { return [] }
        var found: [(range: Range<String.Index>, name: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "@",
                  index == text.startIndex || text[text.index(before: index)].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let mentionStart = index
            let nameStart = text.index(after: mentionStart)
            index = nameStart
            for name in names {
                guard let nameEnd = text.index(nameStart, offsetBy: name.count, limitedBy: text.endIndex),
                      String(text[nameStart..<nameEnd]).caseInsensitiveCompare(name) == .orderedSame,
                      endsName(text, at: nameEnd) else { continue }
                found.append((mentionStart..<nameEnd, name))
                index = nameEnd
                break
            }
        }
        return found
    }

    /// Whether a name may end at `index`: the end of the text, or a character that cannot
    /// continue one. A `.` ends a name only when no letter or digit follows it, so the full
    /// stop in `@vetrina.` does and the domain in `@vetrina.dev` does not.
    private static func endsName(_ text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        if next == "." {
            let after = text.index(after: index)
            return after == text.endIndex || !continuesName(text[after])
        }
        return !continuesName(next)
    }

    private static func continuesName(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
