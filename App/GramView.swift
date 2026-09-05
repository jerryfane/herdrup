import CoreTransferable
import HerdrKit
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The unread-gram count, lifted out of `GramView` so the tab bar can badge it
/// even while the Gram tab is off-screen. Owned by the session-scoped home view;
/// GramView writes it on load / mark-read while visible, and an ambient poller
/// keeps it fresh while another tab is showing.
final class GramUnreadTracker: ObservableObject {
    @Published var count = 0
}

/// The Gram page: the owner's side of the owner<->agent message channel.
///
/// The app is the OWNER. This shows the inbox (agent->owner messages the fleet
/// sent, plus the owner's own posts and their claim state) newest-first, and a
/// composer to post to the shared grab-queue or one agent directly, with an
/// optional file attachment. A received file shows a chip that downloads and
/// previews it (QuickLook); long-pressing a message deletes it — and its file
/// bytes — for good, which is what makes gram safe for a short-lived secret like
/// a temporary API key.
///
/// Nav-agnostic: it renders its own content and takes an optional `onClose` — a
/// modal cover passes one (a close button appears); a persistent tab passes nil.
/// It owns its polling and never blocks the caller.
struct GramView: View {
    let client: HerdrClient
    /// Live agents, for the direct-recipient picker. Only named agents can be
    /// addressed directly (the server validates `to` against a live agent name).
    let agents: [AgentInfo]
    var onClose: (() -> Void)?
    /// Shared unread count for the tab-bar badge. Optional (defaulted) so existing
    /// call sites (and the DEBUG harness) compile unchanged; written on load and
    /// mark-read so reading a message clears the badge without leaving the tab.
    var unread: GramUnreadTracker? = nil
    /// Which "conversation" is shown — Inbox (false) or Saved (true). OWNED BY THE HOST, not
    /// by this view, because on regular width the selector lives in the app's real
    /// NavigationSplitView sidebar rather than inside this page. A sibling column cannot drive
    /// a `@State` in here, so the state is hoisted and both layouts read the same binding.
    @Binding var showingSaved: Bool
    /// Bumped by the host to request a reload. The regular-width refresh affordance moved to
    /// the sidebar with the rest of the selector, and a sidebar button cannot call this view's
    /// async `load` directly — so it changes a token and `onChange` performs the load, the same
    /// one-shot-signal pattern the terminal uses for jump-to-tail and collapse.
    var refreshToken: Int = 0
    /// Bumped by the host's sidebar Read-all button, same one-shot-signal reason as
    /// `refreshToken`: a sibling column cannot call this view's async `markAllRead` directly.
    /// Defaulted so the phone call site (which has its own header button) omits it.
    var readAllToken: Int = 0

    /// The last server snapshot (newest first) and the owner's just-posted messages
    /// not yet reflected in a snapshot. `messages` composes them so a background poll
    /// can never drop an optimistic post it hasn't caught up to.
    /// The server snapshot, held in a store that OUTLIVES this view: on iPad the page
    /// is destroyed whenever the section changes, and a view-local list meant every
    /// return re-fetched the whole store behind a spinner. Accessed through
    /// `serverMessages` below so the rest of the page reads unchanged.
    @ObservedObject private var inboxStore = GramInboxStore.shared
    /// The last server snapshot, newest first. Read-only: every mutation goes through
    /// a `GramInbox` method so the digest is invalidated with the change (a locally
    /// altered list must not be re-validated by a digest the daemon issued for the
    /// list before it).
    private var serverMessages: [GramMessage] { inboxStore.inbox.messages }
    @State private var pendingPosts: [GramMessage] = []
    @State private var phase: LoadPhase = .loading
    @State private var recipient: Recipient = .queue
    @State private var draft: String = ""
    /// Focus of the composer field. Bound so a successful send can resign it —
    /// the composer is a multiline (`axis: .vertical`) field with no Return-to-send,
    /// so without this the keyboard has no way to drop and it hides the tab bar.
    @FocusState private var composerFocused: Bool
    /// True while dictating into the composer, so the field is disabled (typing can't be
    /// overwritten by the next partial) while the live transcript still appends.
    @State private var draftDictating = false
    @State private var sending = false
    /// A send failure. Kept SEPARATE from load state so a successful background poll
    /// never clears it before the owner sees it.
    @State private var sendError: String?
    /// A non-fatal refresh failure while messages are already shown.
    @State private var refreshNote: String?
    @State private var isLoading = false
    /// Saved (bookmarked) Gram messages. Whether the Saved section is showing is the host's
    /// `showingSaved` binding above, not local state.
    @ObservedObject private var savedGrams = SavedGramStore.shared
    /// On regular width this page renders the feed + composer only; the Inbox/Saved selector and
    /// the refresh action live in the app's NavigationSplitView sidebar, so there is exactly ONE
    /// sidebar on screen. iPhone keeps its single column with the header toggle.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Messages with a mark-read in flight, so a re-`onAppear` (scroll) does not fire
    /// a duplicate `gram.mark_read`.
    @State private var markingRead: Set<String> = []
    /// Free-text filter over the visible section. Local to the page: it is a transient view
    /// concern, unlike `showingSaved`, which the sidebar owns (a sibling column drives that).
    @State private var search = ""
    /// True while a Read-all pass is running, so the button disables rather than stacking passes.
    @State private var markingAllRead = false
    /// A partial-failure report from a Read-all pass. Its OWN slot rather than `refreshNote`,
    /// which the 6-second poll clears on every success — same reasoning as `sendError`.
    @State private var markAllNote: String?

    /// Files the owner picked to attach to the next post (read into memory at pick
    /// time), empty when none are staged. Several can be staged at once; each sends as
    /// its own gram message (the wire is one-file-per-message).
    @State private var attachedFiles: [PickedAttachment] = []
    @State private var showFileImporter = false
    /// The paperclip opens a Telegram-style attach sheet first, so we know which
    /// system picker to present: the photo library (images/videos) or the document
    /// picker (any file). `pendingPicker` remembers the choice so the picker is opened
    /// AFTER the sheet finishes dismissing (presenting one sheet while another is
    /// dismissing drops the second on iOS).
    @State private var showAttachSheet = false
    private enum PendingPicker { case photos, file }
    @State private var pendingPicker: PendingPicker?
    @State private var showPhotoPicker = false
    /// Items chosen from the photo library (multi-select), loaded into `attachedFiles`.
    @State private var photoItems: [PhotosPickerItem] = []
    /// True while a photo-library batch is loading (iCloud items can take a moment).
    /// Gates Send and the paperclip so a text-only send can't race the load and a
    /// second pick can't start concurrently.
    @State private var loadingPhoto = false
    /// True while a picked file is uploading (many small chunks over SSH).
    @State private var uploading = false
    /// Byte progress of the file currently uploading: (bytesSent, totalBytes). Drives
    /// the composer's determinate progress bar; nil when no upload is in flight.
    @State private var uploadBytes: (sent: Int, total: Int)?
    /// Progress across a multi-file send: (already-sent, total). nil when idle or when
    /// only a single message is in flight.
    @State private var sendProgress: (sent: Int, total: Int)?
    /// Dismissed the "set up gram for your agents" card. It also auto-hides once any
    /// agent has messaged (proof they've set the skill up), so this is the manual out.
    @AppStorage("gram.setupCardDismissed") private var setupCardDismissed = false
    /// The UI text-size setting. Read in `body` only to observe it: `Typography.scale`
    /// is a global static outside SwiftUI's dependency graph, so a parent re-render
    /// does not re-run this separate child struct — without this, Gram would show
    /// old-size text after a size change until it re-rendered for another reason.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// Momentary "Copied ✓" on the setup card's copy button.
    @State private var setupCommandCopied = false
    /// A downloaded file written to a temp URL, presented via QuickLook when set.
    @State private var previewURL: URL?
    /// A received web document (HTML/SVG) staged for the in-app viewer. Rendered by
    /// `HtmlWebView` (JavaScript off, all network blocked) instead of QuickLook, whose
    /// srcdoc-sandbox path showed a blank white screen for these files (issue #92).
    @State private var webDoc: WebDoc?
    /// The in-flight file-open download (see `openFile`), cancelled when the page goes
    /// away so a late completion can't strand a temp file after cleanup already ran.
    @State private var openFileTask: Task<Void, Never>?
    /// The message id whose file is currently downloading, to show a spinner on it.
    @State private var downloadingFileFor: String?
    /// A Gram file downloaded and staged for export through the system document
    /// picker, so the owner saves it to a real, user-chosen location.
    @State private var exportFile: ExportFile?
    /// Ids the server has confirmed deleted, kept as tombstones so an in-flight poll
    /// (whose snapshot predates the delete) cannot resurrect the row for a few
    /// seconds. Cleared once the server's own snapshot also omits the id.
    @State private var deletedIDs: Set<String> = []

