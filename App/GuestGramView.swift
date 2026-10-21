import HerdrKit
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

    /// The next older page. Throws when it failed, for the feed's sentinel to offer a retry.
    func loadMore(client: HerdrClient, access: GuestAccess) async throws {
        self.access = access
        try await feed.loadMore(client: client)
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

/// The Gram tab: the owner's Gram conversation for the one shared agent. Oldest at the top
/// and pinned to the bottom on the inbox's `WindowedBottomFeed`, with its time separators,
/// sender runs (the name once, the avatar and tail on the run's last message) and file
/// cards, drawn by the inbox's own `GramRow` as a guest viewer. The guest's own posts sit on
/// the right with "Delivered to <agent>" under them. Older pages load when the guest scrolls
/// up to the top; files download in bounded pieces and open in the viewers.
struct GuestGramList: View {
    let client: HerdrClient
    let access: GuestAccess
    @ObservedObject var model: GuestGramModel

    @State private var downloadingID: String?
    @State private var progress: (received: Int, total: Int)?
    @State private var openTask: Task<Void, Never>?
    @State private var preview: GramPreview?
    @State private var fileError: String?
    /// A failed older page, shown ON the sentinel with a retry (as the owner's inbox does):
    /// until the reader taps it, the sentinel's arrivals do not fetch again.
    @State private var pageError: String?
    @State private var visibility = FeedVisibility()
    @State private var appearance = 0
    @State private var landed = false
    @State private var anchorID: String?
    /// The text segments each message's reader opened with "Read more", by message id.
    @State private var expanded: [String: Set<Int>] = [:]
    /// Settings → Text size, as the owner's feed reads it: an `.equatable()` row only
    /// redraws when an input changes, so the scale has to be one of them.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    private static let bottomID = "guest-gram-bottom"

    /// The guest's Grams, oldest first, as the owner's feed draws them.
    private var entries: [GramFeedEntry] {
        GramFeedEntry.entries(oldestFirst: model.messages.reversed().map { $0.gramMessage(agent: access.agentName) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let fileError { notice(fileError, id: "guest-gram-file-error") }
            if let failure = model.failure { notice(failure, id: "guest-gram-failure") }
            if model.messages.isEmpty {
                ScrollView { empty.frame(maxWidth: .infinity) }
                    .refreshable { await model.refresh(client: client, access: access) }
            } else {
                feed
            }
        }
        .gramFileViewer($preview)
        .onDisappear { openTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-list")
    }

    private var feed: some View {
        let rows = entries
        return ScrollViewReader { proxy in
            WindowedBottomFeed(
                feed: proxy,
                items: rows,
                spacing: 0,
                showsSentinel: model.hasMore,
                bottomID: Self.bottomID,
                feedID: "guest-gram-feed",
                messagesID: "guest-gram-messages",
                messagesValue: "\(rows.count) messages",
                columnCap: GramBubble.columnCap,
                visibleTop: 0,
                search: "",
                visibility: visibility,
                appearance: $appearance,
                landed: $landed,
                anchorID: $anchorID,
                // A feed that fits shows the top too. After a hop, as the owner's
                // `feedLanded`: at the landing itself the sentinel can still read as on screen
                // from the first layout at the top, which fetched a page nobody asked for.
                onLanded: { Task { @MainActor in if visibility.sentinelOnScreen { loadOlder(top: rows.first?.id) } } },
                onSentinelArrival: { loadOlder(top: rows.first?.id) },
                sentinel: {
                    Button {
                        // A tap retries the failed page: a fresh, reader-asked fetch.
                        pageError = nil
                        visibility.pageArmed = true
                        loadOlder(top: rows.first?.id)
                    } label: {
                        HStack(spacing: 8) {
                            if let pageError {
                                GramPageFailureLabel(message: pageError)
                            } else {
                                ProgressView().controlSize(.small)
                                Text("Loading older messages…")
                            }
                        }
                        .font(Typography.app(12))
                        .foregroundStyle(Palette.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(pageError == nil)
                    .accessibilityIdentifier("guest-gram-loading-older")
                },
                row: { index, entry in
                    GramFeedRow(index: index, entry: entry) {
                        row(entry)
                    }
                },
                footer: { EmptyView() }
            )
            // A new Gram follows in while the guest is at the bottom, as the inbox does.
            .onChange(of: model.messages.first?.id) { _, _ in
                guard landed, visibility.atBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .refreshable { await model.refresh(client: client, access: access) }
        }
        // The top of the feed fades into the tab strip, as the owner's feed does under its header.
        .overlay(alignment: .top) {
            GramGroundFade().frame(height: 16)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func row(_ entry: GramFeedEntry) -> some View {
        let message = entry.message
        return GramRow(
            message: message,
            isDownloadingFile: downloadingID == message.id,
            downloadProgress: downloadingID == message.id ? progress : nil,
            feedLanded: landed,
            isSaved: false,
            expandedSegments: expanded[message.id] ?? [],
            fontScale: uiFontScale,
            onOpenFile: { open(message.id) },
            onSaveFile: {},
            onPrefetchImage: {},
            onToggleSave: {},
            onDelete: {},
            onSetExpanded: { segment, open in
                if open { expanded[message.id, default: []].insert(segment) } else { expanded[message.id]?.remove(segment) }
            },
            startsGroup: entry.startsGroup,
            endsGroup: entry.endsGroup,
            viewer: .guest
        )
        // A page render (a keystroke, a poll, a file's progress) skips every row whose
        // inputs are unchanged (`GramRow.==`), as in the owner's feed.
        .equatable()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-gram-row-\(message.id)")
    }

    /// One older page per arrival at the top, after the feed landed; the message on top now
    /// is put back at the top once the page is drawn above it. Not over a failure: that waits
    /// for the reader's tap on the sentinel.
    private func loadOlder(top: String?) {
        guard landed, visibility.pageArmed, !visibility.anchoring, !visibility.pageRequested,
              pageError == nil, model.hasMore else { return }
        visibility.pageArmed = false
        visibility.pageRequested = true
        let before = model.messages.count
        Task {
            do {
                try await model.loadMore(client: client, access: access)
            } catch {
                pageError = "Couldn't load older messages."
            }
            visibility.pageRequested = false
            if model.messages.count > before {
                if let top { anchorID = top }
            } else {
                // Nothing landed, so no anchor scroll will re-arm: the next arrival may fetch.
                visibility.pageArmed = true
            }
        }
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
            .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Files

    /// Downloads the file in bounded pieces and opens it: markdown rendered, HTML and SVG in
    /// the in-app viewer (script off unless allowed), anything else in QuickLook, whose share
    /// button saves or sends it.
    private func open(_ id: String) {
        guard downloadingID == nil, let message = model.messages.first(where: { $0.id == id }),
              let file = message.file else { return }
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
        preview = try GramPreviewRouter.preview(data: data, name: name, mime: mime, cachedAt: nil)
        #if DEBUG
        GuestMockTransport.noteOpened(name)
        #endif
    }
}
