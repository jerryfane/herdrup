import Foundation

// NO ActivityKit IMPORT, AND THAT IS WHY THIS FILE EXISTS SEPARATELY.
//
// The sibling AgentActivityAttributes.swift must import ActivityKit to conform to
// `ActivityAttributes`, and ActivityKit does not exist on Linux. While these two types
// were nested inside it they were untestable BY CONSTRUCTION, because this repo has no
// app-side unit test bundle either. A review measured what that cost: changing one line
// in LiveActivityController reintroduced a shipped lock-screen defect in full and survived
// the entire 434-test suite AND the UI receipt, since XCUITest cannot see a Live Activity.
//
// Split out, a SwiftPM target can take `path: "Shared"` with `sources` limited to THIS
// file, beside its ActivityKit-importing sibling, and run on Linux. The Xcode app and
// widget targets keep compiling the whole Shared directory as sources and do NOT link that
// SwiftPM product, so nothing lands in either binary twice.
//
// The names are deliberately not `State` and `Status`: as top-level types those would be
// far too generic. `AgentActivityAttributes` re-exposes them under its old nested names via
// typealiases, so every existing reference keeps working.

struct AgentActivityState: Codable, Hashable {
    /// The agent shown in the headline — the session's highest-priority one.
    var headline: String
    /// That agent's bucket: drives the colour and the status word.
    var status: AgentActivityStatus
    /// How many agents are waiting on the user right now.
    var needsYouCount: Int
    /// How many of `needsYouCount` rest on a state the home could NOT confirm on its
    /// last poll: a federated agent on a degraded peer, whose blocked state is a
    /// last-known value rather than a live one. The lock screen and Dynamic Island have
    /// no room for a per-row marker, so the count is qualified in the summary line
    /// instead.
    ///
    /// A STORED-PROPERTY DEFAULT DOES NOT MAKE THIS DECODABLE FROM AN OLD PAYLOAD.
    /// An earlier version of this comment claimed it did; that was measured false.
    /// Synthesized `Decodable` calls `decode(Int.self, forKey:)` and throws
    /// `keyNotFound` when the key is absent, because stored-property defaults are
    /// invisible to Codable synthesis. Two directions actually break without help:
    /// this build reading an activity persisted by an older one (ActivityKit drops an
    /// undecodable activity, so it can never be reclaimed or ended), and a
    /// daemon-pushed payload minted before this field existed. The explicit
    /// `init(from:)` below uses `decodeIfPresent` for this ONE key to cover both.
    var unconfirmedCount: Int = 0
    /// How many agents are actively working right now.
    var workingCount: Int
    /// Total agents in the session.
    var totalCount: Int
    /// When the headline agent's CURRENT turn started (Unix SECONDS), set only
    /// while `status == .working`. Drives a live `Text(timerInterval:)` in the
    /// widget — the one thing iOS actually frame-interpolates in a Live Activity,
    /// so the working state shows real motion on the lock screen / Dynamic Island.
    /// A plain Double (not Date) so the daemon-pushed JSON decodes identically,
    /// dodging Swift's Date reference-date Codable strategy. `nil` when not working.
    var workingSince: Double?
    /// When the headline agent entered the blocked state (Unix seconds). The widget
    /// renders this with a system timer so the waiting age advances without pushes.
    var blockedSince: Double?
    /// Daemon-truncated prompt copy for the one-line expanded and Lock Screen layouts.
    var question: String?
    /// A daemon-owned safe answer. Nil means the activity must offer Open, not Approve.
    var defaultAnswer: String?
    /// Stable pane identifier used by the activity's deep link.
    var agentID: String?
    /// When this snapshot was produced (Unix seconds), for honest stale-state copy.
    var updatedAt: Double?

