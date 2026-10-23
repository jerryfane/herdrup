import Foundation

// Wire types for `agent.transcript` and `agent.answer` (herdr#306–#308): an omp agent's
// conversation read from its own session file, paged by turn, for the Chat view.
//
// Decoding is deliberately forgiving below the entry level: a newer server may add entry
// kinds, statuses or note sources, and one unfamiliar value must not fail a whole page
// (the view would fall back to "unavailable" for a conversation it can mostly show).

// MARK: - Params

/// Params of `agent.transcript`. `before` and `after` are mutually exclusive (the server
/// refuses both); neither asks for the newest page.
public struct AgentTranscriptParams: Encodable, Sendable, Equatable {
    public let target: String
    public let before: String?
    public let after: String?
    public let limit: UInt32?

    public init(target: String, before: String? = nil, after: String? = nil, limit: UInt32? = nil) {
        self.target = target
        self.before = before
        self.after = after
        self.limit = limit
    }
}

struct AgentAnswerParams: Encodable, Sendable {
    let target: String
    let askID: String
    let option: String

    enum CodingKeys: String, CodingKey {
        case target, option
        case askID = "ask_id"
    }
}

// MARK: - Entries

/// Who wrote a user turn. A guest prompt arrives as `<name> (via HerdrUp): <text>`; the
/// server strips that prefix and reports the guest here instead.
public enum TranscriptAuthor: Sendable, Equatable {
    case owner
    case guest(name: String?)
}

public enum TranscriptStepStatus: String, Sendable, Equatable {
    case running, ok, error
}

public enum TranscriptNoteSource: String, Sendable, Equatable {
    case gitmoot
    case asyncResult = "async_result"
    case advisor
    case other
}

public enum TranscriptTurnEndStatus: String, Sendable, Equatable {
    case done, error, aborted
}

public struct TranscriptStep: Sendable, Equatable {
    public let tool: String
    public let intent: String
    public let status: TranscriptStepStatus
    /// Owner only; at most 300 characters.
    public let detail: String?

    public init(tool: String, intent: String, status: TranscriptStepStatus, detail: String? = nil) {
        self.tool = tool
        self.intent = intent
        self.status = status
        self.detail = detail
    }
}

public struct TranscriptNote: Sendable, Equatable {
    public let source: TranscriptNoteSource
    public let title: String
    public let from: String?
    public let body: String

    public init(source: TranscriptNoteSource, title: String, from: String? = nil, body: String) {
        self.source = source
        self.title = title
        self.from = from
        self.body = body
    }
}

public struct TranscriptPlanItem: Decodable, Sendable, Equatable {
    public let text: String
    public let done: Bool

    public init(text: String, done: Bool) {
        self.text = text
        self.done = done
    }
}

public struct TranscriptQuestion: Decodable, Sendable, Equatable {
    public let question: String
    public let options: [String]
    public let multi: Bool
    /// Index into `options` omp marked as its recommendation.
    public let recommended: Int?

    public init(question: String, options: [String], multi: Bool = false, recommended: Int? = nil) {
        self.question = question
        self.options = options
        self.multi = multi
        self.recommended = recommended
    }

    enum CodingKeys: String, CodingKey { case question, options, multi, recommended }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        recommended = try c.decodeIfPresent(Int.self, forKey: .recommended)
    }
}

public struct TranscriptAsk: Sendable, Equatable {
    public let questions: [TranscriptQuestion]
    /// The options picked (`selectedOptions`); nil while unanswered.
    public let answer: [String]?

    public init(questions: [TranscriptQuestion], answer: [String]? = nil) {
        self.questions = questions
        self.answer = answer
    }
}

public struct TranscriptEntry: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user(text: String, author: TranscriptAuthor)
        /// Markdown. `final` marks the turn's final answer; a non-final reply is text omp
        /// wrote before a tool call, a real mid-task update.
        case reply(text: String, final: Bool)
        case thinking(text: String)
        case step(TranscriptStep)
        case note(TranscriptNote)
        case plan([TranscriptPlanItem])
        case ask(TranscriptAsk)
        case turnEnd(status: TranscriptTurnEndStatus, error: String?)
        case summary(text: String)
        /// A kind this app does not know; ignored by the view (contract: clients MUST
        /// ignore unknown kinds).
        case unknown(String)
    }

    public let id: String
    public let tsMs: UInt64
    public let kind: Kind

    public init(id: String, tsMs: UInt64, kind: Kind) {
        self.id = id
        self.tsMs = tsMs
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, author, final, tool, intent, status, detail, source, title, from, body
        case items, questions, answer, error
        case tsMs = "ts_ms"
        case authorName = "author_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tsMs = try c.decodeIfPresent(UInt64.self, forKey: .tsMs) ?? 0
        let kindName = try c.decode(String.self, forKey: .kind)
        func text() throws -> String { try c.decodeIfPresent(String.self, forKey: .text) ?? "" }
        switch kindName {
        case "user":
            let authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
            let author: TranscriptAuthor = try c.decodeIfPresent(String.self, forKey: .author) == "guest"
                ? .guest(name: authorName) : .owner
            kind = .user(text: try text(), author: author)
        case "reply":
            kind = .reply(text: try text(), final: try c.decodeIfPresent(Bool.self, forKey: .final) ?? false)
        case "thinking":
            kind = .thinking(text: try text())
        case "step":
            let tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
            let intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? tool
            // An unfamiliar status is treated as finished: a step that never stops
            // "running" would keep a blue dot on forever.
            let status = (try c.decodeIfPresent(String.self, forKey: .status))
                .flatMap(TranscriptStepStatus.init(rawValue:)) ?? .ok
            kind = .step(TranscriptStep(tool: tool, intent: intent, status: status,
                                        detail: try c.decodeIfPresent(String.self, forKey: .detail)))
        case "note":
            let source = (try c.decodeIfPresent(String.self, forKey: .source))
                .flatMap(TranscriptNoteSource.init(rawValue:)) ?? .other
            kind = .note(TranscriptNote(
                source: source,
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                from: try c.decodeIfPresent(String.self, forKey: .from),
                body: try c.decodeIfPresent(String.self, forKey: .body) ?? ""))
        case "plan":
            kind = .plan(try c.decodeIfPresent([TranscriptPlanItem].self, forKey: .items) ?? [])
        case "ask":
            kind = .ask(TranscriptAsk(
                questions: try c.decodeIfPresent([TranscriptQuestion].self, forKey: .questions) ?? [],
                answer: try c.decodeIfPresent([String].self, forKey: .answer)))
        case "turn_end":
            let status = (try c.decodeIfPresent(String.self, forKey: .status))
                .flatMap(TranscriptTurnEndStatus.init(rawValue:)) ?? .done
            kind = .turnEnd(status: status, error: try c.decodeIfPresent(String.self, forKey: .error))
        case "summary":
            kind = .summary(text: try text())
        default:
            kind = .unknown(kindName)
        }
    }
}

