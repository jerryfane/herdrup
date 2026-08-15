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
    /// Set when the user taps a gram push (the payload carries `gram: true`, no pane). The home view
    /// opens the Gram page then clears it. Held here so a cold-launch tap (app was closed) survives
    /// until the view can act, exactly like `pendingPaneID`.
    @Published var pendingGram: Bool = false

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

    /// A gram push was tapped — open the Gram page when the view is ready.
    func tappedGram() {
        pendingGram = true
    }

    /// The user's per-category push preferences (the existing Settings toggles), sent to the server
    /// alongside the token so it only pushes the kinds they want. Defaults match SettingsView.
    struct Prefs: Equatable {
        var needsInput: Bool
        var dies: Bool
        var finishes: Bool
        var gram: Bool
        static var current: Prefs {
            let d = UserDefaults.standard
            return Prefs(
                needsInput: d.object(forKey: "notify.needsInput") as? Bool ?? true,
                dies:       d.object(forKey: "notify.dies") as? Bool ?? true,
                finishes:   d.object(forKey: "notify.finishes") as? Bool ?? false,
                gram:       d.object(forKey: "notify.gram") as? Bool ?? true)
        }
        var anyEnabled: Bool { needsInput || dies || finishes || gram }
    }
}

/// The pane ids the owner has muted for push, per-device. Sent to the server on
/// `notifications.register_device` (the daemon skips a muted pane's pushes), so a
/// mute silences that agent even while the app is closed. Muting is PER-PANE — a
/// new agent gets a new pane id and starts un-muted. A UserDefaults-backed singleton
/// (mirrors PushCenter.Prefs' storage) so the deep terminal header can toggle it and
/// RootView can observe it to re-register.
final class MuteStore: ObservableObject {
    static let shared = MuteStore()
    private let key = "push.mutedPanes"

    @Published private(set) var mutedPanes: Set<String>

    init() {
        mutedPanes = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func isMuted(_ paneID: String) -> Bool { mutedPanes.contains(paneID) }

    /// Set (and persist) a pane's mute. `@Published` publishes the change, so an
    /// observing RootView re-registers the device and the header updates its icon.
    func setMuted(_ muted: Bool, for paneID: String) {
        guard !paneID.isEmpty else { return }
        if muted { mutedPanes.insert(paneID) } else { mutedPanes.remove(paneID) }
        UserDefaults.standard.set(Array(mutedPanes), forKey: key)
    }

    func toggle(_ paneID: String) { setMuted(!isMuted(paneID), for: paneID) }
}
