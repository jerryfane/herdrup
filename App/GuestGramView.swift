import HerdrKit
import QuickLook
import SwiftUI
import UIKit

/// The two tabs of a guest's agent screen. Gram shows only when the owner shares it.
enum GuestPaneTab: Hashable { case terminal, gram }

/// A guest's Gram for the shared agent (herdrup#338): the agent's Grams since the grant and
/// the guest's own posts, newest first, with the guest's own read marks. The state and its
/// ordering rules live in HerdrKit's `GuestGramFeed`; this republishes it for SwiftUI.
@MainActor
final class GuestGramModel: ObservableObject {
    @Published private(set) var messages: [GuestGramMessage] = []
    @Published private(set) var loaded = false
    @Published private(set) var failure: String?
    @Published private(set) var hasMore = false

    private let feed = GuestGramFeed()
    private var access: GuestAccess?

    init() {
        feed.onChange = { [weak self] in self?.publish() }
    }

    var unreadCount: Int { messages.filter(\.isUnread).count }

    /// Reloads the newest page; an overtaken refresh applies nothing.
    func refresh(client: HerdrClient, access: GuestAccess) async {
        self.access = access
        await feed.refresh(client: client)
    }

    func loadMore(client: HerdrClient, access: GuestAccess) async {
        self.access = access
        await feed.loadMore(client: client)
    }

    func markAllRead(client: HerdrClient) async {
        await feed.markAllRead(client: client)
    }

    private func publish() {
        if messages != feed.messages { messages = feed.messages }
        if loaded != feed.loaded { loaded = feed.loaded }
        if hasMore != feed.hasMore { hasMore = feed.hasMore }
        let described = feed.lastError.map(describe)
        if failure != described { failure = described }
    }

    private func describe(_ error: Error) -> String {
        let owner = access?.ownerName ?? "The owner"
        let agent = access?.agentName ?? "this agent"
        switch GuestError.classify(error) {
        case .forbidden?: return "\(owner) doesn't share \(agent)'s Gram with you."
        case let guest?: return guest.description
        case nil: return "Couldn't load Gram: \(error.localizedDescription)"
        }
    }
}

/// The Gram tab's list: rows, file downloads and the viewers they open.
struct GuestGramList: View {
    let client: HerdrClient
    let access: GuestAccess
    @ObservedObject var model: GuestGramModel

    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false
    @State private var downloadingID: String?
    @State private var progress: (received: Int, total: Int)?
    @State private var openTask: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var webDoc: WebDoc?
    @State private var fileError: String?

    private struct WebDoc: Identifiable {
        let id = UUID()
        let title: String
        let html: String
        let fileURL: URL
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let fileError {
                    notice(fileError, id: "guest-gram-file-error")
                }
                if let failure = model.failure {
                    notice(failure, id: "guest-gram-failure")
                }
                if model.messages.isEmpty {
                    empty
                }
                ForEach(model.messages) { message in
                    GuestGramRow(
                        message: message, agentName: access.agentName,
                        isDownloading: downloadingID == message.id,
                        progress: downloadingID == message.id ? progress : nil,
                        onOpenFile: { open(message) })
                }
                if model.hasMore {
                    ProgressView().tint(Palette.textDim)
                        .frame(height: 44)
                        .task { await model.loadMore(client: client, access: access) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            // iPad / Mac: the inbox's readable conversation column, so the guest's own posts on
            // the right stay near the agent's on the left.
            .readableColumn(GramBubble.columnCap)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await model.refresh(client: client, access: access) }
        .quickLookPreview($previewURL)
        .fullScreenCover(item: $webDoc) { doc in
            NavigationStack {
                HtmlWebView(html: doc.html, allowsJavaScript: previewJavaScript)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(doc.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { webDoc = nil }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: doc.fileURL)
                        }
                    }
            }
            .onDisappear { try? FileManager.default.removeItem(at: doc.fileURL.deletingLastPathComponent()) }
        }
        // A viewed file doesn't linger in tmp once its viewer closes or is replaced.
        .onChange(of: previewURL) { old, new in
            if let old, old != new { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
        .onDisappear {
            openTask?.cancel()
            if let previewURL { try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent()) }
        }
        .accessibilityIdentifier("guest-gram-list")
    }

