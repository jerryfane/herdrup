import XCTest
@testable import HerdrKit

/// `@name` in the Gram composer decides who a post goes to: a wrong match sends a message
/// to the wrong agent, and a missed one drops it into the shared queue.
final class GramMentionTests: XCTestCase {
    private let agents = ["vetrina", "clientloop", "trend-scout", "ci-watch"]

    private func query(_ text: String, cursorOffset: Int? = nil) -> (token: String, query: String)? {
        let cursor = cursorOffset.map { text.index(text.startIndex, offsetBy: $0) }
        guard let found = GramMention.activeQuery(in: text, cursor: cursor) else { return nil }
        return (String(text[found.range]), found.query)
    }

    private func resolve(_ text: String, names: [String]? = nil) -> (recipient: String?, body: String) {
        GramMention.resolve(text, knownNames: names ?? agents)
    }

    // MARK: activeQuery

    func testBareAtIsAnEmptyQuery() throws {
        let found = try XCTUnwrap(query("@"))
        XCTAssertEqual(found.token, "@")
        XCTAssertEqual(found.query, "")
    }

    func testTrailingTokenAfterSpaceIsTheQuery() throws {
        let found = try XCTUnwrap(query("ship it @ve"))
        XCTAssertEqual(found.token, "@ve")
        XCTAssertEqual(found.query, "ve")
    }

    func testQueryKeepsHyphens() throws {
        XCTAssertEqual(try XCTUnwrap(query("@trend-sc")).query, "trend-sc")
    }

    func testQueryAfterNewline() throws {
        let found = try XCTUnwrap(query("first line\n@ci"))
        XCTAssertEqual(found.token, "@ci")
        XCTAssertEqual(found.query, "ci")
    }

    func testAtInsideAWordIsNotAQuery() {
        XCTAssertNil(query("mail me@vet"), "an email-like @ is not a mention")
        XCTAssertNil(query("a@"))
        XCTAssertNil(query("@@ve"))
    }

    func testNoQueryOnceTheTokenEnds() {
        XCTAssertNil(query("@vetrina "), "a space after the name ends the query")
        XCTAssertNil(query("@vetrina ship it"), "only the trailing token counts")
        XCTAssertNil(query(""))
        XCTAssertNil(query("ship it"))
    }

    func testQueryEndsAtTheCursor() throws {
        // "ask @ve|\nthen go": the token before the cursor, not the text after it.
        let found = try XCTUnwrap(query("ask @ve\nthen go", cursorOffset: 7))
        XCTAssertEqual(found.token, "@ve")
        XCTAssertEqual(found.query, "ve")
        XCTAssertNil(query("ask @ve then go", cursorOffset: 3), "no @ before the cursor")
    }

    // MARK: complete

    func testCompleteReplacesTheTokenWithTheNameAndASpace() throws {
        let text = "ship it @ve"
        let found = try XCTUnwrap(GramMention.activeQuery(in: text))
        XCTAssertEqual(GramMention.complete(text, replacing: found.range, with: "vetrina"), "ship it @vetrina ")
    }

    func testCompleteAtTheStart() throws {
        let found = try XCTUnwrap(GramMention.activeQuery(in: "@"))
        XCTAssertEqual(GramMention.complete("@", replacing: found.range, with: "ci-watch"), "@ci-watch ")
    }

    func testCompleteKeepsTheTextAfterTheCursor() throws {
        let text = "ask @ci\nthen go"
        let cursor = text.index(text.startIndex, offsetBy: 7)
        let found = try XCTUnwrap(GramMention.activeQuery(in: text, cursor: cursor))
        XCTAssertEqual(GramMention.complete(text, replacing: found.range, with: "ci-watch"),
                       "ask @ci-watch \nthen go")
    }

    // MARK: resolve

