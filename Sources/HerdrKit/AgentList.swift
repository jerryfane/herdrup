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

    public var id: String { info.id }
    public var title: String { info.displayName }

    /// Whether the pane still exists. A row for a pane herdr no longer lists is
    /// `stopped` regardless of the last status it reported.
    public let isLive: Bool

    public init(info: AgentInfo, isLive: Bool = true) {
        self.info = info
        self.isLive = isLive
        let status = AgentStatus(wire: info.agentStatus)
        self.status = status
        self.group = AgentRow.resolvedGroup(info: info, status: status, isLive: isLive)
    }

    /// WHETHER THIS ROW'S STATE IS UNCONFIRMED. A FACT about the row, with no rendering
    /// opinion in it: the row is live and sits on a peer the home did not confirm on its
    /// last poll, whether that peer is merely degraded or fully unreachable.
    ///
    /// SEPARATE FROM `showsUnconfirmedMarker` ON PURPOSE, and the separation is the fix for
    /// a real defect: the count below used to reuse the marker, which excludes
    /// `isUnreachable` for a RENDERING reason, so a fully OFFLINE peer's last-known-blocked
    /// agents escalated into needs-you and were then reported as CONFIRMED on the two
    /// surfaces that have no row to mark. A predicate scoped to one surface's drawing
    /// decision is the wrong thing to count with.
    public var hasUnconfirmedState: Bool {
        isLive && info.hasUnconfirmedStatus
    }

    /// Whether this row should be DRAWN with a staleness marker. The fact above, minus the
    /// unreachable case, which already replaces the status outright with an offline mark;
    /// doubling up would say the same thing twice in one row.
    ///
    /// ONE DEFINITION, DELIBERATELY. Every surface that draws a status reads THIS rather
    /// than re-deriving it: the first version of this marker existed only on the roster
    /// card, which is how the lock screen went on asserting an unconfirmed count as fact.
    public var showsUnconfirmedMarker: Bool {
        hasUnconfirmedState && !info.isUnreachable
    }

    /// ESCALATION-ONLY overlay on `group(for:isLive:)`. Two signals may move a row UP
    /// into `needsYou`; nothing here may ever move a row toward a QUIETER section, so
    /// the fail-closed placement the group order encodes cannot be undone by a lenient
    /// field.
    ///
    /// TWO SITES, NOT ONE. `group(for:isLive:)` keeps its exhaustive switch, so adding an
    /// `AgentStatus` case still fails to compile THERE. This overlay does NOT get that
    /// protection: it compares by equality (`status == .indefinite`), which keeps
    /// compiling forever, so a new status would silently decline the last-known
    /// escalation. Anyone adding a case must visit both.
    ///
    /// 1. `inputPending`. The group switch reads ONLY the status string, so an agent
    ///    showing a plan-approval or AskUserQuestion menu while its status is anything
    ///    other than the literal "blocked" could never reach `needsYou`. The predicate
    ///    already exists as `AgentInfo.isAwaitingMenuInput` and already gates input
    ///    routing; this makes the LIST agree with the router instead of contradicting it.
    ///
    /// 2. `lastKnownStatus`, and ONLY when it reads `blocked`. A federated peer that
    ///    misses a SINGLE poll is marked Degraded, and the daemon then overwrites
    ///    `agent_status` with "unknown" and moves the real state into
    ///    `last_known_status`, so every agent on that machine leaves both `working` and
    ///    `needsYou` at once. Reading the surviving copy for the blocked case only keeps
    ///    a fleet agent that is waiting on a human visible, without presenting any other
    ///    stale state as though it were live. A last-known `working` deliberately does
    ///    NOT restore the `working` group: that would be a demotion out of
    ///    `unrecognised`, and "this machine went quiet on us" is the louder, truer thing
    ///    to say. The real remedy for that case is daemon-side, not blanking a whole
    ///    peer on one missed poll.
    static func resolvedGroup(info: AgentInfo, status: AgentStatus, isLive: Bool) -> AgentGroup {
        let base = group(for: status, isLive: isLive)
        // A pane that is gone needs nothing from anybody: never escalate off `.stopped`.
        guard isLive else { return base }
        if info.isAwaitingMenuInput { return .needsYou }
        // The `.indefinite` precondition is load-bearing, not decoration: a LIVE status is
        // authoritative, and `last_known_status` is only meaningful once the daemon has
        // blanked the live one to "unknown". Escalating on a known-idle row that happens to
        // carry a stale blocked value would resurrect a state the server already replaced.
        if status == .indefinite, AgentStatus(wire: info.lastKnownStatus).isBlocked {
            return .needsYou
        }
        return base
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

    /// What the top of the screen says. Counts the `needsYou` GROUP, not the retained
    /// status. Reading `status.isBlocked` directly meant a blocked agent whose pane had
    /// since vanished sorted into `.stopped` and made `isQuiet` true while still
    /// reporting 1 here — the screen simultaneously claiming all-clear and one-waiting.
    ///
    /// THIS IS NO LONGER "positively-blocked agents only", and the older wording said so.
    /// `AgentRow.resolvedGroup` escalates two further shapes into the group: a row whose
    /// status is not `blocked` but which reports `input_pending`, and a row on a degraded
    /// peer whose blocked state is a LAST-KNOWN value. The second is a maybe by
    /// construction. That is a deliberate trade, because an agent waiting on a human is
    /// worse to hide than to over-report, and the row itself carries a staleness mark so
    /// the count is never the only thing the reader sees. An unrecognised status still has
    /// its own section and is still not counted here.
    public var needsYouCount: Int { rows.filter { $0.group == .needsYou }.count }

    /// How many of `needsYouCount` rest on a state the home could not confirm. A surface
    /// with no room for a per-row marker (the Live Activity) needs this to avoid asserting
    /// an unconfirmed "N need you" as fact on the lock screen.
    public var unconfirmedNeedsYouCount: Int {
        // `hasUnconfirmedState`, NOT `showsUnconfirmedMarker`. The marker excludes
        // unreachable rows because the card draws them an offline badge instead, and
        // counting with that exclusion reported a fully OFFLINE peer's stale guess as
        // CONFIRMED on exactly the two surfaces that have no row to mark.
        rows.filter { $0.group == .needsYou && $0.hasUnconfirmedState }.count
    }

    /// THE WORDING SPEC for "N need you", in HerdrKit so every surface can share one rule
    /// instead of each inventing its own. Three surfaces render this count: the roster
    /// header, the Live Activity lock-screen line, and the Dynamic Island. The first
    /// version qualified only the roster CARD, which is how the lock screen ended up
    /// asserting an unconfirmed state as fact.
    ///
    /// The Dynamic Island compact trailing is the one place that cannot use this: it has
    /// room for a glyph and a number, nothing more. That is a space constraint, recorded
    /// rather than pretended away.
    ///
    /// `nil` when nothing is waiting, so a caller can fall through to its own wording.
    public var needsYouSummary: String? {
        let total = needsYouCount
        guard total > 0 else { return nil }
        let unconfirmed = unconfirmedNeedsYouCount
        // Every waiting agent rests on an unconfirmed state, so the whole claim is a maybe.
        // Saying it outright beats appending a qualifier to an assertion.
        if unconfirmed >= total { return "\(total) may need you" }
        // Some confirmed, some not: lead with the fact, then name the doubt.
        if unconfirmed > 0 { return "\(total) need you · \(unconfirmed) stale" }
        return "\(total) need you"
    }

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

/// One atomically-published roster for the app's agent list.
///
/// Agents, account labels, and the derived/sorted list belong to the same render
/// frame. Keeping them together avoids the old two-step refresh where SwiftUI first
/// laid out new agents and then laid the same rows out again with new account data.
/// The derived list is cached here so a view evaluation never re-sorts the roster for
/// each section it renders.
public struct AgentRosterSnapshot: Equatable, Sendable {
    public let agents: [AgentInfo]
    public let accounts: [CredentialAccount]
    public let agentList: AgentList

    public init(
        agents: [AgentInfo] = [],
        accounts: [CredentialAccount] = [],
        livePaneIDs: Set<String>? = nil
    ) {
        self.agents = agents
        self.accounts = accounts
        self.agentList = AgentList(agents: agents, livePaneIDs: livePaneIDs)
    }
}

/// Buffers roster presentation while a reader is scrolling the agent list.
///
/// Fetching continues normally. While scrolling, each response replaces the pending
/// value, so returning to idle applies the newest server state exactly once. A response
/// equal to the displayed state clears a pending change: the server may legitimately
/// move back to its earlier state before scrolling finishes.
///
/// The transforms return a new value instead of mutating in place. The SwiftUI caller
/// can compare old/new and avoid writing `@State` at all for a no-op refresh, which is
/// the load-bearing part of the macOS scrolling fix.
public struct AgentRosterRefreshState: Equatable, Sendable {
    public private(set) var displayed: AgentRosterSnapshot
    public private(set) var pending: AgentRosterSnapshot?
    public private(set) var isScrolling: Bool

    public init(
        displayed: AgentRosterSnapshot = AgentRosterSnapshot(),
        pending: AgentRosterSnapshot? = nil,
        isScrolling: Bool = false
    ) {
        self.displayed = displayed
        self.pending = pending
        self.isScrolling = isScrolling
    }

    /// The freshest successfully-fetched value, whether or not it is on screen yet.
    /// Callers use this to preserve newer account data when a later best-effort
    /// `accounts.list` request fails during the same scroll.
    public var latest: AgentRosterSnapshot { pending ?? displayed }

    public func receiving(_ snapshot: AgentRosterSnapshot) -> AgentRosterRefreshState {
        var next = self
        if isScrolling {
            next.pending = snapshot == displayed ? nil : snapshot
        } else {
            next.pending = nil
            if snapshot != displayed { next.displayed = snapshot }
        }
        return next
    }

    public func settingScrolling(_ scrolling: Bool) -> AgentRosterRefreshState {
        guard scrolling != isScrolling else { return self }
        var next = self
        next.isScrolling = scrolling
        if !scrolling {
            if let pending, pending != displayed { next.displayed = pending }
            next.pending = nil
        }
        return next
    }
}

/// Monotonic latest-request gate for async roster refreshes.
///
/// `@MainActor` serializes state access, but it does not stop two `load()` calls
/// from interleaving at an `await`. Each load captures the token returned by
/// `begin()`, and may publish only while `accepts(_:)` remains true. Therefore an
/// older request that resumes after a newer one can never roll the roster back.
public struct AgentRosterLoadGate: Equatable, Sendable {
    private var latestToken: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        latestToken &+= 1
        return latestToken
    }

    public func accepts(_ token: UInt64) -> Bool {
        token == latestToken
    }
}

