import UIKit
import UserNotifications

/// Owns the APNs registration + notification callbacks (the app is otherwise pure SwiftUI). It only
/// bridges to `PushCenter` — the actual token→server registration and the deep-link are driven by
/// `RootView`, which has the live `HerdrClient` and the nav state. Requesting authorization + a
/// device token is safe even before the server side / entitlement exist: without the
/// `aps-environment` entitlement (e.g. on the Simulator, or before the profile is re-minted) iOS
/// calls `didFailToRegister…` and push simply stays inactive.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A cold launch FROM a notification tap is delivered to `userNotificationCenter(_:didReceive:)`
        // as well (the delegate is set above, synchronously, before the launch tap is dispatched), so
        // we do NOT also read launchOptions[.remoteNotification] here — that would deep-link the same
        // tap twice. The single didReceive path stashes the target for RootView to open once loaded.
        // On launch just REFRESH the token if the user already granted permission — no prompt, so
        // nothing appears on the connect screen (which the buildbox screenshots). The actual
        // permission PROMPT is deferred to `connect()` (see requestAuthorizationIfWanted), because
        // asking before the user has even connected is poor UX.
        Self.refreshTokenIfAuthorized()
        return true
    }

    /// Register for APNs (to refresh the device token) only if permission was already granted — this
    /// never shows a prompt, so it is safe at launch.
    static func refreshTokenIfAuthorized() {
        // One source of truth for "we're in a screenshot/UITest run" — matches ScreenshotMock.mode
        // (env var OR the -herdrScreenshotMock launch arg), so no mock path can slip past an
        // env-only check and prompt/register under test.
        guard ScreenshotMock.mode == nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Refresh for any granted state, including provisional/ephemeral (which also deliver
            // pushes) — not just the full .authorized grant.
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Ask for notification permission (and register for APNs) only if the user has at least one
    /// push category enabled in Settings — mirrors the existing notify.* toggles so we never prompt
    /// for something they turned off. Called from `RootView.connect()` so the prompt appears once
    /// the user is actually using the app, not on the connect screen. Static so RootView can call it
    /// without a reference to the delegate instance.
    static func requestAuthorizationIfWanted() {
        // Never prompt during a buildbox screenshot or an XCUITest run (ScreenshotMock.mode covers
        // both the env var and the -herdrScreenshotMock launch arg).
        guard ScreenshotMock.mode == nil else { return }
        guard PushCenter.Prefs.current.anyEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushCenter.shared.setToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token — no entitlement yet, Simulator, or airplane mode. Push stays inactive; nothing
        // to surface (the Settings screen already tells the user push is best-effort).
    }

    // Show the banner + play the sound even while the app is foregrounded, and ALSO add it to
    // Notification Center (.list) so a user who dismisses or misses the banner still has a record of
    // the agent transition to tap later.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // A tap on the notification → deep-link to the agent's pane.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let paneID = response.notification.request.content.userInfo["pane_id"] as? String {
            await MainActor.run { PushCenter.shared.tapped(paneID: paneID) }
        }
    }
}
