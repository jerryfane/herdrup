import Combine
import SwiftUI
import HerdrKit

/// One live connection to a shared machine: the relay client, this phone's key, and what
/// the host offers this guest (learned from each call's hello).
struct GuestConnection {
    let client: HerdrClient
    let fingerprint: String
    let features: GuestFeaturesModel

    init(client: HerdrClient, fingerprint: String, features: GuestFeaturesModel = GuestFeaturesModel()) {
        self.client = client
        self.fingerprint = fingerprint
        self.features = features
    }

    /// Connects over the relay with this install's device key. Constructing the
    /// transport does not dial; each call opens its own relay socket.
    static func open(_ access: GuestAccess) throws -> GuestConnection {
        let identity = try GuestDevice.identity()
        let features = GuestFeaturesModel()
        let transport = access.transport(identity: identity, onFeatures: features.sink())
        return GuestConnection(client: HerdrClient(transport: transport),
                               fingerprint: identity.fingerprint, features: features)
    }
}

/// Screen G2: a guest's home. One machine, only the shared agent, and two tabs
/// (Agents, Settings); nothing about the owner's fleet. The shared agent's Gram, when the
/// owner shares it, is a tab of the agent's own screen.
struct GuestHomeView: View {
    let access: GuestAccess
    let connect: () throws -> GuestConnection
    /// Back to the machine list; nil when this share is the only thing on the phone.
    let onBack: (() -> Void)?
    /// Called after the share was removed (Leave, or Remove once access is lost).
    let onLeave: () -> Void
    let pollInterval: Duration
    let embedded: Bool

    enum Tab: Hashable { case agents, settings }

    private enum Status: Equatable {
        case loading
        /// The shared agent's row; nil when the host lists no agent (it exited, or the
        /// pane runs something else), which renders as "isn't running", not as gone.
        case live(AgentRow?)
        case offline
        case lost(String)
        case failed(String)
    }

