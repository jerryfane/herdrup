import HerdrKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A guest's view of the one agent shared with them: the live terminal, view only, and a
/// composer whose messages and files reach the agent under the guest's name.
struct GuestPaneView: View {
    let client: HerdrClient
    let access: GuestAccess
    let onClose: () -> Void

    init(client: HerdrClient, access: GuestAccess, onClose: @escaping () -> Void) {
        self.client = client
        self.access = access
        self.onClose = onClose
    }

    /// Whether the shared agent can be reached right now.
    private enum Availability: Equatable {
        case connecting
        case running
        /// The agent isn't the pane's foreground program; the host refuses guests until it is.
        case paused
        case offline
        /// Revoked or otherwise gone for good.
        case lost
    }

    private struct Attachment: Identifiable {
        let id = UUID()
        let name: String
        let mime: String
        let staged: StagedAttachment
        var uploadID: String?
        var messageID: String?
        var isImage: Bool { mime.hasPrefix("image/") }
    }

    private enum PendingPicker { case photos, file }

    /// The host caps a prompt at 32 KiB (`invalid_params` beyond it).
    static let maxPromptBytes = 32 * 1024
    private static let pollNanoseconds: UInt64 = 5_000_000_000

    @State private var agent: AgentInfo?
    @State private var availability: Availability = .connecting
    @State private var streamGen = 0
    @State private var reply = ""
    @State private var replyFocused = false
    @State private var dictating = false
    @State private var sending = false
    @State private var note: String?
    /// Why the last status poll failed, when it wasn't a change of availability.
    @State private var connectionNote: String?
    @State private var attachments: [Attachment] = []
    @State private var sendingAttachmentID: UUID?
    @State private var uploadBytes: (sent: Int, total: Int)?
    @State private var loadingAttachment = false
    @State private var showAttachSheet = false
    @State private var pendingPicker: PendingPicker?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var findOpen = false
    @State private var findTerm = ""
    @State private var findGeneration = 0
    @State private var findDirection: FindRequest.Direction = .forward
    @State private var findMatches: (Int, Int) = (0, 0)
    @FocusState private var findFocused: Bool
    @StateObject private var composerKeyboard = ComposerKeyboard()
    #if DEBUG
    @State private var forbiddenProbe = ""
    #endif