    @ViewBuilder private var empty: some View {
        if model.loaded && model.failure == nil {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.textDim)
                    .frame(width: 46, height: 46)
                    .background(Palette.surfaceRaised, in: Circle())
                Text("No Grams yet")
                    .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text("What \(access.agentName) sends \(access.ownerName) from now on shows here, with its files.")
                    .font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 60).padding(.horizontal, 20)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("guest-gram-empty")
        } else if !model.loaded {
            ProgressView().tint(Palette.textDim).padding(.top, 60)
        }
    }

    private func notice(_ text: String, id: String) -> some View {
        Text(text)
            .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .accessibilityIdentifier(id)
    }

    // MARK: Files

    /// Downloads the file in bounded pieces and opens it: markdown rendered, HTML and SVG in
    /// the in-app viewer (script off unless allowed), anything else in QuickLook, whose share
    /// button saves or sends it.
    private func open(_ message: GuestGramMessage) {
        guard downloadingID == nil, let file = message.file else { return }
        downloadingID = message.id
        progress = nil
        fileError = nil
        openTask = Task {
            defer { downloadingID = nil; progress = nil }
            do {
                let (name, mime, data) = try await client.gramGetFileChunked(
                    id: message.id, expectedSize: file.size) { received, total in
                    Task { @MainActor in progress = (received, total) }
                }
                if Task.isCancelled { return }
                try present(data: data, name: name, mime: mime)
            } catch is CancellationError {
            } catch {
                if GuestError.classify(error) == .forbidden {
                    fileError = "\(access.ownerName) doesn't share this file with you."
                } else {
                    fileError = "Couldn't open the file: \((error as? APIError)?.message ?? error.localizedDescription)"
                }
            }
        }
    }

    private func present(data: Data, name: String, mime: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-gram-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if GramView.isMarkdown(name: name, mime: mime), let text = String(data: data, encoding: .utf8) {
            let html = Markdown.toStyledHTML(text, title: GramView.displayTitle(name))
            let url = dir.appendingPathComponent(GramView.previewHTMLName(for: name))
            try Data(html.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            previewURL = url
        } else if GramView.isWebDocument(name: name, mime: mime) {
            let url = dir.appendingPathComponent(GramStaging.safeFileName(name))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            webDoc = WebDoc(title: GramView.webBaseName(name), html: String(decoding: data, as: UTF8.self),
                            fileURL: url)
        } else {
            let url = dir.appendingPathComponent(GramStaging.safeFileName(name))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            previewURL = url
        }
        #if DEBUG
        GuestMockTransport.noteOpened(name)
        #endif
    }
}

/// One Gram: the agent's, or the guest's own post, with its file, drawn with the inbox's
/// parts (`GramLoneMessage`): its bubble and tail, the agent's avatar, and the file as the
/// inbox's file or expired card. The guest's own posts sit on the right, as the owner's do.
private struct GuestGramRow: View {
    let message: GuestGramMessage
    let agentName: String
    let isDownloading: Bool
    let progress: (received: Int, total: Int)?
    let onOpenFile: () -> Void

    private var mine: Bool { !message.isFromAgent }

    var body: some View {
        GramLoneMessage(
            text: message.text, sender: message.from, mine: mine,
            hasCard: message.file != nil || message.expiredFile != nil,
            menu: { menu },
            header: { header },
            card: card(embedded:)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-row-\(message.id)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(message.isFromAgent ? message.from : "You → \(agentName)")
                .font(Typography.app(12, .semibold)).foregroundStyle(Palette.textDim)
                .lineLimit(1)
            if message.isUnread {
                Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }
            Text(GramRow.age(from: message.createdAt))
                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
        }
    }

    /// A guest can copy a message's text; the file opens from its card (the viewer's Share
    /// saves it).
    @StableMenuBuilder
    private var menu: [StableMenuItem] {
        if !message.text.isEmpty {
            StableMenuItem("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            }
        }
    }

    /// The file's card, which opens it; a file the host's store expired (herdr#298) draws the
    /// inbox's expired card, with nothing to open.
    @ViewBuilder
    private func card(embedded: Bool) -> some View {
        if let file = message.file {
            GramFileCard(
                name: file.name,
                kind: GramFileCard.kind(name: file.name, mime: file.mime),
                byteCount: Int(clamping: file.size),
                download: isDownloading ? GramCardDownload.chunked(progress) : nil,
                onOpen: onOpenFile,
                onSave: nil,
                embedded: embedded,
                identifier: "guest-gram-file-\(message.id)"
            )
            .disabled(isDownloading)
        } else if let expired = message.expiredFile {
            GramExpiredFileCard(name: expired.name, byteCount: Int(clamping: expired.size),
                                embedded: embedded, identifier: "guest-gram-expired-\(message.id)")
        }
    }
}
