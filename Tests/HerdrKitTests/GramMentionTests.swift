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

    /// Either order of the known names gives the same answer: a shorter name that the longer
    /// one starts with cannot end the token, so the matcher needs no longest-first sort.
    func testANameThatStartsAnotherNeverStealsTheMention() {
        for names in [["trend", "trend-scout"], ["trend-scout", "trend"],
                      ["vetrina", "vetrina.ops"], ["vetrina.ops", "vetrina"]] {
            let scout = resolve("@trend-scout digest?", names: names)
            let ops = resolve("@vetrina.ops digest?", names: names)
            if names.contains("trend") {
                XCTAssertEqual(scout.recipient, "trend-scout", "\(names)")
                XCTAssertEqual(scout.body, "digest?", "\(names)")
                XCTAssertEqual(resolve("@trend digest?", names: names).recipient, "trend", "\(names)")
            } else {
                XCTAssertEqual(ops.recipient, "vetrina.ops", "\(names)")
                XCTAssertEqual(ops.body, "digest?", "\(names)")
                XCTAssertEqual(resolve("@vetrina. digest?", names: names).recipient, "vetrina", "\(names)")
            }
        }
    }

    func testLeadingMentionTakesTheSeparatorAfterItOff() {
        XCTAssertEqual(resolve("@vetrina, ship it").body, "ship it")
        XCTAssertEqual(resolve("@vetrina: go").body, "go")
        XCTAssertEqual(resolve("@vetrina - go").body, "go")
        XCTAssertEqual(resolve("@vetrina;go").body, "go")
        XCTAssertEqual(resolve("@vetrina,\n  ship it").body, "ship it")
        XCTAssertEqual(resolve("@vetrina's build").body, "'s build", "an apostrophe is not a separator")
        XCTAssertEqual(resolve("@vetrina: ").body, "", "nothing but a separator is an empty body")
        XCTAssertEqual(resolve("ask @vetrina, then go").body, "ask @vetrina, then go",
                       "a mention later in the text keeps its punctuation")
    }

    /// Only the separator after the mention goes: the message's own leading dash, colon or
    /// bullet is content (CLI flags, negative numbers, markdown lists, smileys).
    func testLeadingMentionKeepsTheMessagesOwnPunctuation() {
        XCTAssertEqual(resolve("@vetrina -v deploy").body, "-v deploy")
        XCTAssertEqual(resolve("@vetrina --dry-run deploy").body, "--dry-run deploy")
        XCTAssertEqual(resolve("@vetrina -5% is fine").body, "-5% is fine")
        XCTAssertEqual(resolve("@vetrina\n- item one\n- item two").body, "- item one\n- item two")
        XCTAssertEqual(resolve("@vetrina :) thanks").body, ":) thanks")
        XCTAssertEqual(resolve("@vetrina: - item").body, "- item", "one separator, then the content")
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

    // MARK: leadingToken

    func testLeadingTokenIsTheRunAfterALeadingAt() {
        XCTAssertEqual(GramMention.leadingToken(in: "@vetrna hi"), "vetrna")
        XCTAssertEqual(GramMention.leadingToken(in: "  @vetrina, go"), "vetrina")
        XCTAssertEqual(GramMention.leadingToken(in: "@vetrina.dev is live"), "vetrina.dev")
        XCTAssertEqual(GramMention.leadingToken(in: "@vetrina."), "vetrina")
        XCTAssertEqual(GramMention.leadingToken(in: "@ hi"), "")
        XCTAssertEqual(GramMention.leadingToken(in: "@"), "")
    }

    func testNoLeadingTokenWithoutALeadingAt() {
        XCTAssertNil(GramMention.leadingToken(in: "ship it @vetrina"))
        XCTAssertNil(GramMention.leadingToken(in: "me@vetrina"))
        XCTAssertNil(GramMention.leadingToken(in: ""))
        XCTAssertNil(GramMention.leadingToken(in: "   "))
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

    // MARK: addressing / unaddressed (the pill sheet's "Write to" and "Shared queue")

    private func address(_ text: String, to name: String = "clientloop") -> String {
        GramMention.addressing(text, to: name, knownNames: agents)
    }

    private func unaddress(_ text: String) -> String {
        GramMention.unaddressed(text, knownNames: agents)
    }

    func testAddressingReplacesALeadingMentionAndItsSeparator() {
        XCTAssertEqual(address("@vetrina ship it"), "@clientloop ship it")
        XCTAssertEqual(address("@vetrina, ship it"), "@clientloop ship it")
        XCTAssertEqual(address("  @VETRINA: go"), "@clientloop go")
        XCTAssertEqual(address("@vetrina\n- item one"), "@clientloop - item one")
    }

    func testAddressingKeepsALaterMentionAsPartOfTheMessage() {
        XCTAssertEqual(address("ship it @vetrina"), "@clientloop ship it @vetrina")
    }

    func testAddressingReplacesALeadingTokenThatNamesNoOne() {
        XCTAssertEqual(address("@vetrna hi"), "@clientloop hi")
        XCTAssertEqual(address("@ hi"), "@clientloop hi")
        XCTAssertEqual(address("@"), "@clientloop ")
    }

    func testAddressingPrefixesUnaddressedText() {
        XCTAssertEqual(address("plain text"), "@clientloop plain text")
        XCTAssertEqual(address(""), "@clientloop ")
        XCTAssertEqual(address("me@vetrina.dev ok", to: "vetrina"), "@vetrina me@vetrina.dev ok")
    }

    func testUnaddressedDropsALeadingMention() {
        XCTAssertEqual(unaddress("@vetrina ship it"), "ship it")
        XCTAssertEqual(unaddress("@vetrina, ship it"), "ship it")
        XCTAssertEqual(unaddress("@vetrina"), "")
    }

    func testUnaddressedDropsALaterMentionWithOneSpace() {
        XCTAssertEqual(unaddress("ship it @vetrina"), "ship it")
        XCTAssertEqual(unaddress("ask @vetrina to ship"), "ask to ship")
    }

    /// Every mention that would address the draft goes, not just the first: after the
    /// leading one leaves, the next becomes the address.
    func testUnaddressedDropsEveryAddressingMention() {
        XCTAssertEqual(unaddress("@vetrina tell @clientloop hi"), "tell hi")
    }

    func testUnaddressedDropsALeadingTokenThatNamesNoOne() {
        XCTAssertEqual(unaddress("@vetrna hi"), "hi")
        XCTAssertEqual(unaddress("@ hi"), "hi")
    }

    func testUnaddressedLeavesTextWithoutMentions() {
        XCTAssertEqual(unaddress("plain text"), "plain text")
        XCTAssertEqual(unaddress("me@vetrina.dev ok"), "me@vetrina.dev ok")
    }
}
