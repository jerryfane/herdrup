import Foundation
import Observation
import HerdrKit

/// The owner's agent folders and stars for one connection (herdrup#552), and which folders are
/// open on this device.
///
/// One per connected home (`TerminalHomeView`, remounted on every reconnect, so a reconnect
/// loads the document again). Nothing shows until the server advertises `agent_groups` and the
/// first `agent.groups.get` has answered: an older server, or a guest, sees the list as before.
///
/// An edit shows at once: `document` is the server's last document with this device's unsent
/// edits applied. Edits are sent one at a time; on `groups_conflict` the edit is applied once
/// more to the server's current document (`AgentGroupsDocument.commit`). An edit that still
/// fails is dropped, the list falls back to the server's document, and `error` says so.
@MainActor @Observable
final class AgentGroupsStore {
    /// What the list draws. Nil while folders are unavailable: no folder rows, no star or
    /// move actions.
    private(set) var document: AgentGroupsDocument?
    /// Folder ids open on this device. Kept per server in UserDefaults, never synced.
    private(set) var openFolders: Set<String> = []
    /// A save that failed, shown once as an alert.
    var error: String?

    @ObservationIgnored private var client: HerdrClient?
    @ObservationIgnored private var supported = false
    @ObservationIgnored private var confirmed: AgentGroupsDocument?
    @ObservationIgnored private var pending: [AgentGroupsEdit] = []
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var openKey: String?
    private let defaults: UserDefaults

    /// How often a connected list re-reads the document, so a change made on another device
    /// (or a rename the server applied) shows without reconnecting.
    private static let refreshInterval: TimeInterval = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Where this device keeps the open folders for the server `host`.
    nonisolated static func openFoldersKey(host: String) -> String { "agentFolders.open.\(host)" }

    /// Binds the store to this connection and restores this device's open folders for `host`.
    func attach(client: HerdrClient, host: String) {
        self.client = client
        let key = Self.openFoldersKey(host: host)
        guard key != openKey else { return }
        openKey = key
        let stored = Set(defaults.stringArray(forKey: key) ?? [])
        if stored != openFolders { openFolders = stored }
    }

    /// The ping's answer: whether the server advertises `agent_groups`. Without it everything
    /// is hidden.
    func setSupported(_ advertised: Bool) {
        supported = advertised
        if !advertised { reset() }
    }

    /// Loads the document on first use, then at most once a minute unless `force` (after a
    /// rename, which the server applies to folders and stars). Skipped while an edit of this
    /// device's is unsent, so a read cannot undo it on screen.
    func refresh(force: Bool = false) async {
        guard supported, let client, !fetching, pending.isEmpty else { return }
        let now = Date()
        if !force, let lastFetch, now.timeIntervalSince(lastFetch) < Self.refreshInterval { return }
        fetching = true
        defer { fetching = false }
        do {
            let fetched = try await client.agentGroupsGet()
            lastFetch = now
            // A save that answered meanwhile may already hold a newer revision.
            guard supported, pending.isEmpty else { return }
            if let confirmed, fetched.revision < confirmed.revision { return }
            confirmed = fetched
            publish()
        } catch AgentGroupsError.unsupported {
            setSupported(false)
        } catch AgentGroupsError.forbidden {
            setSupported(false)
        } catch {
            // A transport hiccup: keep what is shown and try again on a later load.
        }
    }

    // MARK: edits

    func isStarred(_ row: AgentRow) -> Bool {
        guard let name = row.info.name else { return false }
        return document?.isStarred(name) ?? false
    }

    func folder(of row: AgentRow) -> AgentFolder? {
        row.info.name.flatMap { document?.folder(containing: $0) }
    }

    /// Applies `edit` on screen now and queues it for the server.
    func apply(_ edit: AgentGroupsEdit) {
        guard confirmed != nil else { return }
        pending.append(edit)
        publish()
        if !sending { Task { await send() } }
    }

    /// A new folder holding `member`, named `rawName` (trimmed, at most 64 characters). It
    /// opens on this device, so the agent just moved stays in sight.
    func createFolder(named rawName: String, member: String?) {
        guard let name = AgentGroupsDocument.folderName(rawName) else { return }
        let id = AgentGroupsDocument.newFolderID()
        apply(.addFolder(id: id, name: name, member: member))
        setOpen(id, true)
    }

    func toggleOpen(_ folderID: String) {
        setOpen(folderID, !openFolders.contains(folderID))
    }

    private func setOpen(_ folderID: String, _ open: Bool) {
        var next = openFolders
        if open { next.insert(folderID) } else { next.remove(folderID) }
        guard next != openFolders else { return }
        openFolders = next
        if let openKey { defaults.set(next.sorted(), forKey: openKey) }
    }

    private func send() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while let edit = pending.first, let base = confirmed, let client {
            var saved: AgentGroupsDocument?
            var failure: String?
            do {
                saved = try await AgentGroupsDocument.commit(edit, onto: base) {
                    try await client.agentGroupsSet($0)
                }
            } catch AgentGroupsError.conflict(let current) {
                saved = current
                failure = "Your folders changed on another device at the same time. Try again."
            } catch AgentGroupsError.invalid(let message) {
                failure = "The server refused the change: \(message)"
            } catch AgentGroupsError.unsupported, AgentGroupsError.forbidden {
                setSupported(false)
                return
            } catch {
                failure = "Couldn't save folders: \(error.localizedDescription)"
            }
            // Folders went away while the set was out (the connection's ping said so).
            guard supported, !pending.isEmpty else { return }
            if let saved { confirmed = saved }
            if let failure { error = failure }
            pending.removeFirst()
            publish()
        }
    }

    private func publish() {
        let next = confirmed.map { base in pending.reduce(base) { $1.applied(to: $0) } }
        if next != document { document = next }
    }

    private func reset() {
        confirmed = nil
        pending = []
        lastFetch = nil
        if document != nil { document = nil }
    }
}
