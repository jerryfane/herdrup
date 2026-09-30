import HerdrKit
import SwiftUI

/// A guest's view of the one agent shared with them: the live terminal, view only, and a
/// composer whose messages and files reach the agent under the guest's name. When the owner
/// shares the agent's Gram, a second tab lists it.
struct GuestPaneView: View {
    let client: HerdrClient
    let access: GuestAccess
    @ObservedObject var features: GuestFeaturesModel
    @Binding var tab: GuestPaneTab
    let onClose: () -> Void

    init(client: HerdrClient, access: GuestAccess, features: GuestFeaturesModel,
         tab: Binding<GuestPaneTab>, onClose: @escaping () -> Void) {
        self.client = client
        self.access = access
        self.features = features
        _tab = tab
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
    @State private var findOpen = false
    @State private var findTerm = ""
    @State private var findGeneration = 0
    @State private var findDirection: FindRequest.Direction = .forward
    @State private var findMatches: (Int, Int) = (0, 0)
    @FocusState private var findFocused: Bool
    @StateObject private var composerKeyboard = ComposerKeyboard()
    /// The guest's own terminal text size (A− / A+), separate from the owner's setting.
    @AppStorage(GuestTerminalSize.storageKey) private var terminalFontSize = GuestTerminalSize.defaultPoints
    /// The host refused guest resizing (an older host): for the rest of this session the
    /// terminal fits the agent's grid to the width and the size controls are gone.
    @State private var resizeRefused = false
    @StateObject private var gram = GuestGramModel()
    @ObservedObject private var guestPush = GuestPushCenter.shared
    #if DEBUG
    @State private var forbiddenProbe = ""
    @State private var hostCallsProbe = ""
    #endif

    /// The owner shares this agent's Gram with the guest (the host's hello says so).
    private var showsGram: Bool { features.current?.gram == true }
    private var showingGram: Bool { showsGram && tab == .gram }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            statusRow
            if showsGram { tabStrip }
            ZStack(alignment: .bottom) {
                // The terminal stays mounted under the Gram tab, so its stream and scrollback
                // survive a look at Gram.
                terminalArea
                    .opacity(showingGram ? 0 : 1)
                    .allowsHitTesting(!showingGram)
                    .accessibilityHidden(showingGram)
                if showingGram {
                    GuestGramList(client: client, access: access, model: gram)
                        .background(Palette.ground)
                }
                if guestPush.asking == access.id, let current = features.current {
                    GuestPushPrompt(
                        agentName: access.agentName, ownerName: access.ownerName, gram: current.gram,
                        onEnable: {
                            Task { await guestPush.enable(access, client: client, features: current) }
                        },
                        onDecline: { guestPush.decline(access) })
                    .padding(.horizontal, 12).padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            bottomBlock
        }
        .background(Palette.groundMachine.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay { EdgeSwipeBack { onClose() } }
        .task { await pollLoop() }
        // Once the host's features are known: offer push (first open only) and load Gram, so
        // the unread count shows before the guest opens the tab.
        .task(id: features.current) {
            guard let current = features.current else { return }
            await guestPush.paneOpened(access, client: client, features: current)
            if current.gram { await gram.refresh(client: client, access: access) }
        }
        .onChange(of: tab) { _, _ in
            guard showingGram else { return }
            if findOpen { toggleFind() }
            Task {
                await gram.refresh(client: client, access: access)
                await gram.markAllRead(client: client)
            }
        }
        // Viewed is read: whatever lands in the list while it shows is marked read.
        .onChange(of: gram.messages) { _, _ in
            guard showingGram else { return }
            Task { await gram.markAllRead(client: client) }
        }
        // A Gram push from this share's host: reload.
        .onReceive(PushCenter.shared.$guestGramArrival) { arrival in
            guard let arrival, arrival.hostID == access.endpoint.hostID, showsGram else { return }
            Task { await gram.refresh(client: client, access: access) }
        }
        .composerAttachPicker(
            isPresented: $showAttachSheet, loading: $loadingAttachment,
            room: { GramView.Staging.maxAttachments - attachments.count }
        ) { outcome in
            attachments += outcome.files.map {
                Attachment(name: $0.name, mime: $0.mime, staged: $0.staged)
            }
            note = outcome.note
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { debugProbes }
        #endif
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        HStack(spacing: 4) {
            tabButton("Terminal", systemImage: "terminal", tab: .terminal, id: "guest-tab-terminal")
            tabButton("Gram", systemImage: "paperplane", tab: .gram, id: "guest-tab-gram",
                      badge: gram.unreadCount)
        }
        .padding(3)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().stroke(Palette.hairlineQuiet, lineWidth: 1))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.ground)
    }

    private func tabButton(_ title: String, systemImage: String, tab value: GuestPaneTab, id: String,
                           badge: Int = 0) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(Typography.app(14, .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(Typography.machine(11, .bold)).foregroundStyle(Palette.ground)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Palette.waiting))
                        .accessibilityIdentifier("guest-gram-unread")
                }
            }
            .foregroundStyle(selected ? Palette.text : Palette.textDim)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Capsule().fill(selected ? Palette.surfaceRaised : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
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
            if !showingGram {
                Button { toggleFind() } label: {
                    Image(systemName: findOpen ? "xmark" : "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.text).frame(width: 28, height: 44)
                }
                .accessibilityLabel(findOpen ? "Close search" : "Search")
                .accessibilityIdentifier("guest-find")
            }
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
            if !showingGram && !resizeRefused && (availability == .running || availability == .connecting) {
                textSizeControls
            }
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

    /// A− / A+: the guest's text size. The terminal proposes the grid that fits at that size,
    /// so the agent's terminal is resized to it (for the owner's screens too).
    private var textSizeControls: some View {
        HStack(spacing: 2) {
            textSizeButton("textformat.size.smaller", label: "Smaller text", id: "guest-font-decrease",
                           enabled: terminalFontSize > GuestTerminalSize.range.lowerBound, taps: -1)
            textSizeButton("textformat.size.larger", label: "Larger text", id: "guest-font-increase",
                           enabled: terminalFontSize < GuestTerminalSize.range.upperBound, taps: 1)
        }
    }

    private func textSizeButton(_ symbol: String, label: String, id: String, enabled: Bool,
                                taps: Int) -> some View {
        Button {
            terminalFontSize = GuestTerminalSize.stepped(terminalFontSize, by: taps)
        } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
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
                    fitsStreamWidth: resizeRefused,
                    onResizeRefused: { resizeRefused = true },
                    onStreamEnded: streamEnded,
                    fontSize: CGFloat(GuestTerminalSize.clamped(terminalFontSize)),
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
                Text(resizeRefused ? "View-only · this host doesn't support guest resizing"
                                   : "Terminal is view-only · send messages below")
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
                ComposerAttachButton(busy: loadingAttachment) { showAttachSheet = true }
                    .disabled(!canCompose || sending || loadingAttachment)
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
                // Attachments are the guest's own Grams: show them in the Gram tab.
                if !batch.isEmpty, showsGram { await gram.refresh(client: client, access: access) }
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

    // MARK: - Debug probes

    #if DEBUG
    /// For the UI tests: methods the mock host refused as not allowed for guests
    /// (`guest-forbidden-calls`), and the Gram and push calls it answered, with their
    /// arguments (`guest-host-calls`).
    private var debugProbes: some View {
        ZStack {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("guest-forbidden-calls")
                .accessibilityLabel(forbiddenProbe)
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("guest-host-calls")
                .accessibilityLabel(hostCallsProbe)
        }
        .frame(width: 1, height: 1)
        .task {
            while !Task.isCancelled {
                forbiddenProbe = GuestMockTransport.forbiddenCalls.joined(separator: ",")
                hostCallsProbe = GuestMockTransport.hostCalls.joined(separator: ";")
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
