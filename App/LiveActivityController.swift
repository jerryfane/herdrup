import Foundation
import ActivityKit
import HerdrKit

/// Owns the single agent-session Live Activity: starts it when a session connects,
/// updates it as the agent list changes, ends it on disconnect. Every entry point is
/// a no-op when the user has Live Activities turned off (Settings) or the platform
/// can't run them, so callers never have to guard.
///
/// A singleton (like `PushCenter.shared`) because two layers drive it: `RootView`
/// starts/ends it around connect/disconnect, while the agents list view pushes status
/// updates — neither owns the other, so they share this.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<AgentActivityAttributes>?

    /// Whether the system currently permits Live Activities (user toggle + capability).
    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Start the session activity for `hostLabel`, or — if one is already live (e.g. a
    /// reconnect kept it) — just push the new state. Idempotent: never stacks a second
    /// banner for one session.
    func start(hostLabel: String, state: AgentActivityAttributes.ContentState) {
        guard enabled else { return }
        // ActivityKit PERSISTS activities across app launches: after a kill + relaunch our
        // `activity` is nil while an OS activity may still be live. Reclaim it before starting,
        // so we never orphan the old one and stack a second banner for the same session.
        if activity == nil { activity = Activity<AgentActivityAttributes>.activities.first }
        if activity != nil { update(state); return }
        let attributes = AgentActivityAttributes(hostLabel: hostLabel)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // request() can throw (activities disabled mid-call, too many active).
            // Non-fatal — the app is fully usable without the Live Activity.
            activity = nil
        }
    }

    /// Push a new state to the live activity, if there is one.
    func update(_ state: AgentActivityAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// End and clear the activity immediately (on disconnect / sign-out). Ends EVERY
    /// activity of this type, not just the tracked one, so an orphan left by a prior
    /// process (killed mid-session) can't survive as a stuck banner.
    func end() {
        activity = nil
        Task {
            for a in Activity<AgentActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Mapping HerdrKit → the shared content state

    /// Build a content state from the current agent list. The headline is the
    /// highest-priority agent (lowest `AgentGroup` rawValue: needsYou < stopped <
    /// unrecognised < working < idle), so the surface always leads with whatever most
    /// wants the user's attention.
    static func state(from list: AgentList) -> AgentActivityAttributes.ContentState {
        let rows = list.rows
        let lead = rows.min { $0.group.rawValue < $1.group.rawValue }
        let status: AgentActivityAttributes.Status
        switch lead?.group {
        case .needsYou, .unrecognised: status = .needsYou
        case .stopped:                 status = .stopped
        case .working:                 status = .working
        case .idle, .none:             status = .idle
        }
        return AgentActivityAttributes.ContentState(
            headline: lead?.title ?? "No agents",
            status: status,
            needsYouCount: list.needsYouCount,
            workingCount: rows.filter { $0.group == .working }.count,
            totalCount: rows.count
        )
    }

    /// The state shown at connect, before the first agent list arrives.
    static var connecting: AgentActivityAttributes.ContentState {
        .init(headline: "Connecting…", status: .idle, needsYouCount: 0, workingCount: 0, totalCount: 0)
    }
}
