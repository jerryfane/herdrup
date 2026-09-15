import Foundation
import Combine
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
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<AgentActivityAttributes>?

    /// The tracked activity ONLY while it is still live.
    ///
    /// SWIPING THE BANNER AWAY ON THE LOCK SCREEN ENDS IT. ActivityKit leaves our
    /// reference in place with `activityState == .dismissed`, and `update` on a
    /// dismissed activity is silently dropped — so the plain `activity != nil` check in
    /// `start` reported "one is already live", pushed a state nobody would ever see,
    /// and returned. The banner stayed gone for the rest of the process's life, and the
    /// only way back was force-quitting the app. Every decision about whether one
    /// exists goes through this.
    private var liveActivity: Activity<AgentActivityAttributes>? {
        guard let activity, activity.activityState == .active else { return nil }
        return activity
    }

    /// The current activity's APNs push token (hex), or nil when there is no activity / no token
    /// yet. RootView observes this and registers it with the server so the widget can update in
    /// the BACKGROUND. Published because the token arrives asynchronously after `start`.
    @Published private(set) var pushToken: String?

    /// Watches `activity.pushTokenUpdates`; cancelled/replaced whenever the activity changes.
    private var tokenTask: Task<Void, Never>?

    /// The host the session is for, remembered from `start` so `update` can mint a
    /// REPLACEMENT after the reader swipes the banner away. `hostLabel` is a static
    /// attribute, so a new activity needs it and there is no other way to recover it
    /// mid-session. Cleared by `end`, which is what keeps a disconnected session from
    /// resurrecting its banner.
    private var hostLabel: String?

    /// Whether the system currently permits Live Activities (user toggle + capability).
    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Start the session activity for `hostLabel`, or — if one is already live (e.g. a
    /// reconnect kept it) — just push the new state. Idempotent: never stacks a second
    /// banner for one session.
    func start(hostLabel: String, state: AgentActivityAttributes.ContentState) {
        guard enabled else { return }
        // ActivityKit PERSISTS activities across app launches: after a kill + relaunch our
        // `activity` is nil while an OS activity may still be live. Reclaim it before starting
        // so we never orphan one and stack a second banner — but ONLY if it is for the SAME
        // host. `hostLabel` is a static attribute we cannot update, so a reclaimed activity
        // from a different machine would keep showing the wrong host. End every activity we
        // are not keeping (wrong host, or leftover orphans).
        if liveActivity == nil {
            // Drop a dismissed or ended reference before looking: it is not coming back,
            // and keeping it is what made a swiped-away banner permanent.
            activity = nil
            let existing = Activity<AgentActivityAttributes>.activities.filter {
                $0.activityState == .active
            }
            activity = existing.first { $0.attributes.hostLabel == hostLabel }
            let keep = activity?.id
            if existing.contains(where: { $0.id != keep }) {
                Task {
                    for a in existing where a.id != keep {
                        await a.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        }
        self.hostLabel = hostLabel
        if liveActivity != nil { observePushToken(); update(state); return }
        let attributes = AgentActivityAttributes(hostLabel: hostLabel)
        do {
            // pushType: .token so ActivityKit issues a per-activity push token — the server uses
            // it to update the widget in the BACKGROUND (locked / app closed). Foreground updates
            // still go through update() directly.
            //
            // staleDate IS DELIBERATELY nil. A stale window only says something true if
            // something re-pushes inside it; the only caller of update() is
            // `.onChange(of: fullList)`, AgentList is Equatable, and no timer or heartbeat
            // re-pushes anywhere in this client. A 90s window therefore marked a HEALTHY,
            // stable roster — one agent blocked, waiting for you, the state this activity
            // exists for — as "stale", and the widget then asserted the host was unreachable
            // while the app was connected in the foreground. Until a real liveness signal
            // drives it, this claims nothing.
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: .token
            )
            observePushToken()
        } catch {
            // request() can throw (activities disabled mid-call, too many active).
            // Non-fatal — the app is fully usable without the Live Activity.
            activity = nil
        }
    }

    /// Watch the current activity's push-token stream and publish the latest token as hex, so
    /// RootView can register it with the server for background updates. Re-entrant: cancels any
    /// prior watch first (a reclaimed activity across relaunch re-issues its token here too).
    private func observePushToken() {
        tokenTask?.cancel()
        guard let activity else { pushToken = nil; return }
        tokenTask = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                self?.pushToken = data.map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    /// Push a new state to the live activity, if one is still live. A dismissed
    /// activity is forgotten here too, so the next `start` mints a fresh one instead of
    /// pushing into a banner the reader has already swiped away.
    func update(_ state: AgentActivityAttributes.ContentState) {
        guard let activity = liveActivity else {
            self.activity = nil
            // A DISMISSED banner comes back on the next roster change rather than only
            // on the next reconnect. Swiping it away is not "stop watching this
            // machine" — the session is still live and the app still has something to
            // report — and before this the only cure was force-quitting the app.
            // Guarded by `hostLabel`, which `end` clears, so a session that really did
            // disconnect stays gone.
            if let hostLabel { start(hostLabel: hostLabel, state: state) }
            return
        }
        // staleDate nil for the same reason as in `start`: nothing re-pushes on a cadence,
        // so an elapsed window would mean "the roster did not change", not "the host is gone".
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// End and clear the activity immediately (on disconnect / sign-out). Ends EVERY
    /// activity of this type, not just the tracked one, so an orphan left by a prior
    /// process (killed mid-session) can't survive as a stuck banner.
    func end() {
        tokenTask?.cancel()
        tokenTask = nil
        pushToken = nil
        activity = nil
        hostLabel = nil
        Task {
            for a in Activity<AgentActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Mapping HerdrKit → the shared content state

    /// Copy `AgentList.activityContent` into the activity's own state type. THIS FUNCTION
    /// DECIDES NOTHING, deliberately.
    ///
    /// It used to derive the headline here, first as `rows.min { $0.group.rawValue < ... }`
    /// (the roster's section order answering a different question, which put a red Stopped dot
    /// over a summary reading "N working") and then, after that rule moved to HerdrKit, as a
    /// single `list.activityLead` call. A reviewer showed the second version was barely better
    /// than the first: nothing in the repo executes this function, no test target can see
    /// `App/`, and so the ONE-LINE REVERT back to the buggy expression restored the shipped
    /// defect in full and passed all 446 tests. Pinning the helper was not pinning the path.
    ///
    /// Every decision therefore moved into `activityContent`, where a test does execute it.
    /// What is left here is a field copy, and the one remaining judgement — an unknown status
    /// word — resolves the way the rest of this stack resolves it, toward surfacing rather
    /// than sinking. A cross-target test asserts HerdrKit can only ever emit the four words
    /// this enum accepts, so the fallback is unreachable rather than merely unlikely.
    static func state(from list: AgentList) -> AgentActivityAttributes.ContentState {
        let c = list.activityContent
        return AgentActivityAttributes.ContentState(
            headline: c.headline,
            status: AgentActivityAttributes.Status(rawValue: c.statusWord) ?? .needsYou,
            needsYouCount: c.needsYouCount,
            unconfirmedCount: c.unconfirmedCount,
            workingCount: c.workingCount,
            totalCount: c.totalCount,
            workingSince: c.workingSinceUnixSeconds,
            blockedSince: c.blockedSinceUnixSeconds,
            agentID: c.agentID,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    /// The state shown at connect, before the first agent list arrives.
    static var connecting: AgentActivityAttributes.ContentState {
        .init(headline: "Connecting…", status: .idle, needsYouCount: 0, workingCount: 0, totalCount: 0, workingSince: nil)
    }
}
