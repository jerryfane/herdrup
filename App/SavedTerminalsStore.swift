import Combine
import Foundation
import HerdrKit

/// Persists the terminals the user has opened (plain shell panes) as JSON in UserDefaults.
///
/// A shell pane created via `pane.split` (with no `agent.start`) never appears in
/// `agent.list` — that census is agent-only — so the app must remember the panes it opened
/// as terminals to relist and reopen them. Device-local and secret-free (a pane id + a
/// label), so it needs no Keychain, mirroring `SavedPromptsStore`. A singleton
/// `ObservableObject` so the Terminals section updates live as terminals are opened/closed.
/// The pure list logic lives in HerdrKit's tested `SavedTerminals`.
final class SavedTerminalsStore: ObservableObject {
    static let shared = SavedTerminalsStore()

    private let defaultsKey = "dev.herdr.savedTerminals.v1"
    @Published private(set) var model: SavedTerminals

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SavedTerminals.self, from: data) {
            model = decoded
        } else {
            model = SavedTerminals()
        }
    }

    var terminals: [SavedTerminal] { model.terminals }

    /// Remember a freshly created terminal pane (auto-labeled "Terminal N"); returns it.
    @discardableResult
    func add(paneID: String) -> SavedTerminal {
        let created = model.add(paneID: paneID, createdUnixMs: nowUnixMs())
        persist()
        return created
    }

    func delete(_ id: UUID) {
        model.remove(id: id)
        persist()
    }

    func rename(_ id: UUID, to label: String) {
        model.rename(id: id, to: label)
        persist()
    }

    private func nowUnixMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(model) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