    func testLeadingMentionIsTheRecipientAndLeavesTheBody() {
        let resolved = resolve("@vetrina ship it")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "ship it", "the leading mention and its space are stripped")
    }

    func testLeadingMentionBeforeANewline() {
        let resolved = resolve("@vetrina\nship it")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "ship it")
    }

    func testMentionMatchesCaseInsensitivelyAndReturnsTheKnownSpelling() {
        let resolved = resolve("@VeTrina ship it")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "ship it")
    }

    func testHyphenatedNames() {
        let scout = resolve("@trend-scout digest?")
        XCTAssertEqual(scout.recipient, "trend-scout")
        XCTAssertEqual(scout.body, "digest?")
        XCTAssertEqual(resolve("@CI-Watch rerun").recipient, "ci-watch")
    }

    func testLongestKnownNameWins() {
        let resolved = resolve("@trend-scout digest?", names: ["trend", "trend-scout"])
        XCTAssertEqual(resolved.recipient, "trend-scout")
        XCTAssertEqual(resolved.body, "digest?")
    }

    func testAKnownNameMustEndTheToken() {
        XCTAssertNil(resolve("@vetrina2 ship it").recipient)
        XCTAssertNil(resolve("@trend-scoutx hi").recipient)
        XCTAssertNil(resolve("@trend digest", names: ["trend-scout"]).recipient, "a prefix is not the name")
        XCTAssertNil(resolve("@vetrina.dev is live").recipient, "a domain is not a mention")
        XCTAssertEqual(resolve("thanks @vetrina.").recipient, "vetrina", "a full stop ends the name")
    }

    func testUnknownNameGoesToTheQueueUnchanged() {
        let resolved = resolve("@nobody ship it")
        XCTAssertNil(resolved.recipient)
        XCTAssertEqual(resolved.body, "@nobody ship it")
    }

    func testNoMentionGoesToTheQueueUnchanged() {
        let resolved = resolve("Who can triage the failing CI?")
        XCTAssertNil(resolved.recipient)
        XCTAssertEqual(resolved.body, "Who can triage the failing CI?")
        XCTAssertNil(resolve("@vetrina hi", names: []).recipient)
    }

    func testEmailLikeAtIsNotAMention() {
        let resolved = resolve("mail me@vetrina when done")
        XCTAssertNil(resolved.recipient)
        XCTAssertEqual(resolved.body, "mail me@vetrina when done")
    }

    func testMidTextMentionAddressesButStaysInTheBody() {
        let resolved = resolve("ship it @vetrina")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "ship it @vetrina")
    }

    func testFirstKnownMentionWins() {
        let leading = resolve("@ci-watch ask @vetrina")
        XCTAssertEqual(leading.recipient, "ci-watch")
        XCTAssertEqual(leading.body, "ask @vetrina")

        let later = resolve("ask @trend-scout and @vetrina")
        XCTAssertEqual(later.recipient, "trend-scout")
        XCTAssertEqual(later.body, "ask @trend-scout and @vetrina")
    }

    func testUnknownMentionBeforeAKnownOneIsSkipped() {
        let resolved = resolve("@nobody @vetrina hi")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "@nobody @vetrina hi", "the known mention is not leading, so it stays")
    }

    func testMentionAloneLeavesAnEmptyBody() {
        let resolved = resolve("@vetrina")
        XCTAssertEqual(resolved.recipient, "vetrina")
        XCTAssertEqual(resolved.body, "")
    }

    // MARK: ranges

    func testRangesCoverEveryKnownMention() {
        let text = "@vetrina ask @CI-Watch, not @nobody or me@vetrina.dev"
        XCTAssertEqual(GramMention.ranges(in: text, knownNames: agents).map { String(text[$0]) },
                       ["@vetrina", "@CI-Watch"])
    }

    func testNoRangesWithoutKnownMentions() {
        XCTAssertEqual(GramMention.ranges(in: "plain text", knownNames: agents), [])
        XCTAssertEqual(GramMention.ranges(in: "@vetrina", knownNames: []), [])
    }
}