/// Compact "time in current state" label for the agent card badge (#173): minutes
/// under an hour, hours under a day, else days — never seconds, always a few digits
/// + one letter ("5m" / "2h" / "3d"). `nil` when the daemon reported no
/// `status_since` (older server, or not yet transitioned) or the timestamp is in the
/// future (clock skew) — the card then shows no badge rather than a wrong one.
/// Parses `UsageWindow.resetsAt` into an instant. Handles BOTH shapes the server sends.
///
/// The field is documented server-side as an "opaque string; may be an epoch or
/// timestamp", and the daemon really does send epoch seconds as a string
/// (`"1787831400"`). The app parsed ISO-8601 only, so every real account's reset failed
/// to parse and the usage meter silently dropped the reset token — the feature looked
/// unimplemented rather than broken. The mock fixture used ISO, so previews and tests
/// agreed with each other and not with the server.
///
/// All-digits is read as epoch seconds; anything else is tried as ISO-8601. Returns nil
/// when absent or unparseable, so the caller shows NO token rather than a wrong one.
public func parseResetInstant(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if trimmed.allSatisfy(\.isNumber), let epoch = TimeInterval(trimmed) {
        return Date(timeIntervalSince1970: epoch)
    }
    return isoResetParser.date(from: trimmed)
}

