import Foundation
import Combine
import SwiftUI
import HerdrKit

/// A locally-saved ("bookmarked") Gram message. A LOCAL COPY of the essentials — not just the
/// id — because gram is a delete-for-good, server-rotated channel with no single-message
/// re-fetch (only whole-list `gramList` + on-demand `gramGetFile`), so an id-only bookmark
/// would orphan the moment the original is deleted. The file BYTES are never copied (they can
/// be up to 100 MiB and are fetched on demand); we only note whether the original had a file.
/// The metadata of a saved message's attachment — enough to show a chip and re-fetch the bytes
/// on demand via `gramGetFile(id:)`. A local Codable mirror of HerdrKit's `GramFile` (which is
/// Decodable-only). The bytes are NOT stored (they can be up to 100 MiB); they're fetched when
/// the chip is tapped, which works while the original message still exists on the server.
struct SavedGramFile: Codable, Hashable {
    let name: String
    let size: UInt64
    let mime: String

    var displaySize: String {
        let b = Double(size)
        if b < 1024 { return "\(size) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

struct SavedGram: Codable, Identifiable, Hashable {
    let id: String
    var text: String
    var from: String
    /// direction == .agentToOwner — so the saved copy can render the same avatar/side.
    var fromAgent: Bool
    var createdUnixMs: UInt64
    /// The attachment's metadata, if any (bytes fetched on demand). Optional so a pre-existing
    /// saved entry (which stored only a `hasFile` flag) still decodes cleanly, to `nil`.
    var file: SavedGramFile?

    var createdAt: Date { Date(timeIntervalSince1970: Double(createdUnixMs) / 1000) }
}

/// Persists the owner's saved Gram messages as JSON in UserDefaults (device-local, secret-free),
/// mirroring `SavedHostsStore` minus the Keychain. An in-memory `Set` of ids gives O(1)
/// `isSaved` for the per-row bookmark toggle (the `MuteStore` idea). Singleton
/// `ObservableObject` so the Gram view's bookmark icons and Saved section update live.
final class SavedGramStore: ObservableObject {
    static let shared = SavedGramStore()

    private let defaultsKey = "dev.herdr.savedGrams.v1"
    /// Newest-first, matching how the Gram list is shown.
    @Published private(set) var saved: [SavedGram]
    private var ids: Set<String>

    init() {
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
                from: message.from,
                fromAgent: message.isFromAgent,
                createdUnixMs: message.createdUnixMs,
                file: message.file.map { SavedGramFile(name: $0.name, size: $0.size, mime: $0.mime) }
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Renders a locally-saved Gram message (a `SavedGram` copy) in the Saved section, mirroring the
/// inbox `GramRow` card. Read-only apart from the un-save bookmark; file bytes are not kept, so a
/// saved attachment shows only a note (its original may already be gone from the server).
struct SavedGramRow: View {
    let saved: SavedGram
    var isDownloadingFile: Bool
    var onOpenFile: () -> Void
    var onSaveFile: () -> Void
    var onUnsave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(saved.fromAgent ? saved.from : "You")
                    .font(Typography.app(13, .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                Text(age)
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
            if !saved.text.isEmpty {
                Text(linkified(saved.text))
                    .font(Typography.app(14))
                    .foregroundStyle(Palette.textDim)
                    .tint(Palette.brand)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let file = saved.file {
                fileChip(file)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairlineQuiet, lineWidth: 1))
    }

    /// A tappable chip that fetches the attachment from the server on demand (`gramGetFile`) and
    /// previews it — works while the original message still exists (it fails gracefully if the
    /// owner has since deleted it, since the bytes were never copied locally).
    private func fileChip(_ file: SavedGramFile) -> some View {
        Button(action: onOpenFile) {
            HStack(spacing: 8) {
                if isDownloadingFile {
                    ProgressView().controlSize(.mini).tint(Palette.textDim)
                } else {
                    Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(Typography.app(12, .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(file.displaySize).font(Typography.machine(10)).foregroundStyle(Palette.textFaint)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.circle").font(.system(size: 13)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDownloadingFile)
        .contextMenu {
            Button { onOpenFile() } label: { Label("Open", systemImage: "eye") }
            Button { onSaveFile() } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
        }
        .padding(.top, 2)
    }

    /// Compact relative age ("now" / "5m" / "3h" / "2d"), matching the inbox row's terse style.
    private var age: String {
        let secs = Date().timeIntervalSince(saved.createdAt)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }
}
