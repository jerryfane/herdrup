import Foundation
import Security

/// A saved connection target for one-tap reconnect. Holds ONLY the non-secret
/// fields (host — which may include ":port" — and username). The private key is
/// NEVER stored here; it lives in the Keychain (`KeychainCredentialStore`), keyed
/// by `id`. So the on-disk (UserDefaults) list can be read without exposing a key.
struct SavedHost: Codable, Identifiable, Hashable {
    let id: UUID
    var host: String
    var username: String
    /// Optional friendly label ("My Mac"). Legacy saved hosts predate this field, so it
    /// is OPTIONAL — old JSON without the key decodes to `nil` (no migration needed).
    var nickname: String?

    /// The primary display label: the nickname if set, else the host itself.
    var label: String {
        if let n = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return host
    }
}

/// Persists saved hosts: the host+username list in UserDefaults, each host's
/// private key in the Keychain (device-local, unlock-gated). The two are kept in
/// lockstep — `save` only records a host once its key persists, and `delete`
/// removes both — so a listed host is always one-tap reconnectable.
final class SavedHostsStore: ObservableObject {
    static let shared = SavedHostsStore()

    private let defaultsKey = "dev.herdr.savedHosts.v1"
    private let keychain = KeychainCredentialStore(service: "dev.herdr.credentials")

    @Published private(set) var hosts: [SavedHost]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
    }

    /// Adds a NEW saved host (its own id) and stores its key in the Keychain. Returns
    /// false — WITHOUT recording the host — if a required field is missing or the key
    /// could not be persisted, so the UI never offers a one-tap host it cannot open.
    @discardableResult
    func add(nickname: String, host: String, username: String, privateKeyPEM: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty, !key.isEmpty else { return false }
        let id = UUID()
        // Persist the key FIRST; only record the host if the key actually stuck.
        guard keychain.save(account: id.uuidString, secret: key) else { return false }
        hosts.insert(SavedHost(id: id, host: h, username: u, nickname: n.isEmpty ? nil : n), at: 0)
        persist()
        return true
    }

    /// Updates an existing saved host IN PLACE (by id): host / username / nickname, and
    /// the private key only when `privateKeyPEM` is non-empty (empty = keep the current
    /// key, so an edit never forces re-entering it). Returns false without changing
    /// anything if a required field is missing or a provided key fails to persist.
    @discardableResult
    func update(_ existing: SavedHost, nickname: String, host: String, username: String, privateKeyPEM: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !u.isEmpty else { return false }
        guard let i = hosts.firstIndex(where: { $0.id == existing.id }) else { return false }
        // Replace the key only if a new one was entered; a failed persist aborts the whole
        // update so the record never drifts out of lockstep with the Keychain.
        if !key.isEmpty {
            guard keychain.save(account: existing.id.uuidString, secret: key) else { return false }
        }
        hosts[i].host = h
        hosts[i].username = u
        hosts[i].nickname = n.isEmpty ? nil : n
        persist()
        return true
    }

    /// The private key for a saved host, from the Keychain. Nil if missing/unreadable
    /// — the caller must treat that as "cannot reconnect", not "empty key".
    func key(for host: SavedHost) -> String? { keychain.load(account: host.id.uuidString) }

    /// Removes a saved host. Deletes the KEY first and drops the host record ONLY if
    /// the key is confirmed gone — a failed Keychain delete must not leave the private
    /// key orphaned while the host vanishes from the UI. Returns whether it removed;
    /// on false the row stays put (a visible "it didn't remove") so the user can retry.
    @discardableResult
    func delete(_ host: SavedHost) -> Bool {
        guard keychain.delete(account: host.id.uuidString) else { return false }
        hosts.removeAll { $0.id == host.id }
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// A Keychain store for per-host secrets (the private SSH key). Mirrors
/// `KeychainHostKeyPolicy`'s storage discipline — checked statuses, update-in-place
/// rather than delete-then-add — but is its own service and uses
/// `WhenUnlockedThisDeviceOnly`: a private key is more sensitive than a host-key
/// pin, so it is reachable only while the device is unlocked and NEVER syncs to
/// iCloud or another device. The secret is only ever returned by `load`; it is
/// never logged or surfaced elsewhere.
struct KeychainCredentialStore {
    let service: String

    @discardableResult
    func save(account: String, secret: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update the value IN PLACE if the item exists (no window where the key is
        // absent); only add when there is nothing to update. Every status checked.
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }
        return secret
    }

    /// Deletes the secret. Returns true only when it is actually GONE — errSecSuccess
    /// (deleted) or errSecItemNotFound (already absent). Any other OSStatus (e.g. the
    /// Keychain temporarily unavailable) returns false, so the caller does not drop the
    /// host record while the key still lives here.
    @discardableResult
    func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
