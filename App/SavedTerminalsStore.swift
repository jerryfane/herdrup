import Combine
import Foundation
import HerdrKit

/// Persists the terminals the user has opened (plain shell panes) as JSON in UserDefaults,
/// PARTITIONED BY HOST so each connected box shows only its own panes.
///
/// A shell pane created via `pane.split` (with no `agent.start`) never appears in `agent.list` — that
/// census is agent-only — so the app must remember the panes it opened as terminals to relist and
/// reopen them. A terminal is a pane on ONE daemon, so the list must be scoped to the connected host;
/// a single global list wrongly surfaced other hosts' panes. Device-local and secret-free (a pane id
/// + a label), so it needs no Keychain. A singleton `ObservableObject` so the Terminals section
/// updates live. The pure per-host list logic lives in HerdrKit's tested `HostScopedTerminals`.
final class SavedTerminalsStore: ObservableObject {
    static let shared = SavedTerminalsStore()

    private let defaultsKey = "dev.herdr.savedTerminals.v2"
    private let legacyKey = "dev.herdr.savedTerminals.v1"
    @Published private(set) var book: HostScopedTerminals
    /// The pre-scoping flat list, held until the first host connects so it can inherit it (see
    /// `migrateLegacyIfNeeded`). nil once consumed, or if there was nothing to migrate.
    private var legacyPending: SavedTerminals?

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(HostScopedTerminals.self, from: data) {
            book = decoded
        } else {
            book = HostScopedTerminals()
            // First run on the per-host schema: keep the old global list to fold into whichever host
            // connects first (preserves the owner's named terminals on their main box).
            if let legacyData = UserDefaults.standard.data(forKey: legacyKey),
               let legacy = try? JSONDecoder().decode(SavedTerminals.self, from: legacyData),
               !legacy.terminals.isEmpty {
                legacyPending = legacy
            }
        }
    }

    /// Call when a host connection is established (with its canonical key). Folds the legacy global
    /// list into this host once, then never again — a no-op after the first call or when nothing is
    /// pending. Retires the legacy blob so it can't re-migrate.
    func migrateLegacyIfNeeded(host: String) {
        guard let legacy = legacyPending else { return }
        legacyPending = nil
        if book.migrateLegacy(legacy, into: host) {
            persist()
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    func terminals(host: String) -> [SavedTerminal] { book.terminals(host: host) }

    /// Remember a freshly created terminal pane (auto-labeled "Terminal N") on `host`; returns it.
    @discardableResult
    func add(paneID: String, host: String) -> SavedTerminal {
        let created = book.add(paneID: paneID, createdUnixMs: nowUnixMs(), host: host)
        persist()
        return created
    }

    func delete(_ id: UUID, host: String) {
        book.remove(id: id, host: host)
        persist()
    }

    func rename(_ id: UUID, to label: String, host: String) {
        book.rename(id: id, to: label, host: host)
        persist()
    }

    private func nowUnixMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
