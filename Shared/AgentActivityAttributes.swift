import Foundation
import ActivityKit

/// The shape of the Herdr agent-session Live Activity — shared verbatim by the app
/// (which starts / updates / ends it) and the widget extension (which renders it).
///
/// Deliberately free of SwiftUI and HerdrKit so the one file compiles into BOTH
/// targets with no extra dependencies. The app maps HerdrKit's `AgentGroup` onto
/// `Status` when it builds a state (see `LiveActivityController`); the widget only
/// ever reads these plain values.
///
/// One Live Activity represents ONE SSH session (one machine). Its dynamic
/// `ContentState` summarises the session's agents: a representative *headline* agent
/// (the highest-priority one — something that needs you outranks something merely
/// working, which outranks idle) plus counts, so the surface can say "2 need you".
struct AgentActivityAttributes: ActivityAttributes {
    typealias ContentState = State

    /// Fixed for the life of the activity: which machine this session is on
    /// (the saved host's nickname if it has one, else the host itself).
    var hostLabel: String

    struct State: Codable, Hashable {
        /// The agent shown in the headline — the session's highest-priority one.
        var headline: String
        /// That agent's bucket: drives the colour and the status word.
        var status: Status
        /// How many agents are waiting on the user right now.
        var needsYouCount: Int
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
    }

    /// The display bucket. Mirrors HerdrKit's `AgentGroup` (needs-you / stopped /
    /// working / idle) but is redeclared here so this shared file needs no HerdrKit
    /// dependency. `.unrecognised` folds into `.needsYou` at the mapping site — an
    /// uninterpretable agent surfaces, it does not sink.
    enum Status: String, Codable, Hashable {
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
}