    /// Hand-written because additive metadata and enum cases must not make an existing
    /// Live Activity undecodable. ActivityKit drops an undecodable activity, so it could
    /// then be neither reclaimed nor ended.
    ///
    /// `unconfirmedCount` defaults to zero for payloads predating that count. The prompt,
    /// identity, timing, and freshness fields are optional by contract and decode with
    /// `decodeIfPresent` for persisted activities and daemon payloads from older builds.
    ///
    /// An unrecognised `status` word also remains readable. Raw-value decoding would throw
    /// `dataCorrupted`; instead it falls back to `.needsYou`, matching HerdrKit's rule that
    /// something uninterpretable surfaces rather than sinks.
    ///
    /// Core display fields stay required, so a genuinely malformed payload still fails
    /// loudly instead of decoding into a plausible zero.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decode(String.self, forKey: .headline)
        let rawStatus = try c.decode(String.self, forKey: .status)
        status = AgentActivityStatus(rawValue: rawStatus) ?? .needsYou
        needsYouCount = try c.decode(Int.self, forKey: .needsYouCount)
        unconfirmedCount = try c.decodeIfPresent(Int.self, forKey: .unconfirmedCount) ?? 0
        workingCount = try c.decode(Int.self, forKey: .workingCount)
        totalCount = try c.decode(Int.self, forKey: .totalCount)
        workingSince = try c.decodeIfPresent(Double.self, forKey: .workingSince)
        blockedSince = try c.decodeIfPresent(Double.self, forKey: .blockedSince)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        defaultAnswer = try c.decodeIfPresent(String.self, forKey: .defaultAnswer)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }

    /// Restored because writing `init(from:)` suppresses the synthesized memberwise
    /// initialiser this type is constructed with everywhere else.
    init(headline: String, status: AgentActivityStatus, needsYouCount: Int, unconfirmedCount: Int = 0,
         workingCount: Int, totalCount: Int, workingSince: Double?, blockedSince: Double? = nil,
         question: String? = nil, defaultAnswer: String? = nil, agentID: String? = nil,
         updatedAt: Double? = nil) {
        self.headline = headline
        self.status = status
        self.needsYouCount = needsYouCount
        self.unconfirmedCount = unconfirmedCount
        self.workingCount = workingCount
        self.totalCount = totalCount
        self.workingSince = workingSince
        self.blockedSince = blockedSince
        self.question = question
        self.defaultAnswer = defaultAnswer
        self.agentID = agentID
        self.updatedAt = updatedAt
    }
}

enum AgentActivityDeepLink {
    private static let fallback = URL(string: "herdrup://agents")!

    static func url(agentID: String?) -> URL {
        guard let agentID, !agentID.isEmpty else { return fallback }
        var components = URLComponents()
        components.scheme = "herdrup"
        components.host = "agent"
        components.path = "/\(agentID)"
        return components.url ?? fallback
    }

    static func agentID(from url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "herdrup",
            components.host == "agent",
            components.percentEncodedPath.first == "/"
        else { return nil }
        let encodedID = String(components.percentEncodedPath.dropFirst())
        guard let agentID = encodedID.removingPercentEncoding, !agentID.isEmpty else { return nil }
        return agentID
    }
}

/// The display bucket. Mirrors HerdrKit's `AgentGroup` (needs-you / stopped /
/// working / idle) but is redeclared here so this shared file needs no HerdrKit
/// dependency. `.unrecognised` folds into `.needsYou` at the mapping site — an
/// uninterpretable agent surfaces, it does not sink.
enum AgentActivityStatus: String, Codable, Hashable {
    case needsYou
    case working
    case idle
    case stopped

    /// Short human word for the headline's status line.
    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working:  return "Working"
        case .idle:     return "Idle"
        case .stopped:  return "Stopped"
        }
    }
}

/// The summary wording for a Live Activity, in ONE place and in the ActivityKit-free file
/// so it is testable on Linux. Both widget layouts read it.
///
/// Kept in step with HerdrKit's `AgentList.needsYouSummary`, which serves the in-app roster
/// header. The two cannot be a single function: the widget target links only WidgetKit,
/// SwiftUI and ActivityKit and cannot see HerdrKit, and making HerdrKit depend on this
/// target would put these symbols in the app binary twice. So the wording is duplicated on
/// purpose, and BOTH copies are now pinned by tests against the same table.
enum AgentActivitySummary {
    static func line(_ s: AgentActivityState) -> String {
        if s.needsYouCount > 0 {
            // Every waiting agent rests on an unconfirmed state, so the whole claim is a
            // maybe: say so rather than appending a qualifier to an assertion.
            if s.unconfirmedCount >= s.needsYouCount { return "\(s.needsYouCount) may need you" }
            // Some confirmed and some not. Lead with the fact, name the doubt.
            if s.unconfirmedCount > 0 {
                return "\(s.needsYouCount) need you · \(s.unconfirmedCount) stale"
            }
            return "\(s.needsYouCount) need you"
        }
        if s.workingCount > 0 { return "\(s.workingCount) working" }
        return s.status.label
    }
}