    /// A received web document (HTML/SVG) staged for the in-app `HtmlWebView` viewer.
    /// Holds the parsed markup to render plus the raw file on disk so the owner can
    /// still Share/save it (the affordance QuickLook used to offer).
    private struct WebDoc: Identifiable {
        let id = UUID()
        let title: String
        let html: String
        let fileURL: URL
    }

    /// A file staged for sending, held as a COPY ON DISK rather than in memory, so a
    /// batch of large picks costs one open file handle at send time rather than
    /// N × 100 MB resident. `dir` is the per-item staging directory (same idiom as
    /// `ExportFile`); removing it removes the staged bytes.
    /// Identifiable so the composer strip can render + remove chips by identity.
    private struct PickedAttachment: Identifiable {
        let id = UUID()
        let name: String
        let mime: String
        let url: URL
        let dir: URL
        let size: Int
    }

    // The pre-send size gate lives on `Staging` (nonisolated, so the photo importer
    // can read it): `GramView.Staging.maxFileBytes`.
    /// How many files can be staged at once. Each sends as its own gram message.
    ///
    /// 10, matching the photo picker's `maxSelectionCount`. It was cut to 3 when a
    /// staged file was held in memory as `Data`: ten 100 MB picks would have been
    /// ~1 GB resident. Staged bytes now live in a temp file and the upload reads them
    /// one frame at a time, so the resident ceiling is a single frame no matter how
    /// many files are staged or how large they are. The send loop is serial and
    /// `gram.post` consumes each staging file, so the daemon's 1 GiB aggregate
    /// staging budget never sees more than one upload in flight.
    private static let maxAttachments = 10

    /// The list the page renders: optimistic posts first, then the server snapshot
    /// with those posts de-duped out once the server reflects them.
    private var messages: [GramMessage] {
        let pendingIDs = Set(pendingPosts.map(\.id))
        return (pendingPosts + serverMessages.filter { !pendingIDs.contains($0.id) })
            .filter { !deletedIDs.contains($0.id) }
    }

