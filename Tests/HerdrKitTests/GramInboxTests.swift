import XCTest
@testable import HerdrKit

/// `GramInbox` is what makes a section switch cheap: it survives the Gram page and
/// carries the digest that makes the next poll conditional. These pin the properties
/// the page relies on — each one, if broken, produces a specific visible bug.
final class GramInboxTests: XCTestCase {
    private func message(
        _ id: String, from: String = "trend-scout", unread: Bool = true, text: String = "hi"
    ) throws -> GramMessage {
        let json = """
        {"id":"\(id)","direction":"agent_to_owner","from":"\(from)","text":"\(text)",
         "created_unix_ms":1750000000000,"read_by_owner":\(unread ? "false" : "true")}
        """
        return try JSONDecoder().decode(GramMessage.self, from: Data(json.utf8))
    }

    private func answer(
        _ messages: [GramMessage]?, digest: String?, store: String? = "store-1"
    ) -> GramListAnswer {
        GramListAnswer(messages: messages, digest: digest, storeID: store)
    }

    /// The bug this whole type exists for: an "unchanged" answer carries NO messages,
    /// and must never be read as an empty inbox. Treating nil as [] would blank the
    /// list on every successful conditional poll — i.e. every 6 seconds.
    func testUnchangedAnswerKeepsTheMessages() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1"))
        XCTAssertEqual(inbox.messages.count, 1)

        let changed = inbox.apply(answer(nil, digest: "d1"))
        XCTAssertFalse(changed, "an unchanged answer is not a change")
        XCTAssertEqual(inbox.messages.count, 1, "unchanged must not empty the inbox")
        XCTAssertTrue(inbox.hasLoaded)
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// An unchanged reply must leave the digest EXACTLY as it was, not re-assign it.
    /// A previous version adopted `answer.digest` here; the assignment was dead on a
    /// correct daemon (an unchanged reply only comes back when the digest we sent
    /// matched) and survived mutation, so this pins the branch that replaced it.
    /// The dangerous case is the one asserted second: an in-flight unchanged reply
    /// landing AFTER a local mutation cleared the digest must not re-arm one that
    /// describes the pre-mutation list, or the next poll is answered "unchanged"
    /// against a list we have already altered and the page never reconciles.
    func testUnchangedAnswerNeverReArmsTheDigest() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1"), try message("g2")], digest: "d1"))

        inbox.apply(answer(nil, digest: "d-other"))
        XCTAssertEqual(inbox.conditionalDigest, "d1", "an unchanged reply must not change the digest")

        inbox.remove(id: "g1")
        XCTAssertNil(inbox.conditionalDigest)
        inbox.apply(answer(nil, digest: "d1"))
        XCTAssertNil(inbox.conditionalDigest,
                     "a late unchanged reply must not re-arm a digest for the pre-mutation list")
    }

    /// A warm inbox is what suppresses the spinner on a remount. `hasLoaded` has to be
    /// distinct from `messages.isEmpty`, or a genuinely empty inbox would spin forever.
    func testGenuinelyEmptyInboxCountsAsLoaded() {
        var inbox = GramInbox()
        XCTAssertFalse(inbox.hasLoaded, "nothing has arrived yet — a spinner is correct here")
        XCTAssertNil(inbox.conditionalDigest, "no list held, so no digest may be sent")

        inbox.apply(answer([], digest: "d-empty"))
        XCTAssertTrue(inbox.hasLoaded, "an empty list IS a loaded list")
        XCTAssertTrue(inbox.messages.isEmpty)
    }

    /// Sending a digest we cannot back up with a list would invite an "unchanged"
    /// answer we have nothing to render. Only a held list licenses a conditional poll.
    func testDigestIsOnlyOfferedWhileTheListIsHeld() throws {
        var inbox = GramInbox()
        inbox.apply(answer(nil, digest: "d9"))
        XCTAssertNil(inbox.conditionalDigest,
                     "an unchanged answer arriving first leaves nothing to validate")

        inbox.apply(answer([try message("g1")], digest: "d1"))
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// A local edit makes our list differ from the one the daemon fingerprinted. If the
    /// digest survived, the next poll would be answered "unchanged" and the local
    /// deletion would never be reconciled with the server's view.
    func testLocalMutationClearsTheDigest() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1"), try message("g2")], digest: "d1"))

        inbox.remove(id: "g1")
        XCTAssertEqual(inbox.messages.map(\.id), ["g2"])
        XCTAssertNil(inbox.conditionalDigest, "a locally altered list must be re-fetched in full")

        inbox.apply(answer([try message("g2")], digest: "d2"))
        inbox.markRead(id: "g2")
        XCTAssertNil(inbox.conditionalDigest, "a local mark-read also diverges from the digest")
    }

    /// Removing an id we do not hold must not clear the digest: that would turn every
    /// stray delete into a full re-download.
    func testRemovingAnUnknownIDLeavesTheDigestIntact() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1"))
        inbox.remove(id: "nope")
        XCTAssertEqual(inbox.conditionalDigest, "d1")
    }

    /// The unread badge reads the FULL list, which is why the design keeps the whole
    /// list rather than a window — and why mark-read has to move the count.
    func testUnreadCountTracksTheWholeList() throws {
        var inbox = GramInbox()
        inbox.apply(answer([
            try message("g1", unread: true),
            try message("g2", unread: true),
            try message("g3", unread: false),
        ], digest: "d1"))
        XCTAssertEqual(inbox.unreadCount, 2)

        inbox.markRead(id: "g1")
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(inbox.messages.first?.readByOwner, true)
    }

    /// Messages describe one store. Reconnected to a different machine, keeping the old
    /// list would show another store's inbox — including on an "unchanged" answer,
    /// which is the case a digest check alone would not catch.
    func testStoreChangeDropsTheHeldList() throws {
        var inbox = GramInbox()
        inbox.apply(answer([try message("g1")], digest: "d1", store: "store-1"))

        let changed = inbox.apply(answer(nil, digest: "d1", store: "store-2"))
        XCTAssertFalse(changed)
        XCTAssertTrue(inbox.messages.isEmpty, "another store's messages must not be shown")
        XCTAssertFalse(inbox.hasLoaded, "and the page must load rather than render them")
        XCTAssertNil(inbox.conditionalDigest)
    }

    /// A daemon predating the digest sends none, so every poll stays unconditional and
    /// full — the pre-existing behaviour, which must keep working unchanged.
    func testDaemonWithoutDigestsStillLoads() throws {
        var inbox = GramInbox()
        let changed = inbox.apply(answer([try message("g1")], digest: nil, store: nil))
        XCTAssertTrue(changed)
        XCTAssertTrue(inbox.hasLoaded)
        XCTAssertNil(inbox.conditionalDigest, "no digest offered means no conditional request")
    }

    /// `apply` reports whether anything moved so the page can skip re-reconciling on a
    /// poll that changed nothing. A same-content answer is not a change even when the
    /// daemon re-sent the list.
    func testChangeReportingDistinguishesContentFromTransfer() throws {
        var inbox = GramInbox()
        XCTAssertTrue(inbox.apply(answer([try message("g1")], digest: "d1")))
        XCTAssertFalse(inbox.apply(answer([try message("g1")], digest: "d1")),
                       "re-sending identical messages is not a content change")
        XCTAssertTrue(inbox.apply(answer([try message("g1"), try message("g2")], digest: "d2")))
    }
}
