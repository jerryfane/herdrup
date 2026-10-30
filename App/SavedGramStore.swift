import Foundation
import Combine
import SwiftUI
import HerdrKit

/// A locally-saved ("bookmarked") Gram message. A LOCAL COPY of the essentials — not just the
/// id — because gram is a delete-for-good, server-rotated channel with no single-message
/// re-fetch (only whole-list `gramList` + on-demand `gramGetFile`), so an id-only bookmark
/// would orphan the moment the original is deleted. The file BYTES are never copied (they can
/// be up to 100 MiB and are fetched on demand); we only note whether the original had a file.
/// The metadata of a saved message's attachment — enough to draw its card and re-fetch the bytes
/// on demand via `gramGetFile(id:)`. A local Codable mirror of HerdrKit's `GramFile` (which is
/// Decodable-only). The bytes are NOT stored (they can be up to 100 MiB); they're fetched when
/// the card is tapped, which works while the original message still exists on the server.
struct SavedGramFile: Codable, Hashable {
    let name: String
    let size: UInt64
    let mime: String
}

struct SavedGram: Codable, Identifiable, Hashable {
    let id: String
    var text: String
    /// The sender as shown when saved (a federated sender's machine label, not its alias).
    var from: String
    /// direction == .agentToOwner — so the saved copy can render the same avatar/side.
    var fromAgent: Bool
    var createdUnixMs: UInt64
    /// The attachment's metadata, if any (bytes fetched on demand). Optional so a pre-existing
    /// saved entry (which stored only a `hasFile` flag) still decodes cleanly, to `nil`.
    var file: SavedGramFile?
    /// The attachment the server's store had already expired when this was saved (no bytes
    /// to fetch). Optional, so entries saved before it existed decode to `nil`.
    var expiredFile: SavedGramFile?

    var createdAt: Date { Date(timeIntervalSince1970: Double(createdUnixMs) / 1000) }

    /// The attachment as the sidebar's one-line preview names it (see `GramMessage`'s).
    var attachmentPreview: String? {
        if let file { return file.name }
        return expiredFile.map { GramFile.expiredPreview(of: $0.name) }
    }
}

/// Persists the owner's saved Gram messages as JSON in UserDefaults (device-local, secret-free),
/// mirroring `SavedHostsStore` minus the Keychain. An in-memory `Set` of ids gives O(1)
/// `isSaved` for the per-row bookmark toggle (the `MuteStore` idea). Singleton
/// `ObservableObject` so the Gram view's bookmark icons and Saved section update live.
final class SavedGramStore: ObservableObject {
    static let shared = SavedGramStore()

    private let defaultsKey = "dev.herdr.savedGrams.v1"
    /// Newest-first, like the inbox store's list. The Saved feed draws it as the inbox does:
    /// reversed, oldest at the top and the newest at the bottom (`GramSavedFeed`).
    @Published private(set) var saved: [SavedGram]
    private var ids: Set<String>
    /// Off in DEBUG mock runs, so a UI test's saves and unsaves never reach UserDefaults (a
    /// test that stops between a save and its unsave would otherwise leave it saved).
    private var persists = true