    /// Inbox rows after the search filter. Matches message text, the sender, the recipient,
    /// and an attachment's filename — a reader looking for "the key I sent keephair" searches
    /// by any of those, and matching only `text` would miss the last two.
    ///
    /// DELIBERATELY SEPARATE from `messages`: the unfiltered set is what `unreadCount`,
    /// `markReadIfNeeded` and `markAllRead` read, so an active search can never make the
    /// badge lie or hide a message from a Read-all pass. Do not fold the filter into
    /// `messages` itself.
    private var visibleMessages: [GramMessage] {
        guard !search.isEmpty else { return messages }
        return messages.filter { message in
            message.text.localizedCaseInsensitiveContains(search)
                || message.from.localizedCaseInsensitiveContains(search)
                || (message.to ?? "").localizedCaseInsensitiveContains(search)
                || (message.file?.name ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Saved rows after the same filter. `SavedGram` has no `to`, so sender + text + filename.
    private var visibleSaved: [SavedGram] {
        guard !search.isEmpty else { return savedGrams.saved }
        return savedGrams.saved.filter { saved in
            saved.text.localizedCaseInsensitiveContains(search)
                || saved.from.localizedCaseInsensitiveContains(search)
                || (saved.file?.name ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private enum LoadPhase: Equatable {
        case loading
        case loaded
        /// The server does not offer gram yet (older daemon), or another load error.
        case unavailable(String)
    }

    /// Where a composed message goes.
    private enum Recipient: Hashable {
        case queue
        case agent(String)

        var wireTo: String? {
            switch self {
            case .queue: return nil
            case .agent(let name): return name
            }
        }
        var label: String {
            switch self {
            case .queue: return "Shared queue"
            case .agent(let name): return name
            }
        }
    }

    /// Named agents, de-duplicated, sorted — the addressable direct recipients.
    private var addressableAgents: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for agent in agents {
            guard let name = agent.name, !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    var body: some View {
        // Observe the text-size setting so Gram re-renders at the new Typography.scale.
        let _ = uiFontScale
        return Group {
            if hSizeClass == .regular {
                iPadBody
            } else {
                phoneBody
            }
        }
        .background(Palette.ground.ignoresSafeArea())
        // Poll while the page is open so new agent messages appear without a manual
        // refresh (the gram store has no event stream); the loop ends when the view
        // goes away (task cancellation).
        .task { await pollLoop() }
        // The sidebar's refresh button bumps `refreshToken`; consume the change here so a
        // sibling column can drive this view's async reload without owning its state. Guarded on
        // a real change (SwiftUI may re-run the body for unrelated reasons) and on `initial:
        // false` so it refreshes in place instead of dropping back to the loading phase.
        .onChange(of: refreshToken) { old, new in
            guard new != old else { return }
            Task { await load(initial: false) }
        }
        // The sidebar's Read-all button bumps `readAllToken` for the same reason refresh does.
        .onChange(of: readAllToken) { old, new in
            guard new != old else { return }
            Task { await markAllRead() }
        }
        // A filter typed in Inbox has no meaning in Saved, and leaving it set would greet the
        // just-selected section with "No matches", which reads as a bug. `showingSaved` is the
        // host's binding, so this fires for both the phone toggle and the sidebar rows.
        .onChange(of: showingSaved) { _, _ in search = "" }
        // Paperclip → a Telegram-style attach sheet picks the source, so we open the
        // RIGHT system picker. The picker is opened in the sheet's onDismiss (via
        // `pendingPicker`), not inline — presenting a sheet while another dismisses
        // drops the second on iOS.
        .sheet(isPresented: $showAttachSheet, onDismiss: presentPendingPicker) {
            attachSheet
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.visible)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: Self.maxAttachments,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let items = newItems
            photoItems = []  // reset now so re-picking the same items fires onChange again
            Task { await loadPickedPhotos(items) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handlePickedFiles(result)
        }
        // A tapped file chip downloads the bytes to a temp URL; QuickLook previews
        // it and offers the system share action (save to Files, etc.).
        .quickLookPreview($previewURL)
        // Explicit "Save to Files…" (from a file chip's context menu): export through
        // the system document picker so the file lands where the owner picks — the real
        // Finder ~/Documents / ~/Downloads on Mac, the Files picker on iPhone/iPad.
        // QuickLook's own "Save to Files" resolves to the hidden app-sandbox container
        // on the Designed-for-iPad Mac build, so saves there appear to vanish.
        .sheet(item: $exportFile) { export in
            FileExportPicker(url: export.url) {
                // asCopy already copied it to the chosen location; drop our temp.
                try? FileManager.default.removeItem(at: export.dir)
                exportFile = nil
            }
            .ignoresSafeArea()
        }
        // Received HTML/SVG opens in a dedicated in-app viewer (JavaScript off, all
        // network blocked) rather than QuickLook, which rendered these blank (#92).
        // Done dismisses; Share still lets the owner save the raw file.
        .fullScreenCover(item: $webDoc) { doc in
            NavigationStack {
                HtmlWebView(html: doc.html)
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
            // Remove the raw temp file when the viewer closes so a viewed document
            // does not linger in tmp.
            .onDisappear { try? FileManager.default.removeItem(at: doc.fileURL) }
        }
        // Delete the previewed temp file when QuickLook dismisses (it nils the
        // binding) or when it is replaced — so a previewed secret does not linger.
        .onChange(of: previewURL) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                try? FileManager.default.removeItem(at: oldValue)
            }
        }
        // Same for the web-doc viewer's raw file: remove the previous one whenever
        // webDoc changes (including → nil on dismiss), so a viewed HTML/SVG never lingers.
        .onChange(of: webDoc?.fileURL) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                try? FileManager.default.removeItem(at: oldValue)
            }
        }
        // Backstop: on the way out, cancel an in-flight file open (so a late completion
        // can't strand a temp file after cleanup) and remove any lingering temp files —
        // both the QuickLook preview and the web-doc viewer's raw file.
        .onDisappear {
            openFileTask?.cancel()
            if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
            if let url = webDoc?.fileURL { try? FileManager.default.removeItem(at: url) }
            // Staged attachment bytes are deliberately NOT removed here. Gram is a
            // persistent tab (see HerdrApp's TabView), so `onDisappear` fires on a
            // plain tab switch while this view's `@State` — including the chips in
            // `attachedFiles` — survives. Unlinking here would delete the bytes of an
            // attachment still shown in the composer, and make its retry unfixable.
            // The staged bytes are released on chip-X, after a successful send, and
            // for a killed session by the next launch's staging sweep.
        }
        // Don't let a swipe-down (the new sheet dismissal) abandon an in-flight send
        // or a photo load mid-way — the chunked upload would keep running off-screen.
        .interactiveDismissDisabled(sending || loadingPhoto)
    }

    // MARK: - Layout roots

    /// iPhone / compact width: the original single column — header (with the All/Saved toggle),
    /// the message feed, banner, and composer stacked top to bottom. Unchanged from before.
    private var phoneBody: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            searchFieldIfFilterable
            content
            bannerView
            composer
        }
    }

    /// Regular width: the message feed + composer ONLY. The Inbox/Saved selector and the refresh
    /// action are rendered by the host in the app's real `NavigationSplitView` sidebar, beside
    /// the section picker, exactly like the agents list.
    ///
    /// This page used to draw its OWN 260pt rail here, which on iPad and Mac put a second
    /// sidebar next to the split view's own column — and that column was rendering an empty
    /// `Spacer()` for this section, so the screen showed one empty system sidebar and one
    /// hand-rolled one. Reuses the SAME `content` / `bannerView` / `composer` as the phone, so
    /// every send/attach/poll behaviour is identical.
    private var iPadBody: some View {
        VStack(spacing: 0) {
            searchFieldIfFilterable
            content
            bannerView
            composer
        }
    }

    /// The message filter, pinned ABOVE the scroll in both layouts (it must not scroll away),
    /// copying the agents list's field verbatim except for the binding and placeholder so the
    /// two search surfaces in the app look and behave identically.
    private var searchField: some View {
        TextField("Search messages", text: $search)
            .font(Typography.app(15)).foregroundStyle(Palette.text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 4)
    }

    /// The field, but only where there is something to filter. `content` renders a spinner while
    /// loading and an error card (with a Retry) when the daemon has no gram, and a search box
    /// pinned above either of those is a live control over nothing. The agents list's field sits
    /// above an EMPTY LIST, never above an error state.
    @ViewBuilder
    private var searchFieldIfFilterable: some View {
        if showingSaved || phase == .loaded { searchField }
    }

    /// A load error / send error, shown ABOVE the composer in every phase — the
    /// composer is enabled in all states, so a failure must be visible in all states
    /// (empty inbox, pre-deploy daemon, or a loaded list alike).
    @ViewBuilder
    private var bannerView: some View {
        if let text = sendError ?? markAllNote ?? refreshNote {
            Text(text)
                .font(Typography.app(12))
                .foregroundStyle(Palette.died)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(showingSaved ? "Saved" : "Gram")
                .font(Typography.app(20, .semibold))
                .foregroundStyle(Palette.text)
            if !showingSaved, unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(Typography.machine(11, .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.waiting))
            }
            Spacer()
            // All / Saved toggle — a filled bookmark means the Saved section is showing.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingSaved.toggle() }
            } label: {
                Image(systemName: showingSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(showingSaved ? Palette.brand : Palette.textDim)
            }
            // Read all — only while the Inbox is showing (Saved has no unread concept) and
            // something is actually unread, so it never sits there as a no-op control.
            if !showingSaved, unreadCount > 0 {
                Button {
                    Task { await markAllRead() }
                } label: {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                .disabled(markingAllRead)
                .accessibilityLabel("Read all")
            }
            if !showingSaved {
                Button {
                    Task { await load(initial: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unreadCount: Int { messages.filter { $0.isUnread }.count }

    // MARK: - Content

    private var content: some View {
        Group {
            if showingSaved { savedContent } else { inboxContent }
        }
        // Let a drag on the message feed dismiss the keyboard too, so the composer
        // never gets stuck covering the tab bar with no way out.
        .scrollDismissesKeyboard(.interactively)
    }

    /// Shown when the list HAS rows but the active search matches none of them. A distinct
    /// state from "nothing here yet": a blank scroll after typing reads as an empty inbox,
    /// which is the bug the agents list already avoids the same way.
    private var noMatches: some View {
        centered {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textFaint)
                Text("No matches")
                    .font(Typography.app(15, .medium))
                    .foregroundStyle(Palette.textDim)
                Text("Nothing in this list matches “\(search)”.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        }
    }

    /// The Saved section: locally-kept copies of bookmarked messages. Rendered from the local
    /// store (independent of the poll), so a saved message survives even after the original is
    /// deleted from the server.
    @ViewBuilder
    private var savedContent: some View {
        if savedGrams.saved.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text("No saved messages yet")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text("Tap the bookmark on a message to keep it here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }
        } else if visibleSaved.isEmpty {
            noMatches
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleSaved) { s in
                        SavedGramRow(
                            saved: s,
                            isDownloadingFile: downloadingFileFor == s.id,
                            onOpenFile: { openFile(id: s.id) },
                            onSaveFile: { saveFile(id: s.id) },
                            onUnsave: { savedGrams.remove(s.id) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var inboxContent: some View {
        switch phase {
        case .loading:
            centered { ProgressView().tint(Palette.textDim) }
        case .unavailable(let message):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text(message)
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                    Button { Task { await load(initial: true) } } label: {
                        Text("Retry")
                            .font(Typography.app(14, .semibold))
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Palette.text))
                    }
                }
                .padding(.horizontal, 32)
            }
        case .loaded where messages.isEmpty && !shouldShowSetupCard:
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text("No messages yet")
                        .font(Typography.app(15, .medium))
                        .foregroundStyle(Palette.textDim)
                    Text("Agents you message, and their replies, appear here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }
        // Must sit ABOVE `case .loaded:` — Swift evaluates cases in order, so below it this
        // is unreachable. `!messages.isEmpty` is load-bearing: an EMPTY inbox showing the setup
        // card falls through to `case .loaded:` (the case above needs `!shouldShowSetupCard`),
        // and without it one keystroke would replace the only affordance telling the owner how
        // to give their agents gram with "No matches" about a list that never had rows.
        case .loaded where !search.isEmpty && !messages.isEmpty && visibleMessages.isEmpty:
            noMatches
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 10) {
                    if shouldShowSetupCard { setupCard }
                    ForEach(visibleMessages) { message in
                        GramRow(
                            message: message,
                            isDownloadingFile: downloadingFileFor == message.id,
                            isSaved: savedGrams.isSaved(message.id),
                            onOpenFile: { openFile(id: message.id) },
                            onSaveFile: { saveFile(id: message.id) },
                            onToggleSave: { savedGrams.toggle(message) },
                            onDelete: { delete(message) }
                        )
                        .onAppear { markReadIfNeeded(message) }
                    }
                }
                .padding(16)
            }
            .refreshable { await load(initial: false) }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one-liner an agent runs to install the gram skill (from the fork's raw URL).
    private static let setupCommand =
        "curl -fsSL https://raw.githubusercontent.com/jerryfane/herdr/master/"
        + "skills/herdrup-gram-skill/SKILL.md --create-dirs "
        + "-o ~/.claude/skills/herdrup-gram-skill/SKILL.md"

    /// Show the "set up gram" card until an agent has actually messaged (proof the
    /// skill is in use) or the owner dismisses it.
    private var shouldShowSetupCard: Bool {
        !setupCardDismissed && !messages.contains(where: \.isFromAgent)
    }

    /// A dismissable card teaching the owner how to give their agents the gram skill:
    /// the install command + a Copy button. Auto-hides once an agent messages.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up gram for your agents")
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.text)
                    Text("Paste this to your agents so they can message you here.")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { setupCardDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.surfaceRaised))
                }
            }
            Text(Self.setupCommand)
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.groundMachine))
            Button {
                UIPasteboard.general.string = Self.setupCommand
                setupCommandCopied = true
            } label: {
                Text(setupCommandCopied ? "Copied ✓" : "Copy command")
                    .font(Typography.app(13, .semibold))
                    .foregroundStyle(Palette.ground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.text))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            Divider().overlay(Palette.hairlineQuiet)
            HStack(spacing: 8) {
                Text("To")
                    .font(Typography.machine(11, .semibold))
                    .foregroundStyle(Palette.textFaint)
                Menu {
                    Button { recipient = .queue } label: {
                        Label("Shared queue (any agent)", systemImage: "tray.and.arrow.down")
                    }
                    if !addressableAgents.isEmpty {
                        Divider()
                        ForEach(addressableAgents, id: \.self) { name in
                            Button { recipient = .agent(name) } label: { Text(name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(recipient.label)
                            .font(Typography.app(13, .medium))
                            .foregroundStyle(Palette.text)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textFaint)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
                }
                .disabled(sending)
                Spacer(minLength: 0)
            }
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFiles) { file in attachmentChip(file) }
                    }
                }
            }
            if let up = uploadBytes {
                let frac = up.total > 0 ? min(1, Double(up.sent) / Double(up.total)) : 0
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(uploadStatusLabel(fraction: frac))
                            .font(Typography.machine(11))
                            .foregroundStyle(Palette.textFaint)
                        Spacer(minLength: 8)
                        if up.total >= 1024 * 1024 {
                            Text("\(byteString(up.sent)) / \(byteString(up.total))")
                                .font(Typography.machine(11))
                                .foregroundStyle(Palette.textFaint)
                                .monospacedDigit()
                        }
                    }
                    ProgressView(value: frac)
                        .tint(Palette.text)
                }
                .frame(maxWidth: .infinity)
            } else if let progress = sendProgress, progress.total > 1 {
                // Between files (this one's upload done, its message posting): keep the count.
                Text("Sending \(progress.sent + 1) of \(progress.total)…")
                    .font(Typography.machine(11))
                    .foregroundStyle(Palette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showAttachSheet = true
                } label: {
                    Group {
                        if loadingPhoto {
                            // An iCloud-backed pick can take a beat to materialize;
                            // show it's working rather than a dead paperclip.
                            ProgressView().tint(Palette.textDim)
                        } else {
                            Image(systemName: "paperclip")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Palette.textDim)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Palette.surface))
                }
                .disabled(sending || loadingPhoto)
                TextField("Message an agent…", text: $draft, axis: .vertical)
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.text)
                    .tint(Palette.text)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
                    .disabled(draftDictating)   // dictation owns the field while live
                // Dictate into the draft (on-device); appends, never clobbers typed text.
                // Disabled during a send so dictation can't race the field-clear.
                MicButton(text: $draft, recording: $draftDictating)
                    .disabled(sending || loadingPhoto)
                Button {
                    Task { await send() }
                } label: {
                    Group {
                        if uploading {
                            // Over the dark `surface` fill (canSend is false while
                            // sending), tint the spinner light so it is visible —
                            // it is the only feedback during a many-chunk upload.
                            ProgressView().tint(Palette.text)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        }
                    }
                    .foregroundStyle(canSend ? Palette.ground : Palette.textFaint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Palette.text : Palette.surface))
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Palette.ground)
    }

    private var canSend: Bool {
        // Also blocked while a photo is loading, so tapping Send mid-load can't fire a
        // text-only message that races the attachment in behind it, and while dictating
        // (see MicButton): sending mid-dictation would clear the field, then the next
        // recognition partial would restore the just-sent text and re-enable a duplicate.
        guard !sending, !loadingPhoto, !draftDictating else { return false }
        return !attachedFiles.isEmpty
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A staged attachment shown in the composer's horizontal strip, with a remove
    /// button. Sizes to content (long names truncate) rather than filling the width,
    /// since several chips now sit side by side.
    private func attachmentChip(_ file: PickedAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileGlyph.name(for: file.mime, fileName: file.name))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textDim)
            Text(file.name)
                .font(Typography.app(13, .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Text(GramFile.displaySize(of: UInt64(file.size)))
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textFaint)
            Button {
                // Remove the staged bytes with the chip: a dropped attachment must
                // not leave a secret-bearing temp file behind.
                try? FileManager.default.removeItem(at: file.dir)
                attachedFiles.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textFaint)
            }
            // Locked during a send: send() snapshots the files up front, so a
            // "removed" chip would post anyway — a visible remove that silently
            // still sends is the wrong outcome for a secret-bearing channel. The
            // strip is read-only until the batch finishes (matching the paperclip/
            // Send/recipient controls, which are already disabled while sending).
            .disabled(sending)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
        .opacity(sending ? 0.6 : 1)
    }

    /// A Telegram-style attach sheet: two large iconned choices instead of the old
    /// action-sheet list. Photo & Video opens the multi-select library; File opens the
    /// document picker. Each records `pendingPicker` and dismisses; the real picker is
    /// presented in the sheet's onDismiss.
    private var attachSheet: some View {
        VStack(spacing: 18) {
            Text("Attach")
                .font(Typography.app(14, .semibold)).foregroundStyle(Palette.textDim)
                .padding(.top, 16)
            HStack(spacing: 20) {
                attachOption(icon: "photo.on.rectangle.angled", label: "Photo & Video") {
                    pendingPicker = .photos
                    showAttachSheet = false
                }
                attachOption(icon: "doc", label: "File") {
                    pendingPicker = .file
                    showAttachSheet = false
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }

    private func attachOption(icon: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Palette.surface))
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
                Text(label).font(Typography.app(13, .medium)).foregroundStyle(Palette.textDim)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Opens the picker the attach sheet selected, once the sheet has fully dismissed.
    private func presentPendingPicker() {
        switch pendingPicker {
        case .photos: showPhotoPicker = true
        case .file: showFileImporter = true
        case nil: break
        }
        pendingPicker = nil
    }

    // MARK: - Actions

    /// Load once, then poll while the page is visible so a new agent message appears
    /// without a manual refresh (the gram store has no event stream). Backs off when
    /// the server can't serve gram (a pre-deploy daemon), so a failing `gram.list`
    /// isn't hit every few seconds. Ends when the view goes away (task cancelled).
    private func pollLoop() async {
        await load(initial: true)
        while !Task.isCancelled {
            let interval: UInt64
            if case .unavailable = phase { interval = 30_000_000_000 } else { interval = 6_000_000_000 }
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { break }
            await load(initial: false)
        }
    }

    private func load(initial: Bool) async {
        // One load at a time: overlapping loads would race each other.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Spinner only when there is genuinely nothing to show. Keyed on the store's
        // `hasLoaded`, not on `messages.isEmpty`: after a section switch the list is
        // already in hand, so a remount renders it immediately instead of flashing a
        // spinner over content it has.
        if initial && !inboxStore.inbox.hasLoaded && messages.isEmpty { phase = .loading }
        do {
            // Conditional on the digest we hold. An unchanged store answers in a few
            // hundred bytes; only a real change ships the list.
            let answer = try await client.gramList(
                ifUnchangedDigest: inboxStore.inbox.conditionalDigest)
            let changed = inboxStore.inbox.apply(answer)
            phase = .loaded
            refreshNote = nil
            // Nothing moved: the reconciliation below would compute the same result
            // from the same list, so skip it (the common case on a 6s poll).
            guard changed || !answer.isUnchanged else { return }
            // Keep the tab badge in step with what we just loaded.
            unread?.count = inboxStore.inbox.unreadCount
            // Drop optimistic posts the server now reflects; unconfirmed ones stay
            // visible via `messages` (gram.post writes synchronously, so any in-flight
            // load started BEFORE a post can no longer discard it).
            let serverIDs = Set(inboxStore.inbox.messages.map(\.id))
            pendingPosts.removeAll { serverIDs.contains($0.id) }
            // Retire delete-tombstones the server has confirmed gone; keep only those
            // it still returns (a poll that raced the delete), which stay suppressed.
            deletedIDs.formIntersection(serverIDs)
        } catch let error as APIError where error.code == "gram_unavailable" {
            if messages.isEmpty {
                phase = .unavailable("Gram isn't available on this server yet.")
            } else {
                refreshNote = "Gram is unavailable right now."
            }
        } catch {
            // A daemon predating the gram build answers an unknown-method error, NOT
            // `gram_unavailable`, so a first-load failure gets one honest message
            // covering both "not deployed yet" and "couldn't reach it", plus a Retry.
            if messages.isEmpty {
                phase = .unavailable(
                    "Gram isn't available on this server yet, or the messages couldn't load.")
            } else {
                refreshNote = "Refresh failed. Showing the last loaded messages."
            }
        }
    }

    /// Label above the upload bar: "Sending k of N · NN%" for a batch, else "Uploading NN%".
    private func uploadStatusLabel(fraction: Double) -> String {
        let pct = Int((fraction * 100).rounded())
        if let p = sendProgress, p.total > 1 {
            return "Sending \(p.sent + 1) of \(p.total) · \(pct)%"
        }
        return "Uploading \(pct)%"
    }

    /// Compact byte size for the upload bar (e.g. "42.1 MB", "512 KB").
    private func byteString(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachedFiles
        // Capture the destination BEFORE any await. Otherwise the recipient picker
        // could change mid-upload and a file (possibly a secret) would post to a
        // different agent than the one chosen when Send was tapped. The picker is
        // also disabled while sending, but capturing is the real guarantee.
        let to = recipient.wireTo
        // A file with no caption is fine; an empty text-only message is not.
        guard (!text.isEmpty || !files.isEmpty), !sending else { return }
        sending = true
        // Drop the keyboard the moment the message is committed, so the composer
        // stops covering the tab bar (the field has no Return-to-send to resign it).
        composerFocused = false
        defer {
            sending = false
            uploading = false
            sendProgress = nil
            uploadBytes = nil
        }
        sendError = nil

        // Text-only: the unchanged single-message path.
        guard !files.isEmpty else {
            do {
                let posted = try await client.gramPost(text: text, to: to)
                draft = ""
                pendingPosts.removeAll { $0.id == posted.id }
                pendingPosts.insert(posted, at: 0)
            } catch let error as APIError {
                sendError = error.message
            } catch {
                sendError = "Couldn't send. Try again."
            }
            return
        }

        // One upload+post per file (the wire is one-file-per-message). The text rides
        // as the FIRST message's caption; the rest post with no text. `draft` is
        // cleared the instant message 0 succeeds, so a retry of the remaining files
        // never re-sends the caption onto a different file.
        var sentCount = 0
        var remaining: [PickedAttachment] = []
        var failure: String?
        for (index, file) in files.enumerated() {
            sendProgress = (sent: sentCount, total: files.count)
            let caption = index == 0 ? text : ""
            do {
                uploading = true
                uploadBytes = (sent: 0, total: file.size)
                let uploadID = try await client.gramUploadFile(fileURL: file.url) { sent, total in
                    uploadBytes = (sent: sent, total: total)
                }
                uploading = false
                uploadBytes = nil
                let attachment = HerdrClient.GramFileAttachment(
                    uploadID: uploadID, name: file.name, mime: file.mime)
                let posted = try await Self.postAttachment(
                    client: client, text: caption, to: to, attachment: attachment)
                // Optimistic: kept in `pendingPosts`, so a concurrent poll's snapshot
                // cannot drop it; de-duped by id, reconciled once the server reflects it.
                pendingPosts.removeAll { $0.id == posted.id }
                pendingPosts.insert(posted, at: 0)
                sentCount += 1
                if index == 0 { draft = "" }
            } catch let error as APIError {
                // A post still refused after the retries above means the daemon has
                // not reaped the upload connection at all. The bytes are staged and
                // complete, so this is a retry rather than a failure — but the raw
                // daemon sentence ("read the upload connection to EOF") would be
                // meaningless to the owner.
                failure = error.code == "upload_in_progress"
                    ? "Still finishing the last upload. Tap Send again."
                    : error.message
                remaining.append(contentsOf: files[index...])
                break
            } catch {
                failure = "Couldn't send. Try again."
                remaining.append(contentsOf: files[index...])
                break
            }
        }
        // Keep only the not-yet-sent files staged, so a failure leaves the rest ready
        // for a one-tap retry; a full success clears the strip. Already-sent messages
        // are live and are not rolled back.
        attachedFiles = remaining
        // Drop the staged bytes of everything that DID send — after reassigning, so
        // a failed delete cannot corrupt the retry set. Files still in `remaining`
        // keep their temp dirs for the one-tap retry.
        let keptIDs = Set(remaining.map(\.id))
        for file in files where !keptIDs.contains(file.id) {
            try? FileManager.default.removeItem(at: file.dir)
        }
        if let failure {
            sendError = sentCount > 0
                ? "Sent \(sentCount) of \(files.count). \(failure)"
                : failure
        }
    }

    /// Posts an attachment, retrying the POST — never the upload — while the daemon
    /// still owns the `upload_id`.
    ///
    /// The daemon frees its single-writer claim only when it observes EOF on the
    /// upload connection, and the client's close wait is bounded, so a stalled link
    /// can put the post in front of that release. Re-entering `gramUploadFile` would
    /// mint a FRESH `upload_id` and transfer the whole file again, leaving the
    /// previous — complete — staging file to age out over 24 hours; ten taps of a
    /// 100 MB attachment would exhaust the daemon's 1 GiB staging budget and fail
    /// every gram upload from every client. The bytes are already there, so all that
    /// is needed is to ask again.
    private static func postAttachment(
        client: HerdrClient,
        text: String,
        to: String?,
        attachment: HerdrClient.GramFileAttachment
    ) async throws -> GramMessage {
        // Three tries over ~3 s: the daemon's own reap is 60 s, but the case this
        // covers is a teardown a few hundred ms behind the post.
        for attempt in 0..<3 {
            do {
                return try await client.gramPost(text: text, to: to, attachment: attachment)
            } catch let error as APIError where error.code == "upload_in_progress" {
                if attempt == 2 { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // Unreachable: the loop either returns or throws on its last attempt.
        throw GramError.invalidFileData
    }

    /// One combined skip note for a batch pick. `bad` (already phrased) covers picks
    /// that were too large or unreadable; `capped` counts picks dropped for exceeding
    /// the maxAttachments limit — reported distinctly so a cap hit isn't mislabeled as
    /// "too large". nil when nothing was skipped.
    private func attachmentSkipNote(bad: String?, capped: Int) -> String? {
        var parts: [String] = []
        if let bad { parts.append(bad) }
        if capped > 0 { parts.append("\(capped) over the \(Self.maxAttachments)-file limit") }
        guard !parts.isEmpty else { return nil }
        return "Skipped: " + parts.joined(separator: "; ") + "."
    }

    /// Stage picked files as COPIES ON DISK (each bounded by the server's size cap),
    /// so the send streams from a file rather than holding it in memory. File URLs
    /// from the importer are security-scoped, so the copy must happen inside the
    /// access window below — the URL is unreadable after it.
    /// Over-cap / unreadable / uncopyable picks are COLLECTED into one summary rather
    /// than dropped silently, so picking several where one is bad still stages the
    /// good ones.
    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var badNames: [String] = []
        var capped = 0
        for url in urls {
            guard attachedFiles.count < Self.maxAttachments else {
                capped += 1
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Require a KNOWN size within the cap BEFORE copying. An unstat-able URL
            // (size lookup returns nil) is treated as over-cap and skipped, never
            // staged — otherwise a multi-gigabyte pick with no reported size would
            // fall through to an unbounded copy and fill the device. `size > 0` also
            // replaces the old non-empty check. Mirrors PickedMedia's guard so
            // neither the document nor the photo path can stage blind.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0, size <= Staging.maxFileBytes
            else {
                badNames.append(url.lastPathComponent)
                continue
            }
            guard let staged = Staging.copy(of: url, named: url.lastPathComponent) else {
                badNames.append(url.lastPathComponent)
                continue
            }
            attachedFiles.append(PickedAttachment(
                name: url.lastPathComponent, mime: Self.mimeType(for: url),
                url: staged.url, dir: staged.dir, size: staged.size))
        }
        let bad = badNames.isEmpty ? nil : "too large or unreadable: \(badNames.joined(separator: ", "))"
        sendError = attachmentSkipNote(bad: bad, capped: capped)
    }

    // A staged pick is `HerdrKit.StagedAttachment` (url + per-item dir + size).

    /// A photo-library pick copied into app-owned staging. PhotosUI exports the item
    /// to a temp file and DELETES it when the closure returns, so the copy has to
    /// happen inside `FileRepresentation`; the importer stats that export and rejects
    /// an over-cap (or unstat-able) pick THERE — `staged == nil` — before any copy,
    /// mirroring the document path's "reject before staging" guard.
    ///
    /// Rejection is signalled as a VALUE (`staged == nil`), NOT a thrown error, on
    /// purpose: `loadTransferable` routes through NSItemProvider's Obj-C error bridge,
    /// across which a thrown Swift error type may not survive — so a `nil` payload is
    /// the only reliable way to carry "rejected" back and still show the right message.
    private struct PickedMedia: Transferable {
        /// Non-nil only for an in-cap pick that was copied into staging; nil =
        /// rejected (over-cap, size unknown — treated as over-cap — or uncopyable).
        let staged: StagedAttachment?
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .item) { received in
                // Unknown size is treated as OVER-cap (reject), never under-cap — an
                // unstat-able export must not fall through to an unbounded copy.
                guard let size = try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size > 0, size <= GramView.Staging.maxFileBytes
                else {
                    return PickedMedia(staged: nil)
                }
                // Inside the closure: `received.file` is gone once it returns.
                return PickedMedia(
                    staged: GramView.Staging.copy(
                        of: received.file, named: received.file.lastPathComponent))
            }
        }
    }

    /// Load a batch of photo-library picks into `attachedFiles`. Each routes through
    /// `PickedMedia` so the size cap is enforced on the exported file's size before it
    /// is copied — the same invariant the document path holds. Loads SERIALLY (not
    /// concurrently) to bound disk pressure and keep the staged order stable — the
    /// send loop posts in this order and the caption rides on message 0 — and COLLECTS
    /// skips into one summary so picking five where one is oversized doesn't silently
    /// eat the other four's outcome.
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        loadingPhoto = true
        defer { loadingPhoto = false }
        var bad = 0
        var capped = 0
        for item in items {
            guard attachedFiles.count < Self.maxAttachments else {
                capped += 1
                continue
            }
            do {
                // A nil transferable = couldn't produce a file; a non-nil transferable
                // with a nil `staged` = rejected by the size guard, or the copy failed.
                guard let media = try await item.loadTransferable(type: PickedMedia.self),
                    let staged = media.staged
                else {
                    bad += 1
                    continue
                }
                let (name, mime) = Self.photoNameAndMime(for: item)
                attachedFiles.append(PickedAttachment(
                    name: name, mime: mime, url: staged.url, dir: staged.dir, size: staged.size))
            } catch {
                bad += 1
            }
        }
        let badNote = bad == 0 ? nil
            : bad == 1 ? "1 item too large or unreadable"
            : "\(bad) items too large or unreadable"
        sendError = attachmentSkipNote(bad: badNote, capped: capped)
    }

    /// Derive a filename + MIME for a library pick from its concrete content type
    /// (HEIC, JPEG, MOV, …). The name carries a short unique discriminator so three
    /// photos don't all arrive as "image.heic" — identical chips for the owner and a
    /// name collision for any receiving agent that stores attachments by name.
    private static func photoNameAndMime(for item: PhotosPickerItem) -> (String, String) {
        let disc = UUID().uuidString.prefix(8).lowercased()
        if let type = item.supportedContentTypes.first,
            let ext = type.preferredFilenameExtension,
            let mime = type.preferredMIMEType
        {
            let base = type.conforms(to: .movie) ? "video" : "image"
            return ("\(base)-\(disc).\(ext)", mime)
        }
        // The type reported no extension/MIME — still make a movie-aware, unique name.
        if let type = item.supportedContentTypes.first, type.conforms(to: .movie) {
            return ("video-\(disc).mov", "video/quicktime")
        }
        return ("image-\(disc).jpg", "image/jpeg")
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
            let mime = type.preferredMIMEType
        {
            return mime
        }
        return "application/octet-stream"
    }

    /// Download a message's file to a temp URL and present it in QuickLook (which
    /// offers the system share action to save it).
    private func openFile(id: String) {
        guard downloadingFileFor == nil else { return }
        downloadingFileFor = id
        openFileTask = Task {
            defer { downloadingFileFor = nil }
            do {
                let (name, mime, data) = try await client.gramGetFile(id: id)
                // The page went away mid-download (task cancelled in .onDisappear): stop
                // before writing any temp file, so a late completion can't strand one.
                if Task.isCancelled { return }
                // Remove any previously-previewed file so a viewed secret does not
                // accumulate in tmp.
                if let previous = previewURL {
                    try? FileManager.default.removeItem(at: previous)
                }
                let tmp = FileManager.default.temporaryDirectory
                let url: URL
                if Self.isMarkdown(name: name, mime: mime),
                    let text = String(data: data, encoding: .utf8)
                {
                    // Render markdown to styled HTML so it previews FORMATTED —
                    // QuickLook shows a raw .md file as plain source otherwise.
                    let html = Markdown.toStyledHTML(text, title: Self.displayTitle(name))
                    url = tmp.appendingPathComponent(Self.previewHTMLName(for: name))
                    try Data(html.utf8).write(to: url, options: [.atomic, .completeFileProtection])
                } else if Self.isWebDocument(name: name, mime: mime) {
                    // Received HTML/SVG renders in a dedicated in-app WKWebView viewer
                    // (JavaScript off + all network blocked), NOT QuickLook — the old
                    // srcdoc-sandbox path painted a blank white screen (#92). Decode
                    // LOSSILY (invalid UTF-8 -> U+FFFD) so a non-UTF-8 file still renders
                    // as text rather than being treated as a plain download. Keep the raw
                    // bytes on disk so the viewer's Share button can save the original.
                    let raw = tmp.appendingPathComponent(Self.safeTempFileName(name))
                    try data.write(to: raw, options: [.atomic, .completeFileProtection])
                    // We present webDoc, not a QuickLook preview — clear any stale
                    // previewURL (its file was removed above) so nothing tries to present
                    // a now-deleted path, and the previewURL onChange doesn't fire on it.
                    previewURL = nil
                    webDoc = WebDoc(
                        title: Self.webBaseName(name),
                        html: String(decoding: data, as: UTF8.self),
                        fileURL: raw)
                    return
                } else {
                    // Never trust the server name to be a safe path component; reduce
                    // it to a bare basename. Write encrypted-at-rest.
                    url = tmp.appendingPathComponent(Self.safeTempFileName(name))
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                }
                previewURL = url
            } catch let error as APIError {
                sendError = "Couldn't open the file: \(error.message)"
            } catch {
                sendError = "Couldn't open the file."
            }
        }
    }

    /// Download a file and hand it to the system document-export picker, which saves it
    /// to a real, user-chosen location (Finder ~/Documents / ~/Downloads on Mac, Files
    /// on iOS). Unlike QuickLook's "Save to Files", this does not land in the hidden
    /// app-sandbox container on Mac, so the saved file is where the owner expects it.
    private func saveFile(id: String) {
        guard downloadingFileFor == nil else { return }
        downloadingFileFor = id
        Task {
            defer { downloadingFileFor = nil }
            do {
                let (name, _, data) = try await client.gramGetFile(id: id)
                if Task.isCancelled { return }
                // A per-export temp dir so the file keeps its real name (the picker uses
                // the file's own name) without colliding with the preview temp file.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileURL = dir.appendingPathComponent(Self.safeTempFileName(name))
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                exportFile = ExportFile(url: fileURL, dir: dir)
            } catch let error as APIError {
                sendError = "Couldn't save the file: \(error.message)"
            } catch {
                sendError = "Couldn't save the file."
            }
        }
    }

    /// Reduce a server-supplied file name to a safe single path component for the
    /// temp directory: strip any directory parts and reject `.`/`..`.
    private static func safeTempFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." { return "file" }
        return base
    }

    /// Attachment staging, deliberately in a NESTED TYPE rather than on `GramView`.
    ///
    /// `View` is `@MainActor`, so everything on `GramView` inherits that isolation —
    /// but `PickedMedia`'s `FileRepresentation` importer is a nonisolated `@Sendable`
    /// closure, so calling a main-actor static from it is a cross-actor call (a hard
    /// error for a method). A nested type does NOT inherit the enclosing isolation,
    /// which is what is wanted here twice over: the importer can call it directly,
    /// and copying a 100 MB pick never runs on the main actor.
    ///
    /// One staging directory per app SESSION. That level exists for the case where no
    /// cleanup path runs at all: on a crash or a jetsam kill `onDisappear` never
    /// fires, so staged bytes would otherwise sit in tmp untracked. A session
    /// directory makes every earlier session's leftovers a single identifiable
    /// sibling for the launch-time sweep, while the per-item directories inside it
    /// still give a per-chip unlink.
    enum Staging {
        /// Client-side attachment cap, mirroring the server's `MAX_FILE_BYTES`
        /// (100 MiB) and inclusive as the server's is. The upload streams from disk
        /// in frames, so any size uploads fine regardless of divisibility; this is
        /// just the pre-send size gate.
        static let maxFileBytes = 100 * 1024 * 1024

        static let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-staging", isDirectory: true)
        static let session = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        /// Copy a picked file into app-owned staging, so the send streams it from
        /// disk and the app owns its lifetime. nil when the copy fails or the copied
        /// file is empty / over the cap — the caller reports it as a skip.
        ///
        /// The work is `HerdrKit.GramStaging`'s, not this file's: this target is
        /// iOS-only and cannot run on CI, and a staging bug here is silent (it
        /// renders as the same "unreadable pick" message as a genuinely bad file).
        /// In HerdrKit it is tested.
        static func copy(of source: URL, named name: String) -> StagedAttachment? {
            GramStaging.stageCopy(of: source, named: name, in: session, maxBytes: maxFileBytes)
        }

        /// Remove staging left by PREVIOUS app sessions (a crash or jetsam runs no
        /// cleanup).
        ///
        /// Called from the app root's `.task`, not the Gram page's: bytes from a
        /// killed session must be reclaimed even in a launch where the Gram tab is
        /// never opened. Off the main actor because the unlink is a synchronous
        /// recursive walk and the abandoned set can be ten 100 MB attachments.
        static func sweepAbandonedOffMainActor() async {
            let stagingRoot = root
            let current = session.lastPathComponent
            await Task.detached(priority: .utility) {
                GramStaging.sweepAbandoned(root: stagingRoot, keeping: current)
            }.value
        }
    }

    /// A file we should render as formatted HTML (a markdown source), by extension
    /// or advisory mime.
    private static func isMarkdown(name: String, mime: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
            || mime.lowercased() == "text/markdown"
    }

    /// The markdown file's name without its `.md`/`.markdown` extension, for the
    /// preview title.
    private static func displayTitle(_ name: String) -> String {
        let base = safeTempFileName(name)
        for ext in [".markdown", ".md"] where base.lowercased().hasSuffix(ext) {
            return String(base.dropLast(ext.count))
        }
        return base
    }

    /// The temp file name for a rendered markdown preview — a `.html` extension so
    /// QuickLook renders it as a web page, not source.
    private static func previewHTMLName(for name: String) -> String {
        displayTitle(name) + ".html"
    }

    /// A received web document that QuickLook would otherwise render as live,
    /// scriptable content — routed to the in-app `HtmlWebView` viewer instead.
    private static func isWebDocument(name: String, mime: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml")
            || lower.hasSuffix(".svg")
        {
            return true
        }
        let m = mime.lowercased()
        return m == "text/html" || m == "application/xhtml+xml" || m == "image/svg+xml"
    }

    /// The web file's name without its extension, for the preview title.
    private static func webBaseName(_ name: String) -> String {
        let base = safeTempFileName(name)
        for ext in [".xhtml", ".html", ".htm", ".svg"] where base.lowercased().hasSuffix(ext) {
            return String(base.dropLast(ext.count))
        }
        return base
    }

    /// Delete a message (and its file bytes) after the server confirms — so a
    /// failed delete leaves the row in place rather than lying that it's gone.
    private func delete(_ message: GramMessage) {
        Task {
            do {
                try await client.gramDelete(id: message.id)
                // Tombstone it so an in-flight poll (snapshot predating the delete)
                // can't briefly resurrect the row; cleared in `load` once the server
                // no longer returns it.
                deletedIDs.insert(message.id)
                inboxStore.inbox.remove(id: message.id)
                pendingPosts.removeAll { $0.id == message.id }
            } catch let error as APIError {
                sendError = "Couldn't delete: \(error.message)"
            } catch {
                sendError = "Couldn't delete. Try again."
            }
        }
    }

    private func markReadIfNeeded(_ message: GramMessage) {
        // Skip if already read or a mark-read is already in flight for it (onAppear
        // re-fires on scroll).
        guard message.isUnread, !markingRead.contains(message.id) else { return }
        markingRead.insert(message.id)
        Task {
            defer { markingRead.remove(message.id) }
            do {
                try await client.gramMarkRead(id: message.id)
                // Flip the local copy only after the server confirms — an unread
                // agent->owner message always lives in the server snapshot.
                inboxStore.inbox.markRead(id: message.id)
                // Reading a message clears it from the badge immediately.
                unread?.count = inboxStore.inbox.unreadCount
            } catch {
                // Leave it unread; the next poll re-surfaces it.
            }
        }
    }

    /// Marks EVERY unread message read, ignoring any active search — the button says "Read all"
    /// and the badge must reach zero, so marking only the filtered matches would leave a
    /// non-zero badge with no visible cause. Serial, not a TaskGroup: the daemon has no bulk
    /// mark-read (`gram.mark_read` takes one id), so a serial loop is both the existing idiom
    /// and the one that cannot flood a forwarded SSH connection.
    private func markAllRead() async {
        guard !markingAllRead else { return }
        markingAllRead = true
        defer { markingAllRead = false }
        markAllNote = nil
        // Snapshot the ids first: `serverMessages` is mutated inside the loop and a poll may
        // replace it mid-pass, so iterating the live array could skip or repeat a message.
        var pending = serverMessages.filter { $0.isUnread }.map(\.id)
        // Ids this pass actually marked, re-applied after the loop: `load` REPLACES
        // `serverMessages` wholesale, so a poll landing mid-pass reverts the flips written
        // below and the badge would still show a count after a fully successful pass.
        var marked: Set<String> = []
        var attempted = 0
        var failed = 0
        // Two passes: an id a row's own `onAppear` had in flight when we first reached it is
        // retried once, by which time that Task has cleared its entry — otherwise "Read all"
        // could silently leave it unread if that Task's own call failed (its catch is a no-op).
        for _ in 0..<2 {
            var stillInFlight: [String] = []
            for id in pending {
                // Reusing the existing in-flight set is what stops a duplicate `gram.mark_read`.
                guard !markingRead.contains(id) else { stillInFlight.append(id); continue }
                // Someone else's pass already read it; nothing left to do for this id.
                guard serverMessages.first(where: { $0.id == id })?.isUnread ?? false else { continue }
                markingRead.insert(id)
                attempted += 1
                do {
                    try await client.gramMarkRead(id: id)
                    marked.insert(id)
                    inboxStore.inbox.markRead(id: id)
                } catch {
                    failed += 1
                }
                markingRead.remove(id)
            }
            pending = stillInFlight
            if pending.isEmpty { break }
        }
        // Whatever array is current now, the ids we confirmed read are read. Ids still in flight
        // elsewhere are left to their own Task, which flips them on success.
        for id in marked { inboxStore.inbox.markRead(id: id) }
        unread?.count = inboxStore.inbox.unreadCount
        // Partial failure is reported, not swallowed: the badge will still show a count and the
        // reader needs to know why. Its OWN slot, not `refreshNote` — the 6-second poll clears
        // that one unconditionally on success, so the explanation would outlive the badge by
        // seconds at most. `sendError` carries the same reasoning (see its declaration).
        markAllNote = failed == 0 ? nil : "\(failed) of \(attempted) could not be marked read."
    }
}

