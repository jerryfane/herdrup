import Foundation

/// What an agent is doing, as the client is willing to act on it.
///
/// herdr serialises its own `AgentStatus` as `idle | working | blocked | done |
/// unknown`, and the field is optional. That gives the client THREE distinct
/// ways of not knowing, and the whole value of this type is refusing to merge
/// them:
///
///   - `.absent`      the field was not sent. `agent.list` only ever returns
///                    agent terminals, so this means an older server or a gap
///                    — NOT "this is not an agent".
///   - `.indefinite`  the server sent `"unknown"`. It looked and could not tell.
///   - `.unrecognised` the server sent something this client has never heard of.
///
/// The third is the one that matters. A future herdr adding, say,
/// `"waiting_approval"` would — under a `default: .idle` mapping — sort an agent
/// that is blocked on a human into the quietest group on the screen, and nothing
/// would ever report it. The bug would be invisible, permanent, and would look
/// exactly like the feature working.
///
/// So the raw string is CARRIED, not discarded. It costs one associated value
/// and it is the difference between a client that degrades and one that lies.
public enum AgentStatus: Equatable, Sendable {
    case idle
    case working
    case blocked
    case done
    /// The server sent `"unknown"` — it looked and could not determine a state.
    case indefinite
    /// A value this build does not know. The payload is retained verbatim so it
    /// can be surfaced and diagnosed rather than guessed at.
    case unrecognised(String)
    /// No `agent_status` field at all.
    case absent

    /// Maps the wire value. Deliberately has no `default:` collapsing arm — an
    /// unmatched string becomes `.unrecognised(raw)`, never a real state.
    public init(wire: String?) {
        guard let wire else { self = .absent; return }
        switch wire {
        case "idle": self = .idle
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        case "unknown": self = .indefinite
        default: self = .unrecognised(wire)
        }
    }

    /// True only when herdr positively reports the agent is waiting on a human.
    ///
    /// NOT true for the unknown cases. Claiming an agent needs you when you do
    /// not know is a different lie from claiming it does not — this property
    /// answers exactly one question and the grouping below handles the rest.
    public var isBlocked: Bool { self == .blocked }
}

/// Which section of the list an agent belongs to.
///
/// Order is the screen's entire argument: the list exists to answer "does
/// anything need me?", so the answer sorts first and everything quiet sorts
/// last. `RawValue` is the sort key.
public enum AgentGroup: Int, Equatable, Sendable, CaseIterable, Comparable {
    /// herdr says this agent is waiting on a human.
    case needsYou = 0
    /// The pane is gone or the process exited.
    case stopped = 1
    /// THE FAIL-CLOSED PLACEMENT, and the reason this type exists.
    ///
    /// A status this build cannot interpret sorts ABOVE working and idle, not
    /// below them. "I do not know what this agent is doing" is nearer to *needs
    /// attention* than to *nothing to do*, and burying it is what would make a
    /// new upstream state permanently unobservable. Being wrong here is cheap —
    /// a stale row shown too prominently. Being wrong the other way is silent.
    case unrecognised = 2
    case working = 3
    case idle = 4

    public static func < (a: AgentGroup, b: AgentGroup) -> Bool {
        a.rawValue < b.rawValue
    }

    public var label: String {
        switch self {
        case .needsYou: return "needs you"
        case .stopped: return "stopped"
        case .unrecognised: return "unrecognised"
        case .working: return "working"
        case .idle: return "idle"
        }
    }

    /// Whether the section starts collapsed. Only the quiet tail does — a
    /// collapsed group must never be able to hide something wanting attention,
    /// which is why `.unrecognised` is not in here.
    public var startsCollapsed: Bool { self == .idle }
}

/// One row of the list, and the grouping decision for it.
public struct AgentRow: Equatable, Sendable, Identifiable {
    public let info: AgentInfo
    public let status: AgentStatus
    public let group: AgentGroup

    public var id: String { info.paneID }
    public var title: String { info.displayName }

    /// Whether the pane still exists. A row for a pane herdr no longer lists is
    /// `stopped` regardless of the last status it reported.
    public let isLive: Bool

    public init(info: AgentInfo, isLive: Bool = true) {
        self.info = info
        self.isLive = isLive
        let status = AgentStatus(wire: info.agentStatus)
        self.status = status
        self.group = AgentRow.group(for: status, isLive: isLive)
    }

