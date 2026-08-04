import SwiftUI
import Foundation
import Security
import Darwin   // inet_pton/inet_ntop for IPv6 canonicalization
import HerdrKit

// Phase 4, first real slice: terminal-first, on the merged pure-Swift transport.
// Connect over the Citadel transport, list agents, read a pane, render it.
// Termius-inspired dark. ANSI styling and gestures are follow-ups; plain
// monospace is a readable terminal v1.
@main
struct HerdrApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// Palette / Typography / status tokens now live in DesignSystem.swift.

/// Cross-launch TOFU: the persistent `HostKeyPolicy` the transport contract
/// assigns to the app (HerdrKit's `PinStore` is in-memory only and cannot be
/// Keychain-backed). Fingerprints are stored in the iOS Keychain keyed by
/// host:port; compare-and-pin is one locked operation, so a changed key is
/// hard-stopped ACROSS launches, not just within a process. Lives in the app
/// target because the Security framework is not available on Linux, where
/// HerdrKit still builds.
final class KeychainHostKeyPolicy: HostKeyPolicy, @unchecked Sendable {
    /// Shared so all transports enforce one lock/pin set (SwiftUI re-inits View
    /// structs, so a per-view instance would churn and split the lock).
    static let shared = KeychainHostKeyPolicy()