private let isoResetParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// The reset token shown beside a usage bar: how much is left when the reset is near,
/// the calendar date when it is not.
///
/// Chosen by the HORIZON, not by the window's name: the daemon labels windows `5h`,
/// `weekly`, `7d` and could add more, so keying off the text would leave new labels
/// unformatted. Under an hour reports minutes, because a window resetting in 45 minutes
/// must not read "0h left".
public func usageResetLabel(resetsAt: String?, now: Date = Date()) -> String? {
    guard let reset = parseResetInstant(resetsAt) else { return nil }
    let seconds = reset.timeIntervalSince(now)
    // Already past (or clock skew): the window has reset, so promise nothing.
    guard seconds > 0 else { return nil }
    if seconds < 3600 { return "\(Int(seconds / 60))m left" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h left" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: reset)
}

/// The account name to show on an agent row: the account's human label when the id
/// resolves in the roster, otherwise the raw id.
///
/// Falls back to the ID rather than to nil ON PURPOSE. The whole reason routing is
/// surfaced is that an agent on an unexpected account used to be invisible; showing
/// nothing because the roster has not loaded (or no longer holds that id) would restore
/// exactly the silence being fixed. A raw id is worse-looking and still true.
public func accountDisplayLabel(accountID: String?, accounts: [CredentialAccount]) -> String? {
    guard let accountID, !accountID.isEmpty else { return nil }
    return accounts.first { $0.id == accountID }?.label ?? accountID
}

/// The single instant "how long has it been in this state" is measured from, for BOTH
/// the list card's badge and the terminal header's live timer.
///
/// There is one right answer — `status_since_unix_ms`, the moment the agent entered its
/// current state — and two screens that must not disagree about it. They did: the header
/// measured from `last_completed_turn.completed_unix_ms` instead. For an IDLE agent those
/// are the same instant (it went idle exactly when its turn completed), which is why idle
/// always matched and the mismatch stayed hidden. For a WORKING agent the completed-turn
/// stamp is the moment the PREVIOUS turn ended, so the header over-counted by the whole
/// idle gap before the current turn began.
///
/// The completed-turn value survives only as the fallback for a daemon too old to report
/// `status_since` — an approximate timer beats none, and on those servers both screens
/// still agree because both land here.
public func statusAnchorUnixMs(statusSinceUnixMs: UInt64?, lastCompletedUnixMs: Int64?) -> Int64? {
    if let since = statusSinceUnixMs { return Int64(since) }
    return lastCompletedUnixMs
}

public func compactTimeInState(sinceUnixMs: UInt64?, nowUnixMs: UInt64) -> String? {
    guard let since = sinceUnixMs, nowUnixMs >= since else { return nil }
    let seconds = (nowUnixMs - since) / 1000
    if seconds < 3600 { return "\(seconds / 60)m" }      // 0m … 59m (never seconds)
    if seconds < 86_400 { return "\(seconds / 3600)h" }  // 1h … 23h
    return "\(seconds / 86_400)d"                         // 1d …
}
