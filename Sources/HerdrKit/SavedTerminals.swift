import Foundation

/// One user-opened plain-shell terminal, remembered app-side.
///
/// A terminal created via `pane.split` (with no `agent.start`) is a plain shell pane.
/// Such a pane never appears in `agent.list` — that census is agent-only by construction —
/// so the app has to remember the panes it opened as terminals to relist and reopen them.
/// This record is device-local and secret-free (just a pane id + a label), so it lives in
/// UserDefaults as JSON, mirroring the other small stores in the app.
public struct SavedTerminal: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The daemon pane id the shell runs in; the terminal reopens by streaming this.
    public let paneID: String
    /// User-facing label, e.g. "Terminal 1". Editable.
    public var label: String
    /// When it was opened (ms since epoch), for stable ordering.
    public let createdUnixMs: UInt64

    public init(id: UUID = UUID(), paneID: String, label: String, createdUnixMs: UInt64) {
        self.id = id
        self.paneID = paneID
        self.label = label
        self.createdUnixMs = createdUnixMs
    }
}

/// The remembered terminals, with the pure add/remove/rename/relabel logic kept free of
/// Combine/UserDefaults so it is unit-testable on any platform. The app wraps this in an
/// `ObservableObject` that adds persistence (see `SavedTerminalsStore`).
public struct SavedTerminals: Codable, Equatable, Sendable {
    public private(set) var terminals: [SavedTerminal]

    public init(terminals: [SavedTerminal] = []) {
        self.terminals = terminals
    }

    /// Remember a freshly created terminal pane, auto-labeled with the lowest free
    /// "Terminal N". Returns the added record. `id` is injectable for deterministic tests.
    @discardableResult
    public mutating func add(paneID: String, createdUnixMs: UInt64, id: UUID = UUID()) -> SavedTerminal {
        let terminal = SavedTerminal(
            id: id,
            paneID: paneID,
            label: Self.nextLabel(existing: terminals.map(\.label)),
            createdUnixMs: createdUnixMs
        )
        terminals.append(terminal)
        return terminal
    }

    public mutating func remove(id: UUID) {
        terminals.removeAll { $0.id == id }
    }

    /// Forget any terminal backed by a given pane (e.g. after its shell exits and the
    /// user dismisses it).
    public mutating func removePane(_ paneID: String) {
        terminals.removeAll { $0.paneID == paneID }
    }

    /// Rename a terminal. A blank label is refused (the auto-label stays).
    public mutating func rename(id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[index].label = trimmed
    }

    /// The next default label: "Terminal N" for the lowest positive `N` whose label is not
    /// already taken, so deleting "Terminal 2" and adding again reuses 2 rather than climbing
    /// forever. Custom (non-"Terminal N") labels are simply ignored by the numbering.
    static func nextLabel(existing: [String], prefix: String = "Terminal ") -> String {
        var used = Set<Int>()
        for label in existing where label.hasPrefix(prefix) {
            if let n = Int(label.dropFirst(prefix.count)), n > 0 {
                used.insert(n)
            }
        }
        var n = 1
        while used.contains(n) { n += 1 }
        return "\(prefix)\(n)"
    }
}