    @State private var connection: GuestConnection?
    @State private var connectError: String?
    @State private var status: Status = .loading
    @State private var tab: Tab = .agents
    @State private var showingPane = false
    /// The agent screen's tab; a tapped push picks it.
    @State private var paneTab: GuestPaneTab = .terminal
    @State private var confirmingRemove = false
    @Environment(\.displayScale) private var displayScale
    /// Observed so a Text size change re-renders at the new `Typography.scale`.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    init(access: GuestAccess, connect: @escaping () throws -> GuestConnection,
         pollInterval: Duration = .seconds(5), embedded: Bool = false,
         onBack: (() -> Void)?, onLeave: @escaping () -> Void) {
        self.access = access
        self.connect = connect
        self.pollInterval = pollInterval
        self.embedded = embedded
        self.onBack = onBack
        self.onLeave = onLeave
    }

    var body: some View {
        let _ = uiFontScale
        Group {
            if embedded {
                content
                    .fullScreenCover(isPresented: $showingPane) {
                        if let connection {
                            GuestPaneView(client: connection.client, access: access, features: connection.features,
                                          tab: $paneTab) { showingPane = false }
                        }
                    }
                    .confirmationDialog("Remove \(access.agentName)?", isPresented: $confirmingRemove,
                                        titleVisibility: .visible) {
                        Button("Remove share", role: .destructive) { leave() }
                    }
            } else {
                ZStack {
            TabView(selection: $tab) {
                agentsTab
                    .tag(Tab.agents)
                    .tabItem { Label("Agents", systemImage: "square.grid.2x2.fill") }
                GuestSettingsView(access: access, fingerprint: connection?.fingerprint,
                                  client: connection?.client, onLeave: leave)
                    .tag(Tab.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Palette.text)
            if showingPane, let connection {
                GuestPaneView(client: connection.client, access: access, features: connection.features,
                              tab: $paneTab) {
                    withAnimation(.easeOut(duration: 0.26)) { showingPane = false }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
                }
            }
        }
        .task { await poll() }
        // Each connection registers this phone's push token with the host once it learns the
        // host's features, so the host holds the current token and Gram preference.
        .onReceive(connection?.features.$current.eraseToAnyPublisher()
                   ?? Empty().eraseToAnyPublisher()) { features in
            guard let features, let client = connection?.client else { return }
            Task { await GuestPushCenter.shared.connected(access, client: client, features: features) }
        }
        // A tapped push for this share: its Gram tab for a Gram, else the terminal.
        .onReceive(PushCenter.shared.$pendingGuest) { route in
            guard let route, route.access(in: [access]) != nil else { return }
            PushCenter.shared.pendingGuest = nil
            tab = .agents
            paneTab = route.kind == .gram ? .gram : .terminal
            showingPane = true
        }
    }

    private var agentsTab: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        sharedBy
                        content
                        GuestShellStyle.note {
                            Text("You can see only the agents \(access.ownerName) shares with you.")
                        }
                        .padding(.top, 18)
                    }
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await load() }
            }
        }
        .toolbar(showingPane ? .hidden : .automatic, for: .tabBar)
        .confirmationDialog("Remove \(access.machineLabel)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove share", role: .destructive) { leave() }
        } message: {
            Text("\(access.ownerName) no longer shares \(access.agentName) with you.")
        }
    }

    /// The owner's Agents bar: a small centred title, Back in its capsule. In an iPad window
    /// Back joins the right-hand capsule, clear of the window controls (`SectionBackSlot`).
    private var header: some View {
        SectionTopBar(title: "Agents", leading: {
            if onBack != nil { SectionBackSlot(.leading) { backButton } }
        }) {
            if onBack != nil { SectionBackSlot(.trailing) { backButton } }
        }
    }

    private var backButton: some View {
        SectionBarButton(icon: "chevron.left", label: "Machines", identifier: "guest-home-back") {
            onBack?()
        }
    }

    /// Whose machine this is, where the owner's roster has its search field; it scrolls
    /// away with the list.
    private var sharedBy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(access.machineLabel)
                .font(Typography.app(20, .bold)).tracking(-0.2)
                .foregroundStyle(Palette.text).lineLimit(1)
                .accessibilityIdentifier("guest-home-title")
            Text("Shared by \(access.ownerName) · 1 agent")
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let connectError {
            message(icon: "key.slash", title: "\(access.agentName): key unavailable", body: connectError)
        } else {
            switch status {
            case .loading:
                ProgressView().tint(Palette.textDim).frame(height: 64).padding(.top, 26)
            case .live(let row):
                Button {
                    withAnimation(.easeOut(duration: 0.26)) { showingPane = true }
                } label: {
                    agentRow(row)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guest-agent-row")
            case .offline:
                message(icon: "wifi.slash", title: "\(access.machineLabel) is offline",
                        body: "\(access.agentName) will show here again when the machine is back.")
            case .lost(let why):
                message(icon: "person.crop.circle.badge.xmark", title: "\(access.agentName): access removed", body: why) {
                    Button { confirmingRemove = true } label: {
                        Text("Remove share")
                            .font(Typography.app(13.5, .semibold)).foregroundStyle(Palette.died)
                            .padding(.horizontal, 14).frame(height: 34)
                            .overlay(Capsule().stroke(Palette.died.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            case .failed(let why):
                message(icon: "exclamationmark.triangle", title: "Can't reach \(access.agentName)", body: why)
            }
        }
    }

    /// The shared agent as a Messages-style row, like the owner's roster (#352): full width
    /// on the ground, the round avatar with its status badge, the name over the preview, and
    /// an inset divider. With no listed agent, or one the host reports as not the pane's
    /// foreground program, it reads "Agent unavailable" with a dimmed avatar.
    private func agentRow(_ row: AgentRow?) -> some View {
        let running = row.map { $0.info.guestRunning != false } ?? false
        let group = running ? row?.group : nil
        return HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: 20, height: 1)
            AgentAvatar(name: access.agentName,
                        badge: group.map(AgentAvatarBadge.init) ?? .none,
                        badgeLabel: group?.label ?? "Agent unavailable")
                .opacity(running ? 1 : 0.55)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(access.agentName)
                        .font(.system(size: 17 * Typography.scale, weight: .semibold))
                        .foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityHidden(true)
                }
                // A waiting agent's preview reads in the primary colour, like an unread message.
                Text(running ? row.map(meta) ?? "" : "Agent unavailable")
                    .font(.system(size: 15 * Typography.scale))
                    .foregroundStyle(group == .needsYou ? Palette.text : Palette.textDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 86 * max(1, Typography.scale), alignment: .center)
            // The divider starts where the text starts, not under the avatar.
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairline).frame(height: 1 / displayScale)
                    .padding(.trailing, 16)
            }
        }
        .contentShape(Rectangle())
    }

    /// The guest projection carries no cwd or title, so the preview is the agent kind and
    /// its state ("omp · working"), or the state alone when the kind is unknown.
    private func meta(_ row: AgentRow) -> String {
        [row.info.agent, row.group.label].compactMap { $0 }.joined(separator: " · ")
    }

    private func message<Extra: View>(
        icon: String, title: String, body: String, @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.textDim)
                .frame(width: 46, height: 46)
                .background(Palette.surfaceRaised, in: Circle())
                .padding(.bottom, 12)
            Text(title)
                .font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
                .padding(.bottom, 6)
            Text(body)
                .font(Typography.app(14)).foregroundStyle(Palette.textDim).lineSpacing(3.5)
            extra()
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 22)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 24).padding(.top, 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-home-message")
    }

    private func poll() async {
        do {
            connection = try connect()
        } catch {
            connectError = GuestDevice.describe(error, machine: access.machineLabel)
            return
        }
        while !Task.isCancelled {
            await load()
            if case .lost = status { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func load() async {
        guard let client = connection?.client else { return }
        do {
            let agents = try await client.agentList()
            // The host already lists only the shared agent; the app still shows nothing
            // else, so a host bug cannot reveal the owner's other agents.
            // Matched by the grant's terminal or pane id, else by name (the projection may
            // omit terminal_id).
            let shared = agents.first(where: access.isSharedAgent)
                ?? agents.first { $0.name == access.agentName }
            status = .live(shared.map { AgentRow(info: $0) })
            // The owner renamed the agent: the share follows it, saved for every screen.
            if let renamed = access.renamed(listing: agents) {
                SharedMachinesStore.shared.update(renamed)
            }
        } catch is CancellationError {
            return
        } catch {
            guard let guest = GuestError.classify(error) else {
                status = .failed(GuestDevice.describe(error, machine: access.machineLabel))
                return
            }
            if guest.isAccessLost {
                status = .lost("\(access.ownerName) no longer shares \(access.agentName) with you.")
            } else if guest == .hostOffline {
                status = .offline
            } else {
                status = .failed(GuestDevice.describe(guest, machine: access.machineLabel))
            }
        }
    }

    private func leave() {
        SharedMachinesStore.shared.remove(access)
        onLeave()
    }
}