    /// EXHAUSTIVE OVER `AgentStatus` ON PURPOSE — no `default:` arm.
    ///
    /// Adding a case to `AgentStatus` must fail to compile here rather than fall
    /// through to a guess. That compile error is the guard; a `default:` would
    /// silently swallow exactly the class of change this whole file exists to
    /// catch.
    static func group(for status: AgentStatus, isLive: Bool) -> AgentGroup {
        guard isLive else { return .stopped }
        switch status {
        case .blocked: return .needsYou
        case .working: return .working
        case .idle, .done: return .idle
        // Both of these mean "this build cannot say what is happening", and
        // both surface rather than sink. They stay SEPARATE cases in the status
        // type so a diagnostic can tell "the server could not tell" from "this
        // client is out of date", which are different problems with different
        // fixes — but they group identically, because the user's situation is
        // the same either way.
        // ALL THREE NOT-KNOWINGS SURFACE. `.absent` was grouped as `.idle`
        // here, on the reasoning that a missing status means "not an agent
        // pane". That reasoning was wrong, and the reviewer checked the server
        // rather than argue it: `agent_info` returns None unless
        // `terminal.is_agent_terminal()` (herdr src/app/agents.rs:368), so
        // every row in `agent.list` IS an agent. An absent status means an
        // older server or a gap — never a non-agent — and calling it definite
        // idle collapsed the exact case this file exists to surface.
        case .indefinite, .unrecognised, .absent: return .unrecognised
        }
    }
}

/// The whole list screen's state, derived from one `agent.list` response.
public struct AgentList: Equatable, Sendable {
    public let rows: [AgentRow]

    /// Sections in fixed group order, each holding its rows. Empty groups are
    /// omitted; the screen renders no heading for a section with nothing in it.
    public let sections: [(group: AgentGroup, rows: [AgentRow])]

    /// Archived agents (issue #173), kept OUT of the live status sections and out
    /// of `rows`/`needsYouCount`/`isQuiet` entirely — an archived agent needs
    /// nothing from you. Rendered in the screen's own collapsed "Archived" section,
    /// most-recently-archived first.
    public let archived: [AgentRow]

    /// What the top of the screen says. Counts only positively-blocked agents —
    /// an unrecognised status is surfaced by its own section, and inflating this
    /// number with maybes would make the one number on the screen untrustworthy.
    /// Counts the GROUP, not the retained status. Reading `status.isBlocked`
    /// directly meant a blocked agent whose pane had since vanished sorted into
    /// `.stopped` and made `isQuiet` true while still reporting 1 here — the
    /// screen simultaneously claiming all-clear and one-waiting.
    public var needsYouCount: Int { rows.filter { $0.group == .needsYou }.count }

    /// True when nothing is blocked AND nothing is unrecognised. The quiet state
    /// has to mean "I checked everything", so an uninterpretable agent must
    /// prevent it — otherwise the screen says all-clear while holding a row it
    /// could not read.
    public var isQuiet: Bool {
        !rows.contains { $0.group == .needsYou || $0.group == .unrecognised }
    }

    public static func == (a: AgentList, b: AgentList) -> Bool {
        a.rows == b.rows && a.archived == b.archived
    }

    /// Builds the list from an `agent.list` response.
    ///
    /// `livePaneIDs`, when supplied, is the set of panes herdr still reports;
    /// anything absent from it is `stopped`. Passing `nil` means "no pane
    /// census available", and every row is treated as live — the ONLY safe
    /// reading, since inferring death from missing evidence would mark every
    /// agent stopped the moment a census failed to arrive.
    public init(agents: [AgentInfo], livePaneIDs: Set<String>? = nil) {
        // Archived agents are pulled out first: they never appear in a live status
        // section and never count toward "needs you" / quiet. A released pane is not
        // "live", so they carry isLive = false; their own section renders them.
        let archivedInfos = agents.filter { $0.isArchived }
        let liveInfos = agents.filter { !$0.isArchived }
        self.archived = archivedInfos
            .map { AgentRow(info: $0, isLive: false) }
            .sorted { ($0.info.archived?.at ?? "") > ($1.info.archived?.at ?? "") }
        let rows = liveInfos.map { info in
            AgentRow(info: info, isLive: livePaneIDs.map { $0.contains(info.paneID) } ?? true)
        }
        // Group order first (the screen's primary signal — "does anything need me").
        // WITHIN a group, most-recently-active first: the agent whose last turn
        // completed most recently sorts to the top, using the server's wall-clock
        // `completed_unix_ms`. Agents with no completed turn yet sort last. paneID is
        // the final tiebreak — unique and stable as the agent works — so the list only
        // reshuffles when an agent is genuinely more recent, never on an unchanged
        // refresh where every timestamp is equal.
        let ordered = rows.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            let ta = a.info.lastCompletedTurn?.completedUnixMs ?? Int64.min
            let tb = b.info.lastCompletedTurn?.completedUnixMs ?? Int64.min
            if ta != tb { return ta > tb }
            return a.info.paneID < b.info.paneID
        }
        self.rows = ordered
        self.sections = AgentGroup.allCases.compactMap { group in
            let inGroup = ordered.filter { $0.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }
}
