import Foundation

/// One row of the transcript as search sees it: its id and its plain text.
public struct TranscriptSearchRow: Sendable, Equatable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// One match: where it is (row id plus the UTF-16 offset of its first character) and the
/// excerpt around it that the result list shows.
public struct TranscriptSearchHit: Sendable, Equatable, Identifiable {
    public let rowID: String
    /// UTF-16 offset of the match in the row's text. With the row id it names the match
    /// across refreshes: text appended to a row, or rows added after it, leave it unchanged.
    public let offset: Int
    public let excerpt: String
    public var id: String { "\(rowID):\(offset)" }

    public init(rowID: String, offset: Int, excerpt: String) {
        self.rowID = rowID
        self.offset = offset
        self.excerpt = excerpt
    }
}

/// The matches for one query over the whole transcript, at most `TranscriptSearch.matchCap`.
public struct TranscriptSearchResult: Sendable, Equatable {
    public var hits: [TranscriptSearchHit]
    /// More matches exist past `hits`: the counter reads "500+".
    public var capped: Bool

    public init(hits: [TranscriptSearchHit] = [], capped: Bool = false) {
        self.hits = hits
        self.capped = capped
    }

    public static let empty = TranscriptSearchResult()
}

/// The Chat's find-in-conversation: literal, case-insensitive (diacritics count), whole
/// characters only.
///
/// Every match covers whole characters (grapheme clusters) and the scan always moves past
/// the previous match, so a query that folds to part of a character ("👍" in "👍🏽", "s" in
/// "ß") cannot stall the loop or hand out an index inside a character. The scan carries its
/// UTF-16 offset forward instead of measuring each match from the start of the text, so a
/// row costs time in proportion to its length, and the whole search stops at a cap.
public enum TranscriptSearch {
    /// The most matches one search returns; a search with more reports `capped`.
    public static let matchCap = 500
    static let excerptBefore = 48
    static let excerptAfter = 80

    /// One match in a text: whole-character range and the UTF-16 offset where it starts.
    public struct Match: Equatable {
        public let range: Range<String.Index>
        public let utf16Offset: Int
    }

    /// Matches of `query` in `text`, in order, non-overlapping, at most `limit`.
    public static func matches(in text: String, query: String, limit: Int = .max) -> [Match] {
        guard !query.isEmpty, limit > 0 else { return [] }
        var result: [Match] = []
        let end = text.endIndex
        // Always on a character boundary; `cursorOffset` is its UTF-16 offset.
        var cursor = text.startIndex
        var cursorOffset = 0
        func move(to next: String.Index) {
            cursorOffset += text.utf16.distance(from: cursor, to: next)
            cursor = next
        }
        while cursor < end, result.count < limit,
              let found = text.range(of: query, options: .caseInsensitive, range: cursor..<end) {
            // Round the start down to the character that holds it.
            while cursor < end {
                let next = text.index(after: cursor)
                guard next <= found.lowerBound else { break }
                move(to: next)
            }
            guard cursor < end else { break }
            let lower = cursor
            let lowerOffset = cursorOffset
            // Round the end up to a whole character, and take at least one character, so an
            // empty or backward match still moves the scan on.
            repeat { move(to: text.index(after: cursor)) } while cursor < end && cursor < found.upperBound
            result.append(Match(range: lower..<cursor, utf16Offset: lowerOffset))
        }
        return result
    }

    /// The ranges of `matches(in:query:limit:)`; used to highlight an excerpt.
    public static func ranges(in text: String, query: String, limit: Int = .max) -> [Range<String.Index>] {
        matches(in: text, query: query, limit: limit).map(\.range)
    }

    /// The hits of one row, each with an excerpt of the text around it.
    public static func hits(rowID: String, text: String, query: String, limit: Int = .max) -> [TranscriptSearchHit] {
        matches(in: text, query: query, limit: limit).map { match in
            let start = text.index(match.range.lowerBound, offsetBy: -excerptBefore, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(match.range.upperBound, offsetBy: excerptAfter, limitedBy: text.endIndex) ?? text.endIndex
            return TranscriptSearchHit(rowID: rowID, offset: match.utf16Offset, excerpt: String(text[start..<end]))
        }
    }

    /// The hits over `rows` in order, at most `cap`. Rows are read lazily: once the cap is
    /// passed the rest of the sequence is never produced.
    public static func search<Rows: Sequence>(_ rows: Rows, query: String, cap: Int = matchCap) -> TranscriptSearchResult
    where Rows.Element == TranscriptSearchRow {
        guard !query.isEmpty, cap > 0 else { return .empty }
        var hits: [TranscriptSearchHit] = []
        var rowIterator = rows.makeIterator()
        // One past the cap, to know whether more exist.
        while hits.count <= cap, let row = rowIterator.next() {
            guard !row.text.isEmpty else { continue }
            hits += self.hits(rowID: row.id, text: row.text, query: query, limit: cap + 1 - hits.count)
        }
        let capped = hits.count > cap
        if capped { hits.removeLast(hits.count - cap) }
        return TranscriptSearchResult(hits: hits, capped: capped)
    }
}