    init() {
        #if DEBUG
        // `HERDR_MOCK_GRAM_SAVED=N`: N saved messages in memory only (gs1 oldest), for the
        // Saved paging UI test. Three lines each, so a window of them overfills any screen.
        if let count = ProcessInfo.processInfo.environment["HERDR_MOCK_GRAM_SAVED"].flatMap(Int.init), count > 0 {
            let seeded = (1...count).reversed().map { n in
                SavedGram(id: "gs\(n)", text: "Saved note \(n).\nLine two.\nLine three.",
                          from: n.isMultiple(of: 2) ? "owner" : "vetrina", fromAgent: !n.isMultiple(of: 2),
                          createdUnixMs: 1_722_000_000_000 + UInt64(n) * 60_000, file: nil)
            }
            saved = seeded
            ids = Set(seeded.map(\.id))
            persists = false
            return
        }
        if ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] != nil {
            saved = []
            ids = []
            persists = false
            return
        }
        #endif
        let decoded: [SavedGram]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let d = try? JSONDecoder().decode([SavedGram].self, from: data) {
            decoded = d
        } else {
            decoded = []
        }
        saved = decoded.sorted { $0.createdUnixMs > $1.createdUnixMs }
        ids = Set(decoded.map(\.id))
    }

    func isSaved(_ id: String) -> Bool { ids.contains(id) }

    /// Save a copy of the message, or un-save it if already saved.
    func toggle(_ message: GramMessage) {
        if ids.contains(message.id) {
            remove(message.id)
        } else {
            let copy = SavedGram(
                id: message.id,
                text: message.text,
                from: message.senderName,
                fromAgent: message.isFromAgent,
                createdUnixMs: message.createdUnixMs,
                file: message.file.map { SavedGramFile(name: $0.name, size: $0.size, mime: $0.mime) },
                expiredFile: message.expiredFile.map { SavedGramFile(name: $0.name, size: $0.size, mime: $0.mime) }
            )
            saved.append(copy)
            saved.sort { $0.createdUnixMs > $1.createdUnixMs }
            ids.insert(message.id)
            persist()
        }
    }

    func remove(_ id: String) {
        guard ids.contains(id) else { return }
        saved.removeAll { $0.id == id }
        ids.remove(id)
        persist()
    }

    /// The store expired these messages' files since they were saved (herdr#298): a saved
    /// copy that still holds a live `file` for one of them moves it to `expiredFile`, so
    /// Saved stops offering an open of bytes that are gone. Called with every inbox answer
    /// (head and older pages); persists only when something moved.
    func expireFiles(in messages: [GramMessage]) {
        var changed = false
        for message in messages where message.expiredFile != nil && ids.contains(message.id) {
            guard let index = saved.firstIndex(where: { $0.id == message.id }),
                  let file = saved[index].file else { continue }
            saved[index].file = nil
            saved[index].expiredFile = file
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard persists else { return }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Renders a locally-saved Gram message (a `SavedGram` copy) in the Saved section with the
/// inbox's parts (`GramLoneMessage`): its bubble and tail, the sender's avatar, and the file as
/// the inbox's file or expired card. Read-only apart from the un-save bookmark. File bytes are
/// not kept, so opening a saved file fetches it again, which works while the original message
/// still exists on the server.
struct SavedGramRow: View {
    let saved: SavedGram
    var isDownloadingFile: Bool
    /// Reply bytes received against bytes expected for THIS row's download. nil means
    /// the transport reports nothing measurable, and the card's ring spins rather than
    /// drawing a share nothing drives. Same contract as `GramRow`.
    var downloadProgress: (received: Int, total: Int)?
    var onOpenFile: () -> Void
    var onSaveFile: () -> Void
    /// Ends the reader's own open or save of this file, as the inbox's menu does.
    var onCancelDownload: () -> Void
    var onUnsave: () -> Void

    /// #354: never joined (Saved is a list of separate keepsakes). Your saved posts sit on the
    /// right with no status line: a saved copy does not record the recipient.
    private var mine: Bool { !saved.fromAgent }

    var body: some View {
        GramLoneMessage(
            text: saved.text, sender: saved.from, mine: mine,
            hasCard: saved.file != nil || saved.expiredFile != nil,
            menu: { menu },
            header: { header },
            card: card(embedded:)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(saved.fromAgent ? saved.from : "You")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textDim)
            Text(GramRow.age(from: saved.createdAt))
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textFaint)
            Button(action: onUnsave) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.brand)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The inbox's menu minus what a saved copy cannot do (Delete; Unsave is the bookmark).
    @StableMenuBuilder
    private var menu: [StableMenuItem] {
        if saved.file != nil {
            if isDownloadingFile {
                StableMenuItem("Cancel Download", systemImage: "xmark.circle", action: onCancelDownload)
            } else {
                StableMenuItem("Save to Files", systemImage: "square.and.arrow.down", action: onSaveFile)
            }
        }
        if !saved.text.isEmpty {
            StableMenuItem("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = saved.text
            }
        }
    }

    /// The saved file's card: tapping it fetches the file again and opens it. An expired file
    /// draws the inbox's expired card, with nothing to open or save.
    @ViewBuilder
    private func card(embedded: Bool) -> some View {
        if let file = saved.file {
            GramFileCard(
                name: file.name,
                kind: GramFileCard.kind(name: file.name, mime: file.mime),
                byteCount: Int(clamping: file.size),
                download: isDownloadingFile ? GramCardDownload.reply(downloadProgress, fileSize: file.size) : nil,
                onOpen: onOpenFile,
                onSave: onSaveFile,
                embedded: embedded
            )
            .disabled(isDownloadingFile)
        } else if let expired = saved.expiredFile {
            GramExpiredFileCard(name: expired.name, byteCount: Int(clamping: expired.size), embedded: embedded)
        }
    }
}
