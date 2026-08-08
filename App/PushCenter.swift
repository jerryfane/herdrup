import SwiftUI

/// The bridge between the UIKit `AppDelegate` (which owns the APNs registration + notification
/// callbacks) and the SwiftUI tree. A single shared instance because the delegate lives outside
/// the view hierarchy, and because both the device token and a tapped-notification target must
/// SURVIVE a reconnect — `TerminalHomeView` is `.id(session)` and is torn down on every reconnect,
/// so per-view @State would lose them. `RootView` (never re-`id`'d) observes this and (re)sends the
/// token whenever it has a live client. All mutations happen on the main thread (the AppDelegate
/// hops there before calling in), so `@Published` updates are delivered correctly without a formal
/// `@MainActor` annotation (which SwiftUI View property initializers don't play well with in 5.9).
final class PushCenter: ObservableObject {
    static let shared = PushCenter()

    /// The APNs device token (lowercase hex), set by the AppDelegate on registration. Persisted so
    /// a relaunch/reconnect can re-send it to the server before any new registration callback.
    @Published private(set) var deviceToken: String?
    /// A pane the user tapped a push for (the payload's `pane_id`). The home view consumes it once
    /// its agent list has loaded, then clears it. Held here so a cold-launch tap (app was closed)
    /// and a tap during a reconnect both survive until the view can act on it.
    @Published var pendingPaneID: String?

    private static let tokenKey = "push.deviceToken"

    private init() {
        deviceToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    /// Record a freshly-registered token (idempotent; persisted).
    func setToken(_ token: String) {
        guard token != deviceToken else { return }
        deviceToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    /// A notification was tapped for `paneID` — deep-link to it when the view is ready.
    func tapped(paneID: String) {
        pendingPaneID = paneID
    }

    /// The user's per-category push preferences (the existing Settings toggles), sent to the server
    /// alongside the token so it only pushes the kinds they want. Defaults match SettingsView.
    struct Prefs: Equatable {
        var needsInput: Bool
        var dies: Bool
        var finishes: Bool
        static var current: Prefs {
            let d = UserDefaults.standard
            return Prefs(
                needsInput: d.object(forKey: "notify.needsInput") as? Bool ?? true,
                dies:       d.object(forKey: "notify.dies") as? Bool ?? true,
                finishes:   d.object(forKey: "notify.finishes") as? Bool ?? false)
        }
        var anyEnabled: Bool { needsInput || dies || finishes }
    }
}
