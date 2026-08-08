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
        // Cold launch FROM a notification tap: the payload is in launchOptions; stash the target so
        // RootView opens it once connected + loaded.
        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any],
           let paneID = payload["pane_id"] as? String {
            PushCenter.shared.tapped(paneID: paneID)
        }
        requestAuthorizationIfWanted(application)
        return true
    }

    /// Ask for notification permission (and register for APNs) only if the user has at least one
    /// push category enabled in Settings — mirrors the existing notify.* toggles so we never prompt
    /// for something they turned off. `RootView` re-runs this when a toggle flips on.
    func requestAuthorizationIfWanted(_ application: UIApplication = .shared) {
        // Never prompt during a buildbox screenshot or an XCUITest run (both set
        // HERDR_SCREENSHOT_MOCK): a permission alert would overlay the screenshot / block the test.
        guard ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] == nil else { return }
        guard PushCenter.Prefs.current.anyEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
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

    // Show the banner + play the sound even while the app is foregrounded.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // A tap on the notification → deep-link to the agent's pane.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let paneID = response.notification.request.content.userInfo["pane_id"] as? String {
            await MainActor.run { PushCenter.shared.tapped(paneID: paneID) }
        }
    }
}