/// The newest ask with no answer yet (`pending_ask`).
public struct TranscriptPendingAsk: Decodable, Sendable, Equatable {
    public let id: String
    public let questions: [TranscriptQuestion]
    /// Single question, single-select, at least one option, and this caller may answer
    /// (false for guests): only then can the chat's buttons answer it.
    public let answerable: Bool

    public init(id: String, questions: [TranscriptQuestion], answerable: Bool) {
        self.id = id
        self.questions = questions
        self.answerable = answerable
    }

    enum CodingKeys: String, CodingKey { case id, questions, answerable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        questions = try c.decodeIfPresent([TranscriptQuestion].self, forKey: .questions) ?? []
        answerable = try c.decodeIfPresent(Bool.self, forKey: .answerable) ?? false
    }
}

/// What omp is doing right now, from its newest running step.
public struct TranscriptWorking: Decodable, Sendable, Equatable {
    public let intent: String
    public let tool: String
    public let sinceMs: UInt64

    public init(intent: String, tool: String, sinceMs: UInt64) {
        self.intent = intent
        self.tool = tool
        self.sinceMs = sinceMs
    }

    enum CodingKeys: String, CodingKey {
        case intent, tool
        case sinceMs = "since_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? tool
        sinceMs = try c.decodeIfPresent(UInt64.self, forKey: .sinceMs) ?? 0
    }
}

/// Result of `agent.transcript` (`type: "agent_transcript"`), entries oldest first.
public struct AgentTranscriptPage: Decodable, Sendable, Equatable {
    public let agent: String?
    public let paneID: String?
    public let sessionID: String?
    public let entries: [TranscriptEntry]
    /// Cursor for the next older page; nil once the page reached the first turn.
    public let before: String?
    /// Pass back as `after` to fetch what was appended since this page.
    public let after: String?
    public let pendingAsk: TranscriptPendingAsk?
    public let working: TranscriptWorking?

    public init(agent: String? = nil, paneID: String? = nil, sessionID: String? = nil,
                entries: [TranscriptEntry], before: String? = nil, after: String? = nil,
                pendingAsk: TranscriptPendingAsk? = nil, working: TranscriptWorking? = nil) {
        self.agent = agent
        self.paneID = paneID
        self.sessionID = sessionID
        self.entries = entries
        self.before = before
        self.after = after
        self.pendingAsk = pendingAsk
        self.working = working
    }

    enum CodingKeys: String, CodingKey {
        case agent, entries, before, after, working
        case paneID = "pane_id"
        case sessionID = "session_id"
        case pendingAsk = "pending_ask"
    }
}

/// Why `agent.transcript` produced no page.
public enum AgentTranscriptError: Error, Equatable, Sendable {
    case agentNotFound
    /// Not an omp agent, or herdr knows no session file for it; the Terminal view stays.
    case unsupported
    /// The session file is missing or unreadable right now.
    case unavailable
    /// The cursor is unknown to the server; restart from the newest page.
    case cursorExpired
}

/// Result of `agent.answer`. `sentUnconfirmed`: the keys reached omp's question UI but
/// herdr could not see the selection land; the next transcript refresh tells.
public enum AgentAnswerStatus: String, Decodable, Sendable, Equatable {
    case answered
    case sentUnconfirmed = "sent_unconfirmed"
}

struct AgentAnswerResult: Decodable {
    let status: AgentAnswerStatus
}

extension APIError {
    /// `agent.answer` could not drive omp's question UI (an older omp, or the selector is not
    /// on screen); the person can still answer by hand in the Terminal view.
    public var asksForTerminalAnswer: Bool {
        code == "ask_unsupported" || code == "ask_ui_not_found"
    }
}
