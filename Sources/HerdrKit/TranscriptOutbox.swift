import Foundation

/// Delivery and appearance in the transcript are different facts. In particular, writing
/// bytes to a terminal is not confirmation that the agent accepted a prompt.
public enum TranscriptSendState: Sendable, Equatable {
    case sending
    case submitted
    case unconfirmed
    case notDelivered(String)
    case previousSession

    public init(rejection error: APIError) {
        switch PromptRejection(error) {
        case .notDelivered: self = .notDelivered(error.message)
        case .submittedStatusUnknown: self = .submitted
        default: self = .unconfirmed
        }
    }
}

public struct TranscriptOutgoingMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let author: TranscriptAuthor
    public fileprivate(set) var state: TranscriptSendState
    public fileprivate(set) var files: [TranscriptAttachment]
    fileprivate var wireText: String
    fileprivate var existingPromptIDs: Set<String>
    fileprivate var sessionID: String?
    fileprivate var baselineReady: Bool
}

/// A local display buffer, never a retry queue. Reconciliation consumes each new prompt
/// at most once, so two identical sends cannot both disappear when only one is recorded.
/// Matching says only that the text is now in the transcript, not which device wrote it.
public struct TranscriptOutbox: Sendable {
    public private(set) var messages: [TranscriptOutgoingMessage] = []
    public private(set) var recordedPromptIDs: Set<String> = []
    private var lastSessionID: String?

    public init() {}

    @discardableResult
    public mutating func stage(text: String, author: TranscriptAuthor,
                               entries: [TranscriptEntry], sessionID: String?, baselineReady: Bool = true,
                               files: [TranscriptAttachment] = []) -> String {
        let id = UUID().uuidString
        let existing = Set(entries.compactMap { entry -> String? in
            if case .user = entry.kind { return entry.id }
            return nil
        })
        messages.append(TranscriptOutgoingMessage(id: id, text: text, author: author,
                                                 state: .sending, files: files, wireText: text,
                                                 existingPromptIDs: existing, sessionID: sessionID,
                                                 baselineReady: baselineReady))
        return id
    }

    public mutating func update(_ id: String, state: TranscriptSendState, wireText: String? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = state
        if let wireText {
            messages[index].wireText = wireText
            if let parsed = GramAttachmentPrompt.parse(wireText) { messages[index].files = parsed.files }
        }
    }

    public mutating func prepare(_ id: String, entries: [TranscriptEntry], sessionID: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].baselineReady else { return }
        messages[index].existingPromptIDs = Set(entries.compactMap { entry -> String? in
            if case .user = entry.kind { return entry.id }
            return nil
        })
        messages[index].sessionID = sessionID
        messages[index].baselineReady = true
    }

    public mutating func reconcile(_ entries: [TranscriptEntry], sessionID: String?) {
        if let previous = lastSessionID, let current = sessionID, previous != current {
            recordedPromptIDs.removeAll(keepingCapacity: true)
        }
        if let sessionID { lastSessionID = sessionID }
        for index in messages.indices {
            if case .notDelivered = messages[index].state { continue }
            if let before = messages[index].sessionID, let now = sessionID, before != now {
                // Keep the user's text available, but never match or resend it into a
                // replacement session merely because the same words appear there.
                messages[index].state = .previousSession
            }
        }
        for entry in entries {
            guard case .user(let text, let author) = entry.kind,
                  !recordedPromptIDs.contains(entry.id),
                  let index = messages.firstIndex(where: { message in
                      switch message.state {
                      case .notDelivered, .previousSession: return false
                      default: break
                      }
                      return message.baselineReady && !message.existingPromptIDs.contains(entry.id)
                          && message.wireText == text && message.author == author
                  }) else { continue }
            recordedPromptIDs.insert(entry.id)
            messages.remove(at: index)
        }
    }
}
