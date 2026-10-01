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
    @State private var tab: Tab
    @State private var showingPane = false
    /// The agent screen's tab; a tapped push picks it.
    @State private var paneTab: GuestPaneTab = .terminal
    @State private var confirmingRemove = false
    /// Observed so a Text size change re-renders at the new `Typography.scale`.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    init(access: GuestAccess, connect: @escaping () throws -> GuestConnection,
         initialTab: Tab = .agents, pollInterval: Duration = .seconds(5),
         onBack: (() -> Void)?, onLeave: @escaping () -> Void) {
        self.access = access
        self.connect = connect
        self.pollInterval = pollInterval
        self.onBack = onBack
        self.onLeave = onLeave
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        let _ = uiFontScale
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

    private var header: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 3) {
                Text(access.machineLabel)
                    .font(Typography.app(21, .bold)).tracking(-0.21)
                    .foregroundStyle(Palette.text).lineLimit(1)
                    .accessibilityIdentifier("guest-home-title")
                Text("Shared by \(access.ownerName) · 1 agent")
                    .font(Typography.machine(13, .medium)).foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                        .frame(width: 36, height: 36)
                        .background(Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Machines")
                .accessibilityIdentifier("guest-home-back")
                .padding(.leading, 16).padding(.top, 18)
            }
        }
        .frame(height: 74)
    }

    @ViewBuilder
    private var content: some View {
        if let connectError {
            message(icon: "key.slash", title: "Can't use this phone's key", body: connectError)
        } else {
            switch status {
            case .loading:
                ProgressView().tint(Palette.textDim).frame(height: 64).padding(.top, 26)
            case .live(let row):
                sectionHeader(row.flatMap { $0.info.guestRunning == false ? nil : $0.group.sectionTitle } ?? "Paused")
                    .padding(.top, 8).padding(.bottom, 8)
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
                message(icon: "person.crop.circle.badge.xmark", title: "Access removed", body: why) {
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

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased()).tracking(1.56)
                Text("⌄").font(Typography.machine(10, .semibold))
            }
            .font(Typography.machine(12, .semibold))
            .foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
        }
        .padding(.horizontal, 16)
    }

    /// The shared agent's row. With no listed agent, or one the host reports as not
    /// the pane's foreground program, it reads "isn't running" with a paused chip.
    private func agentRow(_ row: AgentRow?) -> some View {
        let running = row.map { $0.info.guestRunning != false } ?? false
        return HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: row?.info.agent))
                Text(AgentIdentity.glyph(for: row?.info.agent ?? access.agentName))
                    .font(Typography.app(19, .bold)).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .opacity(running ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(access.agentName)
                    .font(Typography.app(17, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(running ? row.map(meta) ?? "" : "\(access.agentName) isn't running")
                    .font(Typography.machine(13.5)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let row, running {
                badge(row)
            } else {
                Text("paused")
                    .font(Typography.machine(12, .medium)).foregroundStyle(Palette.textDim)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Palette.surfaceRaised, in: Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(running ? edge(row?.group ?? .idle) : Palette.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    /// The guest projection carries no cwd or title, so the meta is the agent kind and
    /// its state ("omp · working"), or the state alone when the kind is unknown.
    private func meta(_ row: AgentRow) -> String {
        [row.info.agent, row.group.label].compactMap { $0 }.joined(separator: " · ")
    }

    private func edge(_ group: AgentGroup) -> Color {
        switch group {
        case .needsYou, .unrecognised: return Palette.waiting.opacity(0.5)
        case .stopped: return Palette.died.opacity(0.5)
        case .working, .idle: return Palette.hairline
        }
    }

    /// The same status vocabulary as the owner's rows.
    @ViewBuilder
    private func badge(_ row: AgentRow) -> some View {
        switch row.group {
        case .working:
            HStack(spacing: 6) {
                Text("now").font(Typography.machine(13, .medium)).foregroundStyle(Palette.working)
                GuestSpinner()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.group.label))
        case .needsYou:
            symbolBadge("exclamationmark", Palette.waiting, circle: true).accessibilityLabel(Text(row.group.label))
        case .unrecognised:
            symbolBadge("questionmark", Palette.waiting, circle: true).accessibilityLabel(Text(row.group.label))
        case .stopped:
            symbolBadge("xmark", Palette.died, circle: false).accessibilityLabel(Text(row.group.label))
        case .idle:
            Circle().stroke(Palette.textFaint, lineWidth: 1.5).frame(width: 8, height: 8)
                .accessibilityLabel(Text(row.group.label))
        }
    }

    private func symbolBadge(_ system: String, _ color: Color, circle: Bool) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .frame(width: 26, height: 26)
            .overlay {
                if circle {
                    Circle().stroke(color.opacity(0.55), lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.55), lineWidth: 1.5)
                }
            }
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
            // Matched by the grant's terminal id, else by name (the projection may omit it).
            let shared = agents.first { $0.terminalID == access.agentTarget }
                ?? agents.first { $0.name == access.agentName }
            status = .live(shared.map { AgentRow(info: $0) })
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

/// The mock's working spinner: a faint blue track with one bright quarter, turning.
private struct GuestSpinner: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.working.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25)
                .stroke(Palette.working, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(spin ? 315 : -45))
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}
