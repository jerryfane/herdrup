import Foundation

/// Only connection metadata and recipient recency live here. Secrets stay in the
/// app's existing Keychain access group, shared with the extension by entitlement.
enum ShareStorage {
    static let group = "group.com.jerryfane.herdr"
    static let hostsKey = "dev.herdr.savedHosts.v1"
    static let guestsKey = "dev.herdr.sharedMachines.v1"
    static let recentKey = "dev.herdr.shareRecipients.v1"
    static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: group) else {
            preconditionFailure("Shared Herdrup storage is unavailable")
        }
        #if !HERDR_SHARE_EXTENSION
        // One-way migration. Never resurrect a removed entry from old app defaults.
        for key in [hostsKey, guestsKey] {
            if defaults.object(forKey: key) == nil,
               let data = UserDefaults.standard.data(forKey: key) {
                defaults.set(data, forKey: key)
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
        return defaults
    }()
}
