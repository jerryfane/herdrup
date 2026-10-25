import XCTest
@testable import HerdrKit

/// Searching the Chat once froze or crashed the app (herdrup#523 item 8): every match was
/// measured from the start of its row, nothing capped the matches, and a match that did
/// not move past the previous one could stall the scan.
final class TranscriptSearchTests: XCTestCase {
    /// Every match covers whole characters, is non-empty, and starts at or after the end
    /// of the one before, so the scan always advances.
    private func assertAdvancingWholeCharacters(_ text: String, _ query: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let boundaries = Set(text.indices).union([text.endIndex])
        let ranges = TranscriptSearch.ranges(in: text, query: query)
        XCTAssertLessThanOrEqual(ranges.count, text.count, "\(query) in \(text)", file: file, line: line)
        var previousEnd = text.startIndex
        for range in ranges {
            XCTAssertTrue(boundaries.contains(range.lowerBound), "start inside a character: \(query) in \(text)", file: file, line: line)
            XCTAssertTrue(boundaries.contains(range.upperBound), "end inside a character: \(query) in \(text)", file: file, line: line)
            XCTAssertLessThan(range.lowerBound, range.upperBound, "empty match: \(query) in \(text)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(range.lowerBound, previousEnd, "match did not advance: \(query) in \(text)", file: file, line: line)
            previousEnd = range.upperBound
        }
        // The offsets name the same places as the ranges.
        let matches = TranscriptSearch.matches(in: text, query: query)
        for match in matches {
            XCTAssertEqual(match.utf16Offset, text.utf16.distance(from: text.startIndex, to: match.range.lowerBound),
                           file: file, line: line)
        }
    }

    func testMatchesOnPartsOfCharactersAdvanceByWholeCharacters() {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let cases: [(text: String, query: String)] = [
            ("👍🏽 ok 👍🏽 👍", "👍"),
            ("👍🏽👍🏽", "🏽"),
            ("🇺🇸🇺🇸 us", "🇺"),
            ("🇺🇸🇺🇸", "🇸"),
            ("\(family) family \(family)", "👩"),
            ("\(family)\(family)", "\u{200D}"),
            ("Straße STRASSE strasse", "ss"),
            ("Straße", "SS"),
            ("ßßß", "s"),
            ("İstanbul i I ı", "i"),
            ("İİ", "i\u{307}"),
            ("ﬁle fi FI", "fi"),
            ("ﬁﬁ", "f"),
            ("ﬁﬁ", "i"),
            ("cafe\u{301} café", "é"),
            ("cafe\u{301}cafe\u{301}", "e"),
            ("e\u{301}e\u{301}", "\u{301}"),
        ]
        for (text, query) in cases {
            assertAdvancingWholeCharacters(text, query)
        }
    }

    func testCaseAndDiacriticBehaviourIsUnchanged() {
        XCTAssertEqual(TranscriptSearch.ranges(in: "Café and CAFÉ", query: "café").count, 2)
        XCTAssertEqual(TranscriptSearch.ranges(in: "café", query: "cafe").count, 0, "Search stays diacritic-sensitive")
        let text = "Find literal `.*[x]` safely, .*[x]"
        XCTAssertEqual(TranscriptSearch.ranges(in: text, query: ".*[x]").map { String(text[$0]) }, [".*[x]", ".*[x]"])
        XCTAssertEqual(TranscriptSearch.ranges(in: "eee", query: "e").count, 3)
        XCTAssertEqual(TranscriptSearch.ranges(in: "aaaa", query: "aa").count, 2, "Matches do not overlap")
        XCTAssertTrue(TranscriptSearch.ranges(in: "text", query: "").isEmpty)
        XCTAssertTrue(TranscriptSearch.ranges(in: "", query: "e").isEmpty)
    }

    func testHitsCarryUTF16OffsetsAndExcerpts() {
        let hits = TranscriptSearch.hits(rowID: "item:a", text: "👍🏽 café, then café", query: "CAFÉ")
        // "👍🏽" is four UTF-16 units, then a space.
        XCTAssertEqual(hits.map(\.id), ["item:a:5", "item:a:16"])
        XCTAssertTrue(hits.allSatisfy { $0.excerpt.contains("café") })
        let long = String(repeating: "x", count: 200) + "needle" + String(repeating: "y", count: 200)
        let excerpt = TranscriptSearch.hits(rowID: "r", text: long, query: "needle")[0].excerpt
        XCTAssertEqual(excerpt, String(repeating: "x", count: 48) + "needle" + String(repeating: "y", count: 80))
    }

    func testSearchStopsAtTheCapAndSaysSo() {
        let exact = TranscriptSearch.search([TranscriptSearchRow(id: "a", text: String(repeating: "e", count: 500))], query: "e")
        XCTAssertEqual(exact.hits.count, 500)
        XCTAssertFalse(exact.capped, "Exactly the cap is not more than the cap")

        var produced = 0
        let rows = (0..<5).lazy.map { index -> TranscriptSearchRow in
            produced += 1
            return TranscriptSearchRow(id: "row\(index)", text: String(repeating: "e ", count: 300))
        }
        let result = TranscriptSearch.search(rows, query: "E")
        XCTAssertEqual(result.hits.count, TranscriptSearch.matchCap)
        XCTAssertTrue(result.capped)
        XCTAssertEqual(result.hits.first?.id, "row0:0")
        XCTAssertEqual(result.hits.last?.id, "row1:398", "300 in the first row, the next 200 in the second")
        XCTAssertEqual(produced, 2, "Rows after the one that proves the cap are never read")
        XCTAssertEqual(Set(result.hits.map(\.id)).count, result.hits.count)

        XCTAssertEqual(TranscriptSearch.matches(in: String(repeating: "e", count: 50), query: "e", limit: 7).count, 7)
        XCTAssertEqual(TranscriptSearch.search([TranscriptSearchRow(id: "a", text: "e")], query: ""), .empty)
    }

    func testHitIDsSurviveARefreshThatAppends() {
        let before = [
            TranscriptSearchRow(id: "prompt:1", text: "Check café 👍🏽 prices"),
            TranscriptSearchRow(id: "item:reply", text: "| Unicode | café 東京 résumé | 42 |"),
        ]
        let after = [
            TranscriptSearchRow(id: "prompt:1", text: "Check café 👍🏽 prices"),
            TranscriptSearchRow(id: "item:reply", text: "| Unicode | café 東京 résumé | 42 |\n\nStreamed: café again"),
            TranscriptSearchRow(id: "item:incoming", text: "Incoming café update after refresh."),
        ]
        let old = TranscriptSearch.search(before, query: "café").hits.map(\.id)
        let new = TranscriptSearch.search(after, query: "café").hits.map(\.id)
        XCTAssertEqual(old, ["prompt:1:6", "item:reply:12"])
        XCTAssertEqual(Array(new.prefix(2)), old, "Appended text must not move earlier matches")
        XCTAssertEqual(new.count, 4)
        // The selected second match keeps its place: what the counter shows as 2/2 becomes 2/4.
        XCTAssertEqual(new.firstIndex(of: old[1]), 1)
    }

    func testOneCharacterQueryOverTwoHundredKilobytesIsLinear() {
        // Three "e"s per sentence; "café" and "résumé" do not match (diacritics count).
        let sentence = "The quick brown fox jumps over the lazy dog 👍🏽 café, résumé and 東京. "
        let repetitions = 200_000 / sentence.utf8.count + 1
        let text = String(repeating: sentence, count: repetitions)

        var started = Date()
        let all = TranscriptSearch.matches(in: text, query: "e")
        let uncapped = Date().timeIntervalSince(started)
        // Measuring each match from the start of the text took minutes here: ~7,400
        // matches, each walking on average 100k characters.
        XCTAssertEqual(all.count, 3 * repetitions)
        XCTAssertLessThan(uncapped, 5, "An uncapped scan of 200 KB must be linear")
        XCTAssertEqual(all.last.map { text.utf16.distance(from: text.startIndex, to: $0.range.lowerBound) }, all.last?.utf16Offset)

        started = Date()
        let rows = (0..<20).map { TranscriptSearchRow(id: "item:\($0)", text: text) }
        let capped = TranscriptSearch.search(rows, query: "e")
        let cappedTime = Date().timeIntervalSince(started)
        XCTAssertTrue(capped.capped)
        XCTAssertEqual(capped.hits.count, TranscriptSearch.matchCap)
        XCTAssertLessThan(cappedTime, 1, "A capped search over 4 MB stops at the cap")

        measure { _ = TranscriptSearch.search(rows, query: "e") }
    }
}
