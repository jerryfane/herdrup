import Foundation

/// The Gram inbox as held between loads: the last full list, plus the digest that
/// list was answered with.
///
/// It exists because the inbox was previously `@State` INSIDE the Gram page. On iPad
/// the page is built inside the detail column's `switch`, so leaving the section
/// destroys the view and its messages; coming back re-fetched the whole store from
/// zero and showed a spinner while it did. Switching Agents -> Gram -> Agents -> Gram
/// therefore paid for the entire history every time.
///
/// Two properties do the work:
///
/// - **It outlives the page**, so a remount renders the previous list immediately and
///   refreshes behind it. No spinner when there is something to show.
/// - **It holds the digest**, so the refresh behind it is conditional: an unchanged
///   store answers in a few hundred bytes instead of ~900 KB for ~870 messages, over
///   the one SSH channel the terminal also shares.
///
/// Deliberately NOT a cache with an expiry. The digest makes staleness observable at
/// the source, so a timer guessing when to distrust the list would add a second,
/// weaker answer to a question already answered exactly.
public struct GramInbox: Sendable, Equatable {
    /// The last full list the daemon sent, newest first.
    public private(set) var messages: [GramMessage] = []
    /// Digest of `messages` as the daemon fingerprinted them, or nil when we have
    /// never had a full answer (or the daemon does not send digests).
    public private(set) var digest: String?
    /// Which store `messages` came from. A change means these messages describe a
    /// DIFFERENT store and must not be kept.
    public private(set) var storeID: String?
    /// Whether a full list has ever landed. Distinct from `messages.isEmpty`: an inbox
    /// that has genuinely loaded and is empty must not show a spinner forever.
    public private(set) var hasLoaded = false

    public init() {}

    /// The digest to send as `ifUnchangedDigest` on the next poll — only while we
    /// actually hold the list it fingerprints. Sending a digest without the messages
    /// would invite an "unchanged" answer we could not render.
    public var conditionalDigest: String? { hasLoaded ? digest : nil }

    /// Unread agent->owner count over the FULL list, which is why the list is kept
    /// whole rather than windowed: a truncated view would silently under-count.
    public var unreadCount: Int { messages.filter(\.isUnread).count }

    /// Folds one `gram.list` answer in. Returns whether `messages` changed, so a
    /// caller can skip work (re-render, badge writes) on an unchanged poll.
    @discardableResult
    public mutating func apply(_ answer: GramListAnswer) -> Bool {
        // A store swap invalidates everything we hold, INCLUDING on an "unchanged"
        // answer. The daemon mixes its store id into the digest so it cannot happen
        // from that side, but a client that reconnected to a different machine must
        // not keep showing the old store's messages either way.
        if let known = storeID, let incoming = answer.storeID, known != incoming {
            messages = []
            digest = nil
            hasLoaded = false
        }
        if let incoming = answer.storeID { storeID = incoming }

        guard let fresh = answer.messages else {
            // Unchanged: keep the list AND the digest we already hold. Never treat
            // this as an empty inbox.
            //
            // Deliberately does NOT adopt `answer.digest`. An unchanged reply is only
            // returned when the digest we SENT matched, so there is nothing new to
            // adopt; the previous version's assignment was dead on a correct daemon
            // and survived every mutation of it, which is how it was found. Leaving
            // the digest alone is also the safer behaviour in the one race that can
            // reach here: an in-flight unchanged reply landing after `remove` or
            // `markRead` cleared the digest must not re-arm a digest that describes
            // the pre-mutation list.
            return false
        }
        let changed = fresh != messages
        messages = fresh
        digest = answer.digest
        hasLoaded = true
        return changed
    }

    /// Drops a message the owner deleted, so the local list agrees with the server
    /// before the next poll confirms it. Clears the digest: our list no longer matches
    /// what the daemon fingerprinted, and a conditional poll against a stale digest
    /// would be answered "unchanged" against a list we have already altered.
    public mutating func remove(id: String) {
        guard messages.contains(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id }
        digest = nil
    }

    /// Marks a message read locally. Same digest reasoning as `remove`.
    public mutating func markRead(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].isUnread
        else { return }
        messages[index].readByOwner = true
        digest = nil
    }
}