    var body: some View {
        VStack(spacing: 0) {
            navBar
            statusRow
            terminalArea
            bottomBlock
        }
        .background(Palette.groundMachine.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay { EdgeSwipeBack { onClose() } }
        .task { await pollLoop() }
        .sheet(isPresented: $showAttachSheet, onDismiss: presentPendingPicker) {
            attachSheet
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.visible)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: GramView.Staging.maxAttachments,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await loadPickedPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { handlePickedFiles($0) }
        #if DEBUG
        .overlay(alignment: .topLeading) { forbiddenCallsProbe }
        #endif
    }

    // MARK: - Header

    private var heading: String {
        var parts = [agent?.name ?? access.agentName]
        if let kind = agent?.agent, !kind.isEmpty, !parts.contains(kind) { parts.append(kind) }
        if let folder = agent?.guestFolder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.text).frame(width: 28, height: 44)
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("guest-back")
            if findOpen {
                InlineSearchField(
                    placeholder: "Find", text: $findTerm, focus: $findFocused,
                    matches: (index: findMatches.0, total: findMatches.1),
                    onNext: { stepFind(.forward) }, onPrevious: { stepFind(.backward) },
                    identifierPrefix: "guest-find")
            } else {
                Text(heading).font(Typography.app(18.5, .semibold)).tracking(-0.185)
                    .foregroundStyle(Palette.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { toggleFind() } label: {
                Image(systemName: findOpen ? "xmark" : "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.text).frame(width: 28, height: 44)
            }
            .accessibilityLabel(findOpen ? "Close search" : "Search")
            .accessibilityIdentifier("guest-find")
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 52)
        .background(Palette.ground)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusPill
            SharedByChip(owner: access.ownerName)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch availability {
        case .connecting:
            GuestStatusPill(label: "CONNECTING", color: Palette.textDim, dot: Palette.textFaint,
                            fill: Palette.surfaceRaised, pulsing: false)
        case .paused, .offline, .lost:
            GuestStatusPill(label: availability == .offline ? "OFFLINE" : "NOT RUNNING",
                            color: Palette.textDim, dot: Palette.textFaint, fill: Palette.surfaceRaised,
                            pulsing: false)
        case .running:
            if isBlocked {
                GuestStatusPill(label: "NEEDS \(access.ownerName.uppercased())", color: Palette.waiting,
                                dot: Palette.waiting, fill: Palette.waiting.opacity(0.14), pulsing: false)
            } else {
                let group = agent.map { AgentRow(info: $0).group } ?? .working
                GuestStatusPill(label: group.sectionTitle, color: group.color, dot: group.color,
                                fill: group.color.opacity(0.13), pulsing: group == .working)
            }
        }
    }

    private var isBlocked: Bool {
        availability == .running && AgentStatus(wire: agent?.agentStatus).isBlocked
    }

    // MARK: - Terminal

    private var findRequest: FindRequest? {
        guard findOpen else { return nil }
        return FindRequest(term: findTerm, generation: findGeneration, direction: findDirection)
    }

    private var terminalArea: some View {
        ZStack(alignment: .top) {
            Palette.groundMachine
            // Unmounted while the host refuses the stream, and remounted fresh on recovery.
            if availability == .connecting || availability == .running {
                LiveTerminalView(
                    client: client, paneID: access.agentTarget, viewOnly: true,
                    onStreamEnded: streamEnded,
                    controlArmed: .constant(false),
                    findRequest: findRequest,
                    onFindResult: { index, total in findMatches = (index, total) })
                    .id(streamGen)
                    .accessibilityIdentifier("guest-terminal")
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            if let message = centerMessage {
                GuestCenterMessage(icon: message.icon, title: message.title, detail: message.detail)
                    .padding(.horizontal, 24)
                    .padding(.top, 204)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var centerMessage: (icon: String, title: String, detail: String)? {
        switch availability {
        case .paused:
            return ("pause.fill", "\(access.agentName) isn't running",
                    "Your access is paused until \(access.ownerName) starts it again. Your messages and files so far are still in the transcript.")
        case .offline:
            return ("wifi.slash", "\(access.machineLabel) is offline",
                    "HerdrUp will reconnect when \(access.ownerName)'s machine is back online.")
        case .lost:
            return ("lock.fill", "Your access to \(access.agentName) has ended",
                    "\(access.ownerName) removed your access. Ask \(access.ownerName) for a new invite to talk to \(access.agentName) again.")
        case .connecting, .running:
            return nil
        }
    }

    // MARK: - Composer

    private var canCompose: Bool { availability == .running }

    private var hasContent: Bool {
        !attachments.isEmpty || !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bottomBlock: some View {
        VStack(spacing: 0) {
            noteRow
                .padding(.top, 2)
            composer
                .padding(.top, 10)
                .padding(.bottom, composerKeyboard.isVisible ? 8 : 26)
        }
        .background(Palette.groundMachine)
    }

    /// The single line above the composer: an error or progress note when there is one,
    /// else the blocked banner, else the view-only reminder.
    @ViewBuilder
    private var noteRow: some View {
        HStack(spacing: 7) {
            if let text = note ?? connectionNote {
                Text(text).foregroundStyle(Palette.textDim)
                    .accessibilityIdentifier("guest-note")
            } else if let bytes = uploadBytes, bytes.total > 0 {
                Text("Uploading… \(Int(Double(bytes.sent) / Double(bytes.total) * 100))%")
                    .foregroundStyle(Palette.textDim)
            } else if isBlocked {
                Image(systemName: "clock").font(.system(size: 12, weight: .semibold))
                Text("\(access.agentName) is asking a question only \(access.ownerName) can answer")
                    .accessibilityIdentifier("guest-blocked-banner")
            } else if availability == .running || availability == .connecting {
                Image(systemName: "eye").font(.system(size: 12, weight: .semibold))
                Text("Terminal is view-only · send messages below")
                    .accessibilityIdentifier("guest-view-only-note")
            }
        }
        .font(Typography.app(12, .medium))
        .foregroundStyle(isBlocked && note == nil && connectionNote == nil ? Palette.waiting : Palette.textFaint)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        .padding(.horizontal, 16)
    }

    private var placeholder: Text {
        guard canCompose else { return Text(availability == .lost ? "Access ended" : "Paused") }
        let full = access.composerPlaceholder
        guard full.hasSuffix(access.guestName) else { return Text(full) }
        let lead = String(full.dropLast(access.guestName.count))
        return Text(lead) + Text(access.guestName).font(Typography.app(16, .medium)).foregroundColor(Palette.textDim)
    }

    private var composer: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: replyFocused,
            hasAccessory: !attachments.isEmpty,
            // The standard reply bar's collapse button, while a software keyboard covers
            // the pane: the view-only terminal has nothing else to tap it away with.
            showsLeading: composerKeyboard.isVisible && !findFocused && replyFocused,
            isRecording: dictating
        ) { editorHeight in
            ComposerTextField(
                text: $reply,
                isEnabled: canCompose && !dictating,
                isFocused: replyFocused,
                onFocusChange: { replyFocused = $0 },
                placeholder: "",
                accessibilityIdentifier: "guest-composer-input",
                capitalization: .sentences,
                autocorrection: .default,
                onChange: { _, _ in note = nil },
                onCommandReturn: { send() },
                fixedHeight: editorHeight
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if reply.isEmpty && !dictating {
                    placeholder
                        .font(Typography.app(16))
                        .foregroundStyle(Palette.textFaint)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
        } accessory: {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachmentChip($0) }
                    }
                    .padding(.horizontal, 7)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            Button { replyFocused = false } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
            .accessibilityIdentifier("guest-keyboard-button")
        } actions: {
            HStack(spacing: 4) {
                Button { showAttachSheet = true } label: {
                    ComposerActionIcon(image: Image(systemName: "paperclip"), tint: Palette.textDim,
                                       busy: loadingAttachment)
                }
                .disabled(!canCompose || sending || loadingAttachment)
                .fixedSize()
                .accessibilityLabel("Attach file")
                .accessibilityIdentifier("guest-attach-button")
                MicButton(text: $reply, recording: $dictating)
                    .fixedSize()
                    .disabled(!canCompose || sending)
                    .accessibilityIdentifier("guest-mic-button")
                if hasContent {
                    Button { send() } label: {
                        ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending)
                    }
                    .disabled(!canCompose || sending || dictating)
                    .fixedSize()
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("guest-send-button")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .opacity(canCompose ? 1 : 0.45)
        .disabled(!canCompose)
    }

    private func attachmentChip(_ file: Attachment) -> some View {
        let state: ComposerAttachmentState
        if sendingAttachmentID == file.id, let bytes = uploadBytes {
            state = .uploading(sent: bytes.sent, total: bytes.total)
        } else if sendingAttachmentID == file.id {
            state = .sending
        } else if file.messageID != nil {
            state = .sent
        } else {
            state = sending ? .waiting : .ready
        }
        return ComposerAttachmentChip(
            name: file.name, size: file.staged.size, isImage: file.isImage, state: state,
            canRemove: !sending
        ) {
            try? FileManager.default.removeItem(at: file.staged.dir)
            attachments.removeAll { $0.id == file.id }
        }
    }

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

    // MARK: - Find

    private func toggleFind() {
        if findOpen {
            findOpen = false
            findTerm = ""
            findMatches = (0, 0)
            findFocused = false
        } else {
            findOpen = true
            findFocused = true
        }
    }

    private func stepFind(_ direction: FindRequest.Direction) {
        guard !findTerm.isEmpty else { return }
        findDirection = direction
        findGeneration += 1
    }

    // MARK: - Status

    private func pollLoop() async {
        while !Task.isCancelled, availability != .lost {
            await refresh()
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
    }

    private func refresh() async {
        do {
            let agents = try await client.agentList()
            // The grant's terminal id first; name may be null in a guest's projection.
            let shared = agents.first { $0.terminalID == access.agentTarget || $0.paneID == access.agentTarget }
                ?? agents.first { $0.name == access.agentName }
            agent = shared ?? agent
            connectionNote = nil
            // No agent, or one the host says isn't in the foreground: paused.
            if let shared, shared.guestRunning != false {
                setAvailability(.running)
            } else {
                setAvailability(.paused)
            }
        } catch {
            // Anything but a change of availability (host busy, a dropped or refused
            // connection) is worth retrying: say so and keep polling.
            connectionNote = apply(error) ? nil
                : "Can't reach \(access.machineLabel) (\(GuestError.classify(error)?.description ?? error.localizedDescription)). Trying again…"
        }
    }

    private func setAvailability(_ next: Availability) {
        guard availability != .lost, next != availability else { return }
        let resuming = next == .running && availability != .connecting
        availability = next
        if resuming { streamGen += 1 }
    }

    /// Maps a failed call or stream onto the screen; returns true when it was handled as a
    /// change of availability rather than a one-off failure.
    @discardableResult
    private func apply(_ error: Error) -> Bool {
        guard let guest = GuestError.classify(error) else { return false }
        if guest.isAccessLost || guest == .revoked {
            setAvailability(.lost)
        } else if guest == .paused {
            setAvailability(.paused)
        } else if guest == .hostOffline {
            setAvailability(.offline)
        } else {
            return false
        }
        return true
    }

    private func streamEnded(_ error: Error?) {
        guard let error, apply(error) else { return }
        Task { await refresh() }
    }

    // MARK: - Send

    private func send() {
        guard canCompose, !sending, !dictating, hasContent else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maxPromptBytes else {
            note = "Messages are limited to 32 KB. Send it in parts, or attach it as a file."
            return
        }
        sending = true
        note = nil
        let batch = attachments
        Task {
            defer { sending = false; uploadBytes = nil; sendingAttachmentID = nil }
            do {
                var prompt = text
                if !batch.isEmpty {
                    let delivered = try await deliver(batch)
                    prompt = GramAttachmentPrompt.text(text, delivered: delivered)
                }
                try await client.prompt(pane: access.agentTarget, text: prompt,
                                        waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
                for file in batch { try? FileManager.default.removeItem(at: file.staged.dir) }
                let sentIDs = Set(batch.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                if reply.trimmingCharacters(in: .whitespacesAndNewlines) == text { reply = "" }
            } catch {
                note = failureNote(error)
            }
        }
    }

    /// Uploads and posts each staged file as a gram to the shared agent, remembering each
    /// step so a retry after a failure resumes rather than re-sends.
    private func deliver(_ batch: [Attachment]) async throws -> [GramAttachmentPrompt.Delivered] {
        var delivered: [GramAttachmentPrompt.Delivered] = []
        for original in batch {
            var file = attachments.first { $0.id == original.id } ?? original
            sendingAttachmentID = file.id
            if file.messageID == nil {
                if file.uploadID == nil {
                    uploadBytes = (sent: 0, total: file.staged.size)
                    file.uploadID = try await client.gramUploadFile(fileURL: file.staged.url) { sent, total in
                        uploadBytes = (sent: sent, total: total)
                    }
                    uploadBytes = nil
                    remember(file)
                }
                let posted = try await client.gramPost(
                    text: "Attachment from \(access.guestName).", to: access.agentName,
                    attachment: HerdrClient.GramFileAttachment(
                        uploadID: file.uploadID ?? "", name: file.name, mime: file.mime))
                file.messageID = posted.id
                remember(file)
            }
            delivered.append(GramAttachmentPrompt.Delivered(
                name: file.name, isImage: file.isImage, messageID: file.messageID ?? ""))
        }
        return delivered
    }

    private func remember(_ file: Attachment) {
        guard let index = attachments.firstIndex(where: { $0.id == file.id }) else { return }
        attachments[index] = file
    }

    private func failureNote(_ error: Error) -> String {
        if let guest = GuestError.classify(error) {
            apply(error)
            switch guest {
            case .paused: return "\(access.agentName) isn't running, so it wasn't sent."
            case .revoked: return "\(access.ownerName) revoked your access."
            case .forbidden: return "\(access.ownerName)'s machine doesn't allow that."
            default: return guest.description
            }
        }
        if let api = error as? APIError, api.code == "invalid_params" {
            return "\(access.ownerName)'s machine refused the message: \(api.message)"
        }
        return "Couldn't send: \(error.localizedDescription)"
    }

    // MARK: - Picking files

    private func presentPendingPicker() {
        switch pendingPicker {
        case .photos: showPhotoPicker = true
        case .file: showFileImporter = true
        case nil: break
        }
        pendingPicker = nil
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var skipped: [String] = []
        for url in urls {
            guard attachments.count < GramView.Staging.maxAttachments else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= GramView.Staging.maxFileBytes,
                  let staged = GramView.Staging.copy(of: url, named: url.lastPathComponent)
            else {
                skipped.append(url.lastPathComponent)
                continue
            }
            attachments.append(Attachment(name: url.lastPathComponent, mime: Self.mimeType(for: url),
                                          staged: staged))
        }
        note = skipped.isEmpty ? nil : "Not attached (too large, unreadable or over the limit): "
            + skipped.joined(separator: ", ")
    }

    private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
        loadingAttachment = true
        defer { loadingAttachment = false }
        var skipped = 0
        for item in items {
            guard attachments.count < GramView.Staging.maxAttachments,
                  let media = try? await item.loadTransferable(type: PickedMedia.self),
                  let staged = media.staged
            else {
                skipped += 1
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let base = type?.conforms(to: .movie) == true ? "video" : "image"
            let name = "\(base)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            attachments.append(Attachment(name: name, mime: type?.preferredMIMEType ?? "image/jpeg",
                                          staged: staged))
        }
        note = skipped == 0 ? nil : "\(skipped) item\(skipped == 1 ? "" : "s") too large or unreadable"
    }

    /// A library pick copied into staging inside the export callback, since PhotosUI deletes
    /// its temp file when the callback returns. nil = over the size cap or uncopyable.
    private struct PickedMedia: Transferable {
        let staged: StagedAttachment?
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .item) { received in
                guard let size = try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= GramView.Staging.maxFileBytes
                else { return PickedMedia(staged: nil) }
                return PickedMedia(staged: GramView.Staging.copy(
                    of: received.file, named: received.file.lastPathComponent))
            }
        }
    }

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: - Debug probe

    #if DEBUG
    /// Methods the mock host refused as not allowed for guests, for the UI tests.
    private var forbiddenCallsProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("guest-forbidden-calls")
            .accessibilityLabel(forbiddenProbe)
            .task {
                while !Task.isCancelled {
                    forbiddenProbe = GuestMockTransport.forbiddenCalls.joined(separator: ",")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }
    #endif
}

extension AgentInfo {
    /// The folder a guest sees for this agent: the nearest cwd component that isn't just the
    /// agent's own name or kind ("~/repos/llm-opt" for llm-opt → "repos").
    var guestFolder: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let skip = Set([name, agent].compactMap { $0 })
        return URL(fileURLWithPath: cwd).pathComponents.reversed()
            .first { $0 != "/" && $0 != "." && !skip.contains($0) }
    }
}

/// The status pill of the guest pane's status row.
private struct GuestStatusPill: View {
    let label: String
    let color: Color
    let dot: Color
    let fill: Color
    let pulsing: Bool

    var body: some View {
        HStack(spacing: 7) {
            PulsingDot(color: dot, active: pulsing)
            Text(label).font(Typography.machine(12, .semibold)).tracking(1.2)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-status-pill")
    }
}

/// "Shared by <owner>": whose agent the guest is looking at.
struct SharedByChip: View {
    let owner: String

    var body: some View {
        Text("Shared by \(owner)")
            .font(Typography.app(12, .medium))
            .foregroundStyle(Palette.textDim)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// The card over the terminal when the agent can't be reached.
private struct GuestCenterMessage: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.textDim)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Palette.surfaceRaised))
                .padding(.bottom, 12)
            Text(title)
                .font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
                .padding(.bottom, 6)
            Text(detail)
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .lineSpacing(5)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guest-center-message")
    }
}