    private let lock = NSLock()
    private let service = "dev.herdr.hostkey.pins"

    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        lock.lock(); defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        switch lookup(account: account) {
        case .found(let existing):
            return existing == presented ? .trust : .reject
        case .notFound:
            // First contact: trust ONLY if the pin actually persists; a failed
            // write must not read as "trusted but unpinned" next launch.
            return store(account: account, fingerprint: presented) ? .trust : .reject
        case .error:
            // A Keychain read error is NOT the absence of a pin. Fail CLOSED —
            // reading it as "no pin" would trust any key on a transient failure.
            return .reject
        }
    }

    /// Binds a host to an EXACT fingerprint the user verified out of band. Used
    /// for a verified key rotation: an atomic replace (delete + add under the
    /// lock), so there is no delete-then-TOFU window where a substituted key
    /// could be pinned — only the fingerprint passed here is trusted next connect.
    /// Returns whether the fingerprint was actually persisted. The caller MUST
    /// NOT reconnect on false — reconnecting without a stored pin would treat the
    /// next key as first contact (a TOFU window).
    @discardableResult
    func pin(host: String, port: UInt16, fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let account = accountKey(host: host, port: port)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // One checked SecItemUpdate replaces the value IN PLACE (no window where
        // the pin is absent). Only if there is nothing to update do we add. Under
        // the lock, there is no check-then-act race. Every status is checked, so
        // a failed persist is reported rather than silently trusted later.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(fingerprint.utf8)] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = Data(fingerprint.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Canonicalizes the pin key so spellings that reach the same host share one
    /// pin — otherwise a different spelling is a fresh first-contact that bypasses
    /// the pin. IPv6 literals have many textual forms (RFC 5952), so they are
    /// normalized through inet_pton/inet_ntop; DNS names are case-insensitive
    /// (RFC 4343) and may carry a trailing dot.
    private func accountKey(host: String, port: UInt16) -> String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let canonicalIP = canonicalIPv6(h) {
            h = canonicalIP
        } else {
            h = h.lowercased()
            while h.hasSuffix(".") { h.removeLast() }
        }
        return "\(h):\(port)"
    }

    /// Canonical IPv6 text (compressed, lowercase) via the resolver, or nil if
    /// `s` is not an IPv6 literal. A scoped address keeps its zone id (`%en0`)
    /// lowercased so `fe80::1%EN0` and `fe80::1%en0` share a pin — the zone is
    /// canonicalized alongside the address rather than left to split the pin.
    private func canonicalIPv6(_ s: String) -> String? {
        let parts = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        var addr = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        var canonical = String(cString: buffer)
        if parts.count == 2 {
            // Lowercase the zone id — a STABLE canonicalization. An earlier
            // version mapped the zone through if_nametoindex, but that was a
            // fail-open (backfill review): if_nametoindex is a case-sensitive
            // exact-match lookup (so `%EN0` and `%en0` took different branches
            // and split the pin), and worse it embedded the kernel-assigned
            // interface INDEX, which is runtime state that changes across
            // reboots — a moved index no longer matches the pin and the next key
            // is trusted as first contact. Lowercasing is stable and closes the
            // realistic (case) variation; a name-vs-numeric-zone difference is a
            // theoretical link-local-only edge, not worth an unstable key.
            canonical += "%" + parts[1].lowercased()
        }
        return canonical
    }

    private enum Lookup { case found(String), notFound, error }

    private func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let fingerprint = String(data: data, encoding: .utf8) else { return .error }
            return .found(fingerprint)
        case errSecItemNotFound:
            return .notFound
        default:
            return .error   // transient/availability/auth error — not an absence
        }
    }

    private func store(account: String, fingerprint: String) -> Bool {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

struct RootView: View {
    // Owns the transport (so disconnect can `close()` it — that's the transport's
    // method, not the client's), the credentials (to rebuild on reconnect), and
    // the pin policy (to forget a host key on a verified rotation).
    @State private var transport: CitadelTransport?
    @State private var client: HerdrClient?
    @State private var credentials: SSHCredentials?
    @State private var session = 0   // bumped to force a fresh load on reconnect
    private let pins = KeychainHostKeyPolicy.shared

    var body: some View {
        Group {
            #if DEBUG
            if let mock = ScreenshotMock.mode {
                mockView(mock)
            } else {
                liveContent
            }
            #else
            liveContent
            #endif
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var liveContent: some View {
        if let client, let credentials {
            TerminalHomeView(
                client: client,
                onDisconnect: { disconnect() },
                onTrustHostKey: { fingerprint in trustAndReconnect(credentials, fingerprint: fingerprint) }
            )
            .id(session)
        } else {
            ConnectView { connect($0) }
        }
    }

    #if DEBUG
    /// Renders a screen from MockTransport (no connection, no key) so the buildbox
    /// can screenshot the list/pane views safely.
    @ViewBuilder
    private func mockView(_ mode: ScreenshotMock) -> some View {
        let mockClient = HerdrClient(transport: MockTransport())
        switch mode {
        case .list:
            TerminalHomeView(client: mockClient, onDisconnect: {}, onTrustHostKey: { _ in false },
                             livePaneIDs: MockTransport.demoLivePaneIDs)
        case .pane:
            NavigationStack {
                TerminalPaneView(client: mockClient, paneID: "w1:p1", title: "jarvis")
            }
        }
    }
    #endif

    private func connect(_ creds: SSHCredentials) {
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        credentials = creds
        transport = newTransport
        client = HerdrClient(transport: newTransport)
    }

    private func disconnect() {
        let closing = transport
        Task { await closing?.close() }
        client = nil
        transport = nil
        credentials = nil
    }

    /// A verified key rotation: pin the EXACT fingerprint the user verified out
    /// of band (from the rejection), then reconnect. Because the pin is bound to
    /// that fingerprint before reconnecting, a substituted key during the
    /// reconnect is rejected — there is no re-TOFU window. Bumping `session`
    /// recreates the home view so its load re-runs.
    /// Returns false (without reconnecting) if the verified key could not be
    /// persisted — reconnecting then would reopen a first-contact TOFU window.
    private func trustAndReconnect(_ creds: SSHCredentials, fingerprint: String) -> Bool {
        guard pins.pin(host: creds.host, port: creds.port, fingerprint: fingerprint) else { return false }
        let closing = transport
        Task { await closing?.close() }
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        transport = newTransport
        client = HerdrClient(transport: newTransport)
        session += 1
        return true
    }
}

/// Collects host/key and constructs the transport. Constructing does not connect —
/// the first request does — so this screen never blocks on the network.
struct ConnectView: View {
    var onConnect: (SSHCredentials) -> Void

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var keyPEM = ""

    /// A valid SSH port, or nil — invalid input is rejected here rather than
    /// silently coerced to 22.
    private var portValue: UInt16? {
        UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1 ? $0 : nil }
    }
    private var portInvalid: Bool { !port.isEmpty && portValue == nil }
    private var canConnect: Bool {
        !host.isEmpty && !username.isEmpty && !keyPEM.isEmpty && portValue != nil
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("herdr")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.working)
                    Text("connect to a host")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Palette.textDim)

                    field("host", text: $host)
                    field("port", text: $port)
                    if portInvalid {
                        Text("invalid port (1–65535)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    field("user", text: $username)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("private key (ed25519 PEM)")
                            .font(.caption).foregroundStyle(Palette.textDim)
                        TextEditor(text: $keyPEM)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .scrollContentBackground(.hidden)
                            .frame(height: 130)
                            .padding(8)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        guard let port = portValue else { return }
                        let credentials = SSHCredentials(
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: port,
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            privateKeyPEM: keyPEM,
                            remoteSocketPath: "")
                        onConnect(credentials)
                    } label: {
                        Text("connect")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canConnect ? Palette.working : Palette.surface)
                            .foregroundStyle(canConnect ? Palette.ground : Palette.textDim)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!canConnect)
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Palette.textDim)
            TextField("", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Palette.text)
                .padding(10)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Lists the agents on the host; tapping one opens its pane. A failed load is
/// recoverable (retry, or disconnect back to the connect form).
struct TerminalHomeView: View {
    let client: HerdrClient
    var onDisconnect: () -> Void
    var onTrustHostKey: (String) -> Bool
    /// The set of panes herdr still lists; anything absent is `stopped`. `nil`
    /// means no census is available yet (the live default) — every agent is
    /// treated as live, the only safe reading. The DEBUG mock passes one so the
    /// stopped section has something to show.
    var livePaneIDs: Set<String>? = nil

    @State private var agents: [AgentInfo] = []
    @State private var error: String?
    @State private var loading = true
    @State private var rejectedFingerprint: String?
    @State private var trustFailed = false
    @State private var search = ""
    // Only the quiet tail (idle) starts collapsed — the model forbids a
    // collapsed group from ever hiding something that wants attention.
    @State private var collapsed: Set<AgentGroup> = Set(AgentGroup.allCases.filter { $0.startsCollapsed })

    /// The whole list derived from the current agents + census. The grouping,
    /// fail-closed placement, stable order, count and quiet flag all live in
    /// HerdrKit's tested `AgentList`, not here.
    private var fullList: AgentList { AgentList(agents: agents, livePaneIDs: livePaneIDs) }

    /// Sections after applying the search box. Search filters the raw agents and
    /// re-derives, so counts and grouping stay honest for the filtered view.
    private var visibleSections: [(group: AgentGroup, rows: [AgentRow])] {
        guard !search.isEmpty else { return fullList.sections }
        let filtered = agents.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || ($0.terminalTitleStripped ?? "").localizedCaseInsensitiveContains(search)
        }
        return AgentList(agents: filtered, livePaneIDs: livePaneIDs).sections
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if let error {
                        errorView(error)
                    } else if loading {
                        Spacer(); ProgressView().tint(Palette.textDim); Spacer()
                    } else {
                        agentList
                    }
                    tabBar
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await load() }
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            circleButton("chevron.left") { onDisconnect() }
            Spacer()
            VStack(spacing: 2) {
                Text("Agents").font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                // The one number, and its restful inverse. Blocked count leads in
                // amber; when the model says nothing is blocked AND nothing is
                // uninterpretable, say so plainly.
                if fullList.needsYouCount > 0 {
                    Text("\(fullList.needsYouCount) need you")
                        .font(Typography.machine(12)).foregroundStyle(Palette.waiting)
                } else if fullList.isQuiet && !agents.isEmpty {
                    Text("nothing needs you")
                        .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                }
            }
            Spacer()
            circleButton("plus") { }   // new-agent screen (04) is not built yet
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    private func circleButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textDim)
                .frame(width: 36, height: 36)
                .background(Palette.surface)
                .clipShape(Circle())
        }
    }

    private var searchField: some View {
        TextField("Search", text: $search)
            .font(Typography.app(15)).foregroundStyle(Palette.text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 4)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabItem("square.grid.2x2.fill", "Agents", active: true)
            tabItem("terminal", "Terminal", active: false)
            tabItem("gearshape", "Settings", active: false)
        }
        .padding(6)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 36).padding(.bottom, 4)
    }

    private func tabItem(_ system: String, _ label: String, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 16, weight: .medium))
            Text(label).font(Typography.app(11, active ? .semibold : .regular))
        }
        .foregroundStyle(active ? Palette.text : Palette.textFaint)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(active ? Palette.card : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: list

    private var agentList: some View {
        ScrollView {
            searchField
            if agents.isEmpty {
                emptyLine("no agents")
            } else if visibleSections.isEmpty {
                // Agents exist but the search matched none — say so, rather than
                // leave a blank scroll that reads as "no agents".
                emptyLine("no matches")
            } else {
                ForEach(visibleSections, id: \.group) { section in
                    sectionView(section.group, section.rows)
                }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity).padding(.top, 44)
    }

    private func sectionView(_ group: AgentGroup, _ rows: [AgentRow]) -> some View {
        let isCollapsed = collapsed.contains(group)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isCollapsed { collapsed.remove(group) } else { collapsed.insert(group) }
            } label: {
                HStack(spacing: 8) {
                    // Count is shown when collapsed (so hidden work is legible);
                    // an expanded section speaks for itself through its cards.
                    Text(isCollapsed ? "\(group.sectionTitle) · \(rows.count)" : group.sectionTitle)
                        .font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 10)

            if !isCollapsed {
                ForEach(rows) { row in
                    NavigationLink {
                        TerminalPaneView(client: client, paneID: row.info.paneID, title: row.title)
                    } label: {
                        card(row)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ row: AgentRow) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: row.info.agent))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: row.info.agent))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text(row.info.terminalTitleStripped ?? row.info.paneID)
                    .font(Typography.machine(12)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            statusBadge(row.group)
        }
        .padding(12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ group: AgentGroup) -> some View {
        switch group {
        case .needsYou: badgeCircle("exclamationmark", group.color)
        case .stopped: badgeCircle("xmark", group.color)
        case .unrecognised: badgeCircle("questionmark", group.color)
        case .working: Text("now").font(Typography.machine(12)).foregroundStyle(group.color)
        case .idle:
            // Not bare, not loud: a small hollow dot so an expanded idle row still
            // has a right-edge anchor.
            Circle().stroke(Palette.textFaint, lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    private func badgeCircle(_ system: String, _ color: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 1.5))
    }

    // MARK: error / host-key recovery (functional, restyled to the tokens)

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        Spacer()
        VStack(spacing: 14) {
            Text(error).font(Typography.machine(13)).foregroundStyle(Palette.died)
                .multilineTextAlignment(.center)
            if let fingerprint = rejectedFingerprint {
                VStack(spacing: 8) {
                    Text("the host key changed. the server now presents:")
                        .font(Typography.app(12)).foregroundStyle(Palette.textDim)
                    Text(fingerprint).font(Typography.machine(11)).foregroundStyle(Palette.text)
                        .textSelection(.enabled).multilineTextAlignment(.center)
                    Text("trust it ONLY if this exactly matches the key you verified out of band.")
                        .font(Typography.app(12)).foregroundStyle(Palette.textDim).multilineTextAlignment(.center)
                }
                Button("trust this key & reconnect") { trustFailed = !onTrustHostKey(fingerprint) }
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.died)
                if trustFailed {
                    Text("could not save the verified key to the keychain — not reconnecting. try again.")
                        .font(Typography.app(12)).foregroundStyle(Palette.died).multilineTextAlignment(.center)
                }
            }
            if rejectedFingerprint == nil {
                Button("retry") { Task { await load() } }
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.working)
            }
        }
        .padding(24)
        Spacer()
    }

    private func load() async {
        loading = true
        error = nil
        rejectedFingerprint = nil
        trustFailed = false
        do {
            agents = try await client.agentList()
        } catch {
            self.error = "\(error)"
            if let transportError = error as? TransportError,
               case .hostKeyRejected(_, let fingerprint) = transportError {
                rejectedFingerprint = fingerprint
            }
        }
        loading = false
    }
}

