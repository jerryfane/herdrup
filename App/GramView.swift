import HerdrKit
import SwiftUI

/// The Gram page: the owner's side of the owner<->agent message channel.
///
/// The app is the OWNER. This shows the inbox (agent->owner messages the fleet
/// sent, plus the owner's own posts and their claim state) newest-first, and a
/// composer to post to the shared grab-queue or one agent directly. Text only;
/// file attachments are a later phase.
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

    @State private var messages: [GramMessage] = []
    @State private var phase: LoadPhase = .loading
    @State private var recipient: Recipient = .queue
    @State private var draft: String = ""
    @State private var sending = false
    @State private var banner: String?

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
            composer
        }
        .background(Palette.ground.ignoresSafeArea())
        .task { await load(initial: true) }
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
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(Palette.textFaint)
                    Text(message)
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
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
                    if let banner {
                        Text(banner)
                            .font(Typography.app(12))
                            .foregroundStyle(Palette.died)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(messages) { message in
                        GramRow(message: message)
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
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
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
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
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
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func load(initial: Bool) async {
        // Show the spinner only on the first load with nothing to show yet; a
        // refresh keeps the current messages visible.
        if initial && messages.isEmpty { phase = .loading }
        do {
            let fetched = try await client.gramList()
            messages = fetched
            phase = .loaded
            banner = nil
        } catch let error as APIError where error.code == "gram_unavailable" {
            phase = .unavailable("Gram isn't available on this server yet.")
        } catch {
            if messages.isEmpty {
                phase = .unavailable("Couldn't load messages. Pull to retry.")
            } else {
                banner = "Refresh failed — showing the last loaded messages."
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let posted = try await client.gramPost(text: text, to: recipient.wireTo)
            draft = ""
            // Optimistically show it immediately, then reconcile on the next load.
            messages.insert(posted, at: 0)
            banner = nil
        } catch let error as APIError {
            banner = error.message
        } catch {
            banner = "Couldn't send. Try again."
        }
    }

    private func markReadIfNeeded(_ message: GramMessage) {
        guard message.isUnread else { return }
        Task {
            try? await client.gramMarkRead(id: message.id)
            // Optimistically flip the local copy so the unread dot/badge clears.
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].readByOwner = true
            }
        }
    }
}

/// One message row. Agent->owner shows the sender's identity chip; owner->agent
/// shows the recipient and the claim state of a queued item.
private struct GramRow: View {
    let message: GramMessage

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
                Text(message.text)
                    .font(Typography.app(14))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
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
