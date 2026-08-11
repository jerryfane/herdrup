import CoreTransferable
import HerdrKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

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

    /// The last server snapshot (newest first) and the owner's just-posted messages
    /// not yet reflected in a snapshot. `messages` composes them so a background poll
    /// can never drop an optimistic post it hasn't caught up to.
    @State private var serverMessages: [GramMessage] = []
    @State private var pendingPosts: [GramMessage] = []
    @State private var phase: LoadPhase = .loading
    @State private var recipient: Recipient = .queue
    @State private var draft: String = ""
    @State private var sending = false
    /// A send failure. Kept SEPARATE from load state so a successful background poll
    /// never clears it before the owner sees it.
    @State private var sendError: String?
    /// A non-fatal refresh failure while messages are already shown.
    @State private var refreshNote: String?
    @State private var isLoading = false
    /// Messages with a mark-read in flight, so a re-`onAppear` (scroll) does not fire
    /// a duplicate `gram.mark_read`.
    @State private var markingRead: Set<String> = []

    /// A file the owner picked to attach to the next post (read into memory at pick
    /// time), nil when none is staged.
    @State private var attachedFile: PickedAttachment?
    @State private var showFileImporter = false
    /// The paperclip opens this chooser first, so we know which system picker to
    /// present: the photo library (image/video) or the document picker (any file).
    @State private var showAttachTypeDialog = false
    @State private var showPhotoPicker = false
    /// The item chosen from the photo library, loaded into a `PickedAttachment`.
    @State private var photoItem: PhotosPickerItem?
    /// True while a photo-library pick is loading (iCloud items can take a moment).
    /// Gates Send and the paperclip so a text-only send can't race the load and a
    /// second pick can't start concurrently.
    @State private var loadingPhoto = false
    /// True while a picked file is uploading (many small chunks over SSH).
    @State private var uploading = false
    /// A downloaded file written to a temp URL, presented via QuickLook when set.
    @State private var previewURL: URL?
    /// The message id whose file is currently downloading, to show a spinner on it.
    @State private var downloadingFileFor: String?
    /// Ids the server has confirmed deleted, kept as tombstones so an in-flight poll
    /// (whose snapshot predates the delete) cannot resurrect the row for a few
    /// seconds. Cleared once the server's own snapshot also omits the id.
    @State private var deletedIDs: Set<String> = []

    /// A file staged for sending: read into memory so the send is one atomic action.
    private struct PickedAttachment {
        let name: String
        let mime: String
        let data: Data
    }

    /// Client-side attachment cap, mirroring the server's `MAX_FILE_BYTES`.
    private static let maxFileBytes = 10 * 1024 * 1024

    /// The list the page renders: optimistic posts first, then the server snapshot
    /// with those posts de-duped out once the server reflects them.
    private var messages: [GramMessage] {
        let pendingIDs = Set(pendingPosts.map(\.id))
        return (pendingPosts + serverMessages.filter { !pendingIDs.contains($0.id) })
            .filter { !deletedIDs.contains($0.id) }
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
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            content
            bannerView
            composer
        }
        .background(Palette.ground.ignoresSafeArea())
        // Poll while the page is open so new agent messages appear without a manual
        // refresh (the gram store has no event stream); the loop ends when the view
        // goes away (task cancellation).
        .task { await pollLoop() }
        // Paperclip → choose the source so we open the RIGHT system picker: the
        // photo library for media, or the document picker for an arbitrary file.
        .confirmationDialog("Attach", isPresented: $showAttachTypeDialog, titleVisibility: .visible) {
            Button("Photo or Video") { showPhotoPicker = true }
            Button("File") { showFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItem,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedPhoto(newItem) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        // A tapped file chip downloads the bytes to a temp URL; QuickLook previews
        // it and offers the system share action (save to Files, etc.).
        .quickLookPreview($previewURL)
        // Delete the previewed temp file when QuickLook dismisses (it nils the
        // binding) or when it is replaced — so a previewed secret does not linger.
        .onChange(of: previewURL) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                try? FileManager.default.removeItem(at: oldValue)
            }
        }
        // Backstop: remove any lingering preview file when the page goes away.
        .onDisappear {
            if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        }
        // Don't let a swipe-down (the new sheet dismissal) abandon an in-flight send
        // or a photo load mid-way — the chunked upload would keep running off-screen.
        .interactiveDismissDisabled(sending || loadingPhoto)
    }

    /// A load error / send error, shown ABOVE the composer in every phase — the
    /// composer is enabled in all states, so a failure must be visible in all states
    /// (empty inbox, pre-deploy daemon, or a loaded list alike).
    @ViewBuilder
    private var bannerView: some View {
        if let text = sendError ?? refreshNote {
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
            Text("Gram")
                .font(Typography.app(20, .semibold))
                .foregroundStyle(Palette.text)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(Typography.machine(11, .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.waiting))
            }
            Spacer()
            Button {
                Task { await load(initial: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
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

    @ViewBuilder
    private var content: some View {
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
        case .loaded where messages.isEmpty:
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
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        GramRow(
                            message: message,
                            isDownloadingFile: downloadingFileFor == message.id,
                            onOpenFile: { openFile(message) },
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
            if let attachedFile { attachmentChip(attachedFile) }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showAttachTypeDialog = true
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
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
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
        // text-only message that races the attachment in behind it.
        guard !sending, !loadingPhoto else { return false }
        return attachedFile != nil
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The staged attachment shown above the composer, with a remove button.
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
            Text(GramFile.displaySize(of: UInt64(file.data.count)))
                .font(Typography.machine(11))
                .foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
            Button {
                attachedFile = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Spinner only on the first load with nothing to show yet; a refresh keeps
        // the current messages visible.
        if initial && messages.isEmpty { phase = .loading }
        do {
            let fetched = try await client.gramList()
            serverMessages = fetched
            // Drop optimistic posts the server now reflects; unconfirmed ones stay
            // visible via `messages` (gram.post writes synchronously, so any in-flight
            // load started BEFORE a post can no longer discard it).
            let serverIDs = Set(fetched.map(\.id))
            pendingPosts.removeAll { serverIDs.contains($0.id) }
            // Retire delete-tombstones the server has confirmed gone; keep only those
            // it still returns (a poll that raced the delete), which stay suppressed.
            deletedIDs.formIntersection(serverIDs)
            phase = .loaded
            refreshNote = nil
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
                refreshNote = "Refresh failed — showing the last loaded messages."
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachedFile
        // Capture the destination BEFORE any await. Otherwise the recipient picker
        // could change mid-upload and the file (possibly a secret) would post to a
        // different agent than the one chosen when Send was tapped. The picker is
        // also disabled while sending, but capturing is the real guarantee.
        let to = recipient.wireTo
        // A file with no caption is fine; an empty text-only message is not.
        guard (!text.isEmpty || attachment != nil), !sending else { return }
        sending = true
        defer {
            sending = false
            uploading = false
        }
        sendError = nil
        do {
            let posted: GramMessage
            if let attachment {
                // Upload the bytes in chunks, then post the message referencing them.
                uploading = true
                let uploadID = try await client.gramUploadFile(attachment.data)
                uploading = false
                posted = try await client.gramPost(
                    text: text, to: to,
                    attachment: .init(
                        uploadID: uploadID, name: attachment.name, mime: attachment.mime))
            } else {
                posted = try await client.gramPost(text: text, to: to)
            }
            draft = ""
            attachedFile = nil
            // Optimistic: kept in `pendingPosts`, so a concurrent poll's snapshot
            // cannot drop it; de-duped by id, reconciled once the server reflects it.
            pendingPosts.removeAll { $0.id == posted.id }
            pendingPosts.insert(posted, at: 0)
        } catch let error as APIError {
            sendError = error.message
        } catch {
            sendError = "Couldn't send. Try again."
        }
    }

    /// Read a picked file into memory (bounded by the server's size cap) so the
    /// send is one atomic action. A file URL from the importer is security-scoped.
    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Reject an over-cap file BEFORE reading it into memory, so picking a
        // multi-gigabyte file can't allocate/read it all (and risk a jetsam) before
        // the size check ever runs.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > Self.maxFileBytes
        {
            sendError = "That file is too large (max 10 MB)."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                sendError = "That file is empty."
                return
            }
            // Fallback for a URL whose size wasn't reported up front.
            guard data.count <= Self.maxFileBytes else {
                sendError = "That file is too large (max 10 MB)."
                return
            }
            attachedFile = PickedAttachment(
                name: url.lastPathComponent, mime: Self.mimeType(for: url), data: data)
            sendError = nil
        } catch {
            sendError = "Couldn't read that file."
        }
    }

    /// A photo-library pick loaded as a size-checked file. PhotosUI exports the item to
    /// a temp file; the importer stats that file and rejects an over-cap (or unstat-able)
    /// pick THERE — `data == nil` — before any bytes are read, mirroring the document
    /// path's "reject before reading into memory" guard.
    ///
    /// Rejection is signalled as a VALUE (`data == nil`), NOT a thrown error, on purpose:
    /// `loadTransferable` routes through NSItemProvider's Obj-C error bridge, across which
    /// a thrown Swift error type may not survive — so a `nil` payload is the only reliable
    /// way to carry "rejected" back and still show the right message.
    private struct PickedMedia: Transferable {
        /// Non-nil only for an in-cap, readable pick; nil = rejected (over-cap OR the
        /// exported file's size could not be determined — treated as over-cap, never
        /// read blindly into memory).
        let data: Data?
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .item) { received in
                // Unknown size is treated as OVER-cap (reject), never under-cap — an
                // unstat-able export must not fall through to an unbounded read.
                guard let size = try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size <= GramView.maxFileBytes
                else {
                    return PickedMedia(data: nil)
                }
                let data = try Data(contentsOf: received.file)
                // Belt-and-braces, matching the document path: reject if the read somehow
                // exceeded the stat'd size, so an over-cap Data can never reach the caller.
                guard data.count <= GramView.maxFileBytes else { return PickedMedia(data: nil) }
                return PickedMedia(data: data)
            }
        }
    }

    /// Load a photo-library pick into a `PickedAttachment`. Routes through `PickedMedia`
    /// so the 10 MB cap is enforced on the exported file's size before any bytes are
    /// read — the same invariant the document path holds, so an over-cap video shows
    /// the "too large" error instead of jetsamming the app.
    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        defer {
            loadingPhoto = false
            photoItem = nil  // reset so re-picking the same item fires onChange again
        }
        do {
            // A nil transferable = couldn't produce a file; a non-nil transferable with a
            // nil `data` = rejected by the size guard (over-cap / unstat-able).
            guard let media = try await item.loadTransferable(type: PickedMedia.self) else {
                sendError = "Couldn't read that item."
                return
            }
            guard let data = media.data else {
                sendError = "That item is too large (max 10 MB)."
                return
            }
            guard !data.isEmpty else {
                sendError = "That item is empty."
                return
            }
            let (name, mime) = Self.photoNameAndMime(for: item)
            attachedFile = PickedAttachment(name: name, mime: mime, data: data)
            sendError = nil
        } catch {
            sendError = "Couldn't read that item."
        }
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
    private func openFile(_ message: GramMessage) {
        guard downloadingFileFor == nil else { return }
        downloadingFileFor = message.id
        Task {
            defer { downloadingFileFor = nil }
            do {
                let (name, mime, data) = try await client.gramGetFile(id: message.id)
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
                    // Received HTML/SVG would render as LIVE, scriptable content in
                    // QuickLook. Wrap it in a sandboxed iframe so it still renders
                    // styled but no script from a hostile file can run. Decode from
                    // DATA (lossy) — NEVER gate on strict UTF-8, or a non-UTF-8 hostile
                    // file would fall through to the raw, unsandboxed write below.
                    let wrapped = HtmlSandbox.wrap(data: data, title: Self.webBaseName(name))
                    url = tmp.appendingPathComponent(Self.sandboxHTMLName(for: name))
                    try Data(wrapped.utf8).write(to: url, options: [.atomic, .completeFileProtection])
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
    /// scriptable content — routed through the sandbox instead.
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

    /// The temp file name for a sandboxed web preview — always `.html`, since the
    /// sandbox WRAPPER is HTML (even when wrapping an `.svg`), so QuickLook renders it.
    private static func sandboxHTMLName(for name: String) -> String {
        webBaseName(name) + ".html"
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
                serverMessages.removeAll { $0.id == message.id }
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
                if let index = serverMessages.firstIndex(where: { $0.id == message.id }) {
                    serverMessages[index].readByOwner = true
                }
            } catch {
                // Leave it unread; the next poll re-surfaces it.
            }
        }
    }
}

/// One message row. Agent->owner shows the sender's identity chip; owner->agent
/// shows the recipient and the claim state of a queued item.
private struct GramRow: View {
    let message: GramMessage
    var isDownloadingFile: Bool
    var onOpenFile: () -> Void
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
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
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
        // Long-press to delete a message (and its file bytes) for good.
        .contextMenu {
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