/// One message row. Agent->owner shows the sender's identity chip; owner->agent
/// shows the recipient and the claim state of a queued item.
/// A Gram file staged for export, plus the temp dir holding it (removed once the
/// export picker finishes copying it to the chosen location).
private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let dir: URL
}

/// Wraps `UIDocumentPickerViewController(forExporting:asCopy:)` so a downloaded Gram
/// file saves to a real, user-chosen location — the Finder save panel (real
/// ~/Documents / ~/Downloads) on Mac, the Files picker on iPhone/iPad. QuickLook's
/// built-in "Save to Files" maps "Documents" to the hidden app-sandbox container on
/// the Designed-for-iPad Mac build, which is why saved files seem to disappear.
private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}

private struct GramRow: View {
    let message: GramMessage
    var isDownloadingFile: Bool
    var isSaved: Bool
    var onOpenFile: () -> Void
    var onSaveFile: () -> Void
    var onToggleSave: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Typography.app(13, .semibold))
                        .foregroundStyle(Palette.text)
                    if message.isUnread {
                        Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 0)
                    Text(age)
                        .font(Typography.machine(11))
                        .foregroundStyle(Palette.textFaint)
                    // Small save/unsave tap target (the same action is also in the long-press menu).
                    Button(action: onToggleSave) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSaved ? Palette.brand : Palette.textFaint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !message.text.isEmpty {
                    Text(linkified(message.text))
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .tint(Palette.brand)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let file = message.file {
                    fileChip(file)
                }
                if let status = statusLine {
                    Text(status)
                        .font(Typography.machine(11))
                        .foregroundStyle(statusColor)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairlineQuiet, lineWidth: 1))
        // Long-press for the message actions. Copy the text (when there is any) —
        // a file's bytes are reached via the chip's preview + system share sheet, so
        // we don't add a second, weaker file-copy path here. Delete is destructive,
        // pinned last.
        .contextMenu {
            if !message.text.isEmpty {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Button(action: onToggleSave) {
                Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "bookmark.slash" : "bookmark")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// A tappable chip for an attached file: tap to download + preview it.
    private func fileChip(_ file: GramFile) -> some View {
        Button(action: onOpenFile) {
            HStack(spacing: 8) {
                Image(systemName: FileGlyph.name(for: file.mime, fileName: file.name))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(Typography.app(13, .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.displaySize)
                        .font(Typography.machine(11))
                        .foregroundStyle(Palette.textFaint)
                }
                Spacer(minLength: 0)
                if isDownloadingFile {
                    ProgressView().tint(Palette.textDim)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surface))
        }
        .buttonStyle(.plain)
        .disabled(isDownloadingFile)
        .contextMenu {
            Button { onOpenFile() } label: { Label("Open", systemImage: "eye") }
            Button { onSaveFile() } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if message.isFromAgent {
            Text(AgentIdentity.glyph(for: message.from))
                .font(Typography.app(14, .bold))
                .foregroundStyle(Palette.text)
                .frame(width: 30, height: 30)
                .background(AgentIdentity.gradient(for: message.from), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textDim)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
        }
    }

    private var title: String {
        if message.isFromAgent {
            return message.from
        }
        if let to = message.to {
            return "You → \(to)"
        }
        return "You → queue"
    }

    /// Claim state for the owner's queue posts.
    private var statusLine: String? {
        guard !message.isFromAgent else { return nil }
        if let grabber = message.grabbedBy {
            return "grabbed by \(grabber)"
        }
        if message.to == nil {
            return "unclaimed"
        }
        return nil
    }

    private var statusColor: Color {
        message.grabbedBy != nil ? Palette.done : Palette.textFaint
    }

    private var age: String { Self.age(from: message.createdAt) }

    static func age(from date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

/// Picks an SF Symbol for a file from its MIME type. Shared by the composer's
/// staged-attachment chip and a received message's file chip.
private enum FileGlyph {
    static func name(for mime: String, fileName: String) -> String {
        let mime = mime.lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime == "application/zip" || mime.contains("compressed") { return "doc.zipper" }
        if mime == "application/json" { return "curlybraces" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}