/// Reads a pane and renders it as folded monospace lines. Folds to the measured
/// view width, and refresh reuses that same width.
struct TerminalPaneView: View {
    let client: HerdrClient
    let paneID: String
    let title: String

    @State private var rawText = ""
    @State private var lines: [String] = []
    @State private var error: String?

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            GeometryReader { geo in
                // Fold from the SETTLED layout width, but cache the result: re-fold
                // ONLY when the width or the text changes (below), not on every body
                // evaluation — folding 200 lines each frame cost ~13ms during
                // scroll. Reading the width in `.task` (an earlier bug) measured it
                // before layout and over-wrapped at the ~20-col minimum.
                let columns = columnCount(for: geo.size.width)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error {
                            Text(error)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Palette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }
                .task(id: paneID) { await refresh() }
                // `initial: true` folds once on appear too, so `lines` is never
                // left empty if the text arrives before the first width change.
                .onChange(of: columns, initial: true) { _, newColumns in refold(columns: newColumns) }
                .onChange(of: rawText) { _, _ in refold(columns: columns) }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(Palette.working)
            }
        }
    }

    /// Rough monospace column count for the footnote font (~7pt advance), less the
    /// 12pt horizontal padding on each side.
    private func columnCount(for width: CGFloat) -> Int {
        max(20, Int((width - 24) / 7.2))
    }

    /// Folds `rawText` to `columns` into the cached `lines`. Called only from the
    /// width/text `onChange`, so scrolling does not re-fold.
    private func refold(columns: Int) {
        lines = TerminalWrap.fold(rawText.components(separatedBy: "\n"), width: columns).flatMap { $0.lines }
    }

    private func refresh() async {
        do {
            let read = try await client.read(pane: paneID, source: .recentUnwrapped, format: .text, lines: 200)
            rawText = read.text
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

#if DEBUG
/// DEBUG-only screenshot mode: renders the list/pane views from MockTransport —
/// no connection, no key, so the buildbox can screenshot them SAFELY (the app
/// otherwise launches to the empty ConnectView). Enable by launching with env
/// `HERDR_SCREENSHOT_MOCK=list` (default) or `=pane`, or the `-herdrScreenshotMock`
/// launch argument.
enum ScreenshotMock {
    case list, pane

    static var mode: ScreenshotMock? {
        let env = ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"]?.lowercased()
        let arg = ProcessInfo.processInfo.arguments.contains("-herdrScreenshotMock")
        guard env != nil || arg else { return nil }
        return env == "pane" ? .pane : .list
    }
}

/// Canned-response transport for the screenshot mock. The JSON is machine-checked
/// in Tests/HerdrKitTests/MockWireFixtureTests.swift (the app target can't be
/// compiled on Linux) — keep the two fixtures in sync.
struct MockTransport: HerdrTransport {
    func roundTrip(_ requestLine: String) async throws -> String {
        if requestLine.contains("agent.list") { return Self.agentList }
        if requestLine.contains("agent.read") { return Self.agentRead }
        return #"{"id":"mock","result":{}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // Realistic herdr statuses only (idle|working|blocked|done|unknown). "needs
    // you" is `blocked`; the STOPPED row is NOT a status string — it comes from
    // liveness (w2:p1 is absent from demoLivePaneIDs below), exactly as the real
    // model derives it. done folds into idle.
    static let agentList = #"""
    {"id":"mock","result":{"type":"agent_list","agents":[
      {"pane_id":"w1:p1","name":"codex","agent":"codex","agent_status":"blocked","terminal_title_stripped":"herdr-ios · asking to run tests"},
      {"pane_id":"w1:p2","name":"claude","agent":"claude","agent_status":"blocked","terminal_title_stripped":"vetrina · overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"codex","agent":"codex","agent_status":"idle","terminal_title_stripped":"trend-scout · exited, code 1"},
      {"pane_id":"w2:p2","name":"claude","agent":"claude","agent_status":"working","terminal_title_stripped":"herdr · editing src/acp.rs"},
      {"pane_id":"w3:p1","name":"claude","agent":"claude","agent_status":"idle","terminal_title_stripped":"clientloop · amigo-poc scaffold"},
      {"pane_id":"w3:p2","name":"codex","agent":"codex","agent_status":"idle","terminal_title_stripped":"aste-screener · apify-harvest"},
      {"pane_id":"w4:p1","name":"gemini","agent":"gemini","agent_status":"idle","terminal_title_stripped":"discovery · redaction-pass v3"},
      {"pane_id":"w4:p2","name":"claude","agent":"claude","agent_status":"done","terminal_title_stripped":"bank-qa · deal-assistant rag"}
    ]}}
    """#

    /// The panes herdr still lists, for the mock render. Excludes w2:p1 so that
    /// row lands in STOPPED via liveness (not a status string). MUST stay in sync
    /// with the census the fixture test uses.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2",
    ]

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach codex\n\n> may I run `just test` on herdr-ios?\n  177 tests, ~30s, no network\n\n  [y] allow   [n] deny   [a] always\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#
}
#endif
