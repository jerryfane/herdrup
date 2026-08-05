import SwiftUI
import Foundation
import Security
import UIKit    // UIPasteboard (Copy diagnostics)
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
                host: credentials.host,
                onReconnect: { reconnect() },
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
                TerminalPaneView(client: mockClient, paneID: "w1:p1", title: "jarvis",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .settings:
            SettingsView(host: "mac.tail-scale.ts.net")
        case .newAgent:
            NewAgentView(client: mockClient,
                         initialFolder: "/root/herdr-ios", initialKind: "codex",
                         initialTask: "Fix the failing schema artifact test and push")
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

    /// Drops and re-establishes the connection with the RETAINED credentials —
    /// the transport is rebuilt and `session` bumped so the home view re-loads.
    /// Distinct from disconnect(): the user stays connected, they do not fall back
    /// to re-entering host/key. No pin change, so the existing pin still guards.
    private func reconnect() {
        guard let creds = credentials else { return }
        let closing = transport
        Task { await closing?.close() }
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        transport = newTransport
        client = HerdrClient(transport: newTransport)
        session += 1
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
        reconnect()   // pin bound above; the reconnect reuses `pins`, so the just-verified key is trusted
        return true
    }
}

/// Collects host/key and constructs the transport. Constructing does not connect —
/// the first request does — so this screen never blocks on the network.
struct ConnectView: View {
    var onConnect: (SSHCredentials) -> Void

    @State private var host = ""
    @State private var username = ""
    @State private var keyPEM = ""
    @State private var showingKeySheet = false

    // Host accepts "host" or "host:port" (and "[ipv6]:port"); the port lives in
    // the one field so the form stays the three rows the mockup shows. Parsing is
    // HerdrKit's HostEndpoint (Linux-tested); an explicit bad port yields nil, so
    // it is rejected here rather than silently connecting to :22.
    private var endpoint: HostEndpoint? { HostEndpoint.parse(host) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyPEM.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostInvalid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint == nil
    }
    private var canConnect: Bool {
        endpoint != nil && !trimmedUser.isEmpty && !trimmedKey.isEmpty
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    // Centered identity header: the mark, the app name, one line of intent.
                    VStack(spacing: 10) {
                        Text("h")
                            .font(Typography.app(22, .semibold))
                            .foregroundStyle(Palette.text)
                            .frame(width: 56, height: 56)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack(spacing: 4) {
                            Text("herdrup")
                                .font(Typography.app(28, .bold))
                                .foregroundStyle(Palette.text)
                            Text("connect to your machine")
                                .font(Typography.machine(13))
                                .foregroundStyle(Palette.textDim)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                    // The three settings-style rows: label left, value right.
                    VStack(spacing: 10) {
                        fieldRow("Host", text: $host, placeholder: "mac.tail-scale.ts.net")
                        if hostInvalid {
                            Text("check host or host:port")
                                .font(Typography.app(12)).foregroundStyle(Palette.died)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                        }
                        fieldRow("User", text: $username, placeholder: "jerry")
                        keyRow
                    }

                    // Primary action — INK fill. The design carries NO accent colour; the
                    // one near-white fill in the whole app marks the control that ACTS.
                    Button {
                        guard let ep = endpoint else { return }
                        onConnect(SSHCredentials(
                            host: ep.host, port: ep.port,
                            username: trimmedUser,
                            // Gated on trimmedKey, so send trimmedKey — a trailing
                            // space/CR otherwise enables Connect then throws
                            // InvalidOpenSSHBoundary in Citadel's parser.
                            privateKeyPEM: trimmedKey, remoteSocketPath: ""))
                    } label: {
                        Text("Connect")
                            .font(Typography.app(16, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(canConnect ? Palette.text : Palette.surface)
                            .foregroundStyle(canConnect ? Palette.ground : Palette.textFaint)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canConnect)
                    .padding(.top, 6)

                    // Two faint captions (design copy), centered.
                    VStack(spacing: 10) {
                        Text("over your tailscale network · nothing public")
                            .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                        Text("Seen once. Fails with a reason, never a spinner that gives up quietly.")
                            .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(22)
            }
        }
        .sheet(isPresented: $showingKeySheet) { keySheet }
    }

    /// A row with the label on the left and a right-aligned monospace value.
    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The key row NEVER renders the key itself — only whether one is loaded.
    /// That is both the mockup ("id_ed25519 ✓") and the security rule: the
    /// connect screen is screenshotted onto an open port, so the PEM must not be
    /// on screen. Tapping opens a sheet to paste it.
    private var keyRow: some View {
        Button { showingKeySheet = true } label: {
            HStack {
                Text("Key").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                if keyPEM.isEmpty {
                    Text("Add private key").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                } else {
                    Text("ed25519 key").font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.done)   // green ✓ — the key is loaded (per the .dc.html)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var keySheet: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste your ed25519 private key (PEM). It is held only in memory and sent over the SSH connection — never shown again.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    TextEditor(text: $keyPEM)
                        .font(Typography.machine(13)).foregroundStyle(Palette.text)
                        .scrollContentBackground(.hidden)
                        .padding(10).background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if !keyPEM.isEmpty {
                        Button("Clear key") { keyPEM = "" }
                            .font(Typography.app(14)).foregroundStyle(Palette.died)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Private key")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showingKeySheet = false }.foregroundStyle(Palette.brand)
            } }
        }
    }
}

/// New agent (screen 04): pick a folder, an agent kind, and a task, then spawn a
/// real agent. HIGH-STAKES — "Start" splits a pane, launches the agent, and sends
/// the task (splitPane → startAgent → prompt), which begins spending tokens. The
/// footer says so.
struct NewAgentView: View {
    let client: HerdrClient
    /// Called after the agent is spawned, with the new pane id, the agent's
    /// (normalized) name, and the trimmed task. The caller opens that pane with the
    /// task pre-filled — the task is NOT sent here (see `start()`).
    let onStarted: (_ paneID: String, _ name: String, _ task: String) -> Void
    let onCancel: () -> Void

    @State private var folder: String
    @State private var kind: String
    @State private var task: String
    @State private var starting = false
    @State private var errorMessage: String?

    private static let kinds = ["claude", "codex", "gemini"]

    init(client: HerdrClient,
         onStarted: @escaping (_ paneID: String, _ name: String, _ task: String) -> Void = { _, _, _ in },
         onCancel: @escaping () -> Void = {},
         initialFolder: String = "", initialKind: String = "claude", initialTask: String = "") {
        self.client = client
        self.onStarted = onStarted
        self.onCancel = onCancel
        _folder = State(initialValue: initialFolder)
        _kind = State(initialValue: initialKind)
        _task = State(initialValue: initialTask)
    }

    private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A folder must be ABSOLUTE (or blank = follow the focused pane). The phone
    /// cannot expand "~" or a relative path — the remote $HOME is unknown here —
    /// and the server would silently drop a non-directory and spawn in $HOME. So
    /// reject anything non-absolute at the form rather than run in the wrong place.
    private var folderValid: Bool { trimmedFolder.isEmpty || trimmedFolder.hasPrefix("/") }
    private var canStart: Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && folderValid && !starting
    }
    /// The agent's name — the folder's basename, else the kind. herdr validates
    /// the name; a duplicate surfaces as a start error rather than being guessed.
    private var derivedName: String {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty {
            let base = URL(fileURLWithPath: f).lastPathComponent
            if !base.isEmpty && base != "/" { return base }
        }
        return kind
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("WHERE")
                        folderRow
                        sectionLabel("WHO")
                        agentRow
                        sectionLabel("WHAT")
                        taskEditor
                        if let errorMessage {
                            Text(errorMessage).font(Typography.machine(12)).foregroundStyle(Palette.died)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 10)
                        }
                        startButton
                        Text("Starts a real agent and begins spending tokens.")
                            .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.top, 10)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") { onCancel() }.font(Typography.app(15)).foregroundStyle(Palette.brand)
                .disabled(starting)   // no dismiss mid-spawn — the op would keep running off-screen
            Text("New agent").font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Folder").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                TextField("/root/project", text: $folder)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Typography.machine(15)).foregroundStyle(Palette.text)
            }
            .rowShell()
            if !folderValid {
                Text("use an absolute path (starts with /), or leave blank to use the current folder")
                    .font(Typography.app(12)).foregroundStyle(Palette.died).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private var agentRow: some View {
        HStack {
            Text("Agent").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            Spacer()
            Menu {
                ForEach(Self.kinds, id: \.self) { k in Button(k) { kind = k } }
            } label: {
                HStack(spacing: 6) {
                    Text(kind).font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textFaint)
                }
            }
        }
        .rowShell()
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var taskEditor: some View {
        TextEditor(text: $task)
            .font(Typography.app(15)).foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 90)
            .padding(8)
            .background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))   // filled card, per the mockup
            .overlay(alignment: .topLeading) {
                if task.isEmpty {
                    Text("What should it do?").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                        .padding(.horizontal, 13).padding(.top, 16).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
    }

    private var startButton: some View {
        Button { start() } label: {
            HStack(spacing: 8) {
                if starting { ProgressView().tint(.white) }
                Text(starting ? "Starting…" : "Start")
                    .font(Typography.app(16, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(canStart ? Palette.brand : Palette.surface)
            .foregroundStyle(canStart ? .white : Palette.textFaint)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canStart)
        .padding(.horizontal, 16).padding(.top, 16)
    }

    /// The spawn: split a pane in the folder, then start the agent. It does NOT
    /// send the task here. `agent.start` only initiates launch; `agent.prompt`
    /// refuses (agent_not_ready) for a variable, sometimes-long window until the
    /// agent registers as a promptable known agent with a composer, and there is no
    /// reliable client-pollable readiness flag to wait on (interactive_ready is not
    /// populated on this path). So rather than auto-deliver into a not-ready agent
    /// (or spin on a poll that never flips), we hand the pane + task back to the
    /// caller, which opens the agent's terminal with the task PRE-FILLED. The
    /// terminal's input router sends it as a proper prompt the moment the pane
    /// reports a composer (InputMode.intent) — one deliberate tap, no lost task.
    ///
    /// Failure is surfaced honestly by WHERE it failed:
    ///   - before the agent starts (split failed) → nothing to clean up.
    ///   - after the split but the start failed → the pane is an orphan with no
    ///     live agent, so close it (safe) and a retry starts clean.
    private func start() {
        guard !starting else { return }   // re-entry invariant, not just Button.disabled
        starting = true
        errorMessage = nil
        let cwd = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskText = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = AgentName.normalize(derivedName)   // to the server grammar BEFORE splitting
        let chosenKind = kind
        Task {
            defer { starting = false }
            var createdPane: String?
            do {
                let paneID = try await client.splitPane(cwd: cwd.isEmpty ? nil : cwd)
                createdPane = paneID
                _ = try await client.startAgent(name: name, kind: chosenKind, paneID: paneID)
                onStarted(paneID, name, taskText)
            } catch let startError {
                if let pane = createdPane {
                    // startAgent failed after the split left an orphan pane; close
                    // it so a retry does not accumulate empty panes. Disclose if the
                    // cleanup ALSO failed — otherwise an invisible agent-less pane
                    // lingers server-side and the next retry looks clean when it is
                    // not.
                    do {
                        try await client.closePane(paneID: pane)
                        errorMessage = "couldn't start the agent: \(startError)"
                    } catch {
                        errorMessage = "couldn't start the agent (\(startError)); also failed to "
                            + "clean up the empty pane (\(error)) — it may need closing manually"
                    }
                } else {
                    errorMessage = "couldn't create the pane: \(startError)"
                }
            }
        }
    }
}

/// Lists the agents on the host; tapping one opens its pane. A failed load is
/// recoverable (retry, or disconnect back to the connect form).
struct TerminalHomeView: View {
    let client: HerdrClient
    var onDisconnect: () -> Void
    var host: String = ""   // shown in the Settings sheet's connection row
    var onReconnect: () -> Void = {}
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
    @State private var activeCover: ActiveCover?

    private enum ActiveCover: Int, Identifiable {
        case settings, newAgent
        var id: Int { rawValue }
    }

    /// A freshly-spawned pane to open with its task pre-filled. Held in
    /// `pendingOpen` while the New-agent cover animates away, then applied in the
    /// cover's onDismiss (→ `openedPane`) so the push happens AFTER the cover is
    /// gone — presenting a navigation push and dismissing a full-screen cover in
    /// the same frame is the historically fragile case.
    private struct PaneToOpen: Identifiable, Hashable {
        let paneID: String
        let name: String
        let task: String
        var id: String { paneID }
    }
    @State private var pendingOpen: PaneToOpen?
    @State private var openedPane: PaneToOpen?
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
            // Programmatic push for a just-spawned agent's pane, opened with its
            // task pre-filled. Popping back reloads the list so the new agent shows.
            .navigationDestination(item: $openedPane) { pane in
                TerminalPaneView(client: client, paneID: pane.paneID, title: pane.name,
                                 agent: nil, initialReply: pane.task)
                    .onDisappear { Task { await load() } }
            }
        }
        // ONE item-based cover, not two stacked isPresented covers (stacked
        // presentation modifiers on a single view are historically fragile).
        // onDismiss applies a queued open AFTER the cover is fully gone.
        .fullScreenCover(item: $activeCover, onDismiss: {
            if let pane = pendingOpen { pendingOpen = nil; openedPane = pane }
        }) { cover in
            switch cover {
            case .settings:
                SettingsView(
                    host: host,
                    connected: error == nil && !loading,
                    // Withhold reconnect during a host-key rejection — reconnecting
                    // then would first-contact-trust the next key (same gate as the
                    // recovery screen's withheld retry).
                    canReconnect: rejectedFingerprint == nil,
                    onReconnect: { activeCover = nil; onReconnect() },
                    onClose: { activeCover = nil })
            case .newAgent:
                NewAgentView(
                    client: client,
                    // Spawn done: queue the new pane, then dismiss the cover; the
                    // cover's onDismiss opens the pane with the task pre-filled.
                    onStarted: { paneID, name, task in
                        pendingOpen = PaneToOpen(paneID: paneID, name: name, task: task)
                        activeCover = nil
                    },
                    onCancel: { activeCover = nil })
            }
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack {
            circleButton("chevron.left") { onDisconnect() }
            Spacer()
            VStack(spacing: 2) {
                Text("Agents").font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                // The line is ALWAYS present (reserved height) so the title does
                // not jump as it appears; its text is the one number or its
                // restful inverse.
                Text(headerSubtitle.text)
                    .font(Typography.machine(12)).foregroundStyle(headerSubtitle.color)
                    .frame(height: 15)
            }
            Spacer()
            circleButton("plus") { activeCover = .newAgent }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    /// The one number leads in amber; when the model reports nothing blocked AND
    /// nothing uninterpretable, the quiet state says so. A space holds the line
    /// while loading/empty so nothing above it moves.
    private var headerSubtitle: (text: String, color: Color) {
        if fullList.needsYouCount > 0 { return ("\(fullList.needsYouCount) need you", Palette.waiting) }
        if fullList.isQuiet && !agents.isEmpty { return ("nothing needs you", Palette.textFaint) }
        return (" ", Palette.textFaint)
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
            Button { activeCover = .settings } label: {
                tabItem("gearshape", "Settings", active: false)
            }
            .buttonStyle(.plain)
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
        // surfaceRaised (#262A45), NOT surface: the tab bar itself is surface, so an
        // active pill on surface would vanish (the design's "active tab" is raised).
        .background(active ? Palette.surfaceRaised : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: list

    private var agentList: some View {
        VStack(spacing: 0) {
            searchField   // pinned above the scroll, as the mockup/Termius have it
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if agents.isEmpty {
                        emptyLine("no agents")
                    } else if visibleSections.isEmpty {
                        // Agents exist but the search matched none — say so, rather
                        // than leave a blank scroll that reads as "no agents".
                        emptyLine("no matches")
                    } else {
                        ForEach(visibleSections, id: \.group) { section in
                            sectionView(section.group, section.rows)
                        }
                    }
                }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity).padding(.top, 44)
    }

    private func sectionView(_ group: AgentGroup, _ rows: [AgentRow]) -> some View {
        // An active search overrides collapse — a match inside IDLE must not stay
        // hidden behind a shut section the user did not open.
        let isCollapsed = search.isEmpty && collapsed.contains(group)
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
                        TerminalPaneView(client: client, paneID: row.info.paneID, title: row.title, agent: row.info)
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
                Text(subtitle(row.info))
                    .font(Typography.machine(12)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            statusBadge(row.group)
        }
        .padding(12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(edgeTint(row.group), lineWidth: 1))
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    /// "folder · activity": folder is the last path component of `cwd`, activity
    /// is the stripped terminal title. Either may be missing; the pane id is the
    /// last resort so a row is never subtitle-less.
    private func subtitle(_ info: AgentInfo) -> String {
        let folder = info.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        switch (folder, info.terminalTitleStripped) {
        case let (f?, a?): return "\(f) · \(a)"
        case let (f?, nil): return f
        case let (nil, a?): return a
        case (nil, nil): return info.paneID
        }
    }

    private func statusBadge(_ group: AgentGroup) -> some View {
        // The status is colour+shape; name it for VoiceOver too.
        badgeContent(group).accessibilityLabel(Text(group.label))
    }

    @ViewBuilder
    private func badgeContent(_ group: AgentGroup) -> some View {
        switch group {
        // Status is SHAPE + colour, never colour alone — desaturate the screen and it
        // still sorts: ! in a circle waits, × in a SQUARE stopped, a turning ring works.
        case .needsYou: badgeCircle("exclamationmark", group.color)
        case .stopped: badgeSquare("xmark", group.color)
        case .unrecognised: badgeCircle("questionmark", group.color)
        // "now" is a non-temporal "active" marker, not an elapsed timer — there is no
        // start timestamp in AgentInfo to count from — beside a turning ring for "live".
        case .working:
            HStack(spacing: 6) {
                Text("now").font(Typography.machine(12)).foregroundStyle(group.color)
                TurningRing(color: group.color)
            }
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

    /// Stopped's badge is a SQUARE (rounded) — a shape distinct from the waiting/
    /// unrecognised circles, so "gone" reads without relying on the red alone.
    private func badgeSquare(_ system: String, _ color: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.55), lineWidth: 1.5))
    }

    /// The 1px edge tint the design gives ONLY the two states you must not miss —
    /// needs-you (amber) and stopped (red); every other card stays edgeless.
    private func edgeTint(_ group: AgentGroup) -> Color {
        switch group {
        case .needsYou, .unrecognised: return Palette.waiting.opacity(0.5)
        case .stopped: return Palette.died.opacity(0.5)
        default: return .clear
        }
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
            // Plain retry ONLY for non-host-key errors. After a host-key
            // rejection a bare reconnect could first-contact-trust whatever key
            // next appears (bypassing the fingerprint the user must verify), so
            // the only routes then are "trust this key" above or disconnect.
            if rejectedFingerprint == nil {
                Button("retry") { Task { await load() } }
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
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

/// One agent's pane: a styled header, the folded monospace output, and the input
/// surface (a control-key row with a Return cap, and a reply box). Input goes
/// through HerdrKit's InputRouter so intent-mode prompts submit while shell/TUI
/// keys pass through literally — the "send intent, not keystrokes" contract, not
/// a raw byte pipe. Answering a blocked agent is by typing the choice + Return;
/// there are deliberately no Approve/Reject buttons (a fixed 1/2 mapping cannot be
/// verified against an agent-specific menu — structured menu actions are a follow-up).
struct TerminalPaneView: View {
    let client: HerdrClient
    let paneID: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var rawText = ""
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var reply: String
    /// The agent this pane hosts (drives identity, status badge, and input mode).
    /// Seeded from the caller's list context, then RE-RESOLVED from agent.list on
    /// every refresh so status + input mode track the LIVE pane instead of freezing
    /// at open time. Nil until the server names an agent for this pane — input
    /// stays rawKeys (the safe reading) until then. This live re-resolution is what
    /// lets a freshly-spawned agent flip rawKeys→intent once its composer appears,
    /// so a pre-filled task sends as a proper prompt.
    @State private var agent: AgentInfo?
    @State private var sending = false
    @State private var actionNote: String?
    /// True when the pane was opened with a pre-filled task (a just-spawned agent).
    /// While true, the manual send is DISABLED and `deliverPrefillIfNeeded` polls
    /// until the agent is promptable, then delivers the task as a prompt. This is
    /// what closes the early-tap hazard: a just-started pane is a booting shell, so
    /// tapping send in rawKeys would type the task literally and a later Return
    /// would EXECUTE it as a shell command — the task must go through agent.prompt,
    /// never send_text.
    @State private var pendingPrefill: Bool
    /// True while `deliverPrefillIfNeeded` is actively polling. The manual Send is
    /// withheld during this window (the auto-loop owns delivery); once it stops
    /// (delivered or timed out) the button re-enables — but ALWAYS routes a pending
    /// pre-fill through the prompt-only path, never rawKeys.
    @State private var autoDelivering = false

    private let router = InputRouter()

    /// `initialReply` pre-fills the reply box — used when opening a freshly-spawned
    /// agent's pane with the new-agent task ready to send. The agent is not
    /// promptable at spawn; the task is delivered automatically (as a prompt) the
    /// moment the pane reports a composer — never typed raw into the still-booting
    /// pane. A non-empty `initialReply` puts the view into the pending-delivery
    /// state.
    init(client: HerdrClient, paneID: String, title: String, agent: AgentInfo? = nil, initialReply: String = "") {
        self.client = client
        self.paneID = paneID
        self.title = title
        _agent = State(initialValue: agent)
        _reply = State(initialValue: initialReply)
        _pendingPrefill = State(initialValue: !initialReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var group: AgentGroup? { agent.map { AgentRow(info: $0).group } }
    /// "kind · folder" for the header, e.g. "claude · herdr-ios".
    private var heading: String {
        let kind = agent?.agent ?? title
        if let cwd = agent?.cwd {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            if !folder.isEmpty && folder != "/" { return "\(kind) · \(folder)" }
        }
        return kind
    }
    // Send is withheld only while the auto-delivery loop is actively polling (it
    // owns delivery then). A pending pre-fill does NOT disable the button once the
    // loop stops — instead the button ROUTES a pre-fill through the prompt-only
    // path (see the replyBar action), so it can never fall to rawKeys send_text.
    private var canSend: Bool { !reply.trimmingCharacters(in: .whitespaces).isEmpty && !sending && !autoDelivering }

    var body: some View {
        ZStack {
            // The terminal is its own ground — one shade under the app (groundMachine
            // #0B0D1C vs ground #13162A). Per the design, the output IS the ground and
            // the chrome floats over it; this is that base shade.
            Palette.groundMachine.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                paneScroll
                if let note = actionNote {
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                }
                controlBar
                replyBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: paneID) {
            await refresh()
            await deliverPrefillIfNeeded()
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                Text(heading).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15)).foregroundStyle(Palette.textDim)
                }
            }
            if let group {
                HStack(spacing: 6) {
                    Circle().fill(group.color).frame(width: 7, height: 7)
                    Text(group.sectionTitle).font(Typography.microLabel).tracking(1).foregroundStyle(group.color)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(group.color.opacity(0.12)).clipShape(Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(Palette.surface)
    }

    // MARK: pane output (fold cache preserved)

    private var paneScroll: some View {
        GeometryReader { geo in
            // Fold from the SETTLED layout width, but cache the result: re-fold
            // ONLY when the width or the text changes, not on every body eval —
            // folding 200 lines each frame cost ~13ms during scroll.
            let columns = columnCount(for: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error {
                        Text(error).font(Typography.machine(12)).foregroundStyle(Palette.died)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(Typography.machine(Self.paneFontSize)).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            // `initial: true` folds once on appear too, so `lines` is never left
            // empty if the text arrives before the first width change.
            .onChange(of: columns, initial: true) { _, newColumns in refold(columns: newColumns) }
            .onChange(of: rawText) { _, _ in refold(columns: columns) }
        }
    }

    // MARK: input

    // No Approve/Reject buttons: a fixed "1"/"2" mapping assumes a two-option
    // menu shape the server never guarantees, and both reviewers found it could
    // submit the OPPOSITE of the label (a menu with a broader grant at 2). Until
    // the option list is delivered as structured data, the reader answers by
    // typing the choice and pressing Return — which is the safe, verifiable path.
    private var controlBar: some View {
        HStack(spacing: 6) {
            keyCap(label: "esc", key: "Escape")
            keyCap(symbol: "chevron.left", key: "Left")
            keyCap(symbol: "chevron.up", key: "Up")
            keyCap(symbol: "chevron.down", key: "Down")
            keyCap(symbol: "chevron.right", key: "Right")
            keyCap(label: "tab", key: "Tab")
            // The submit affordance rawKeys needs — typing never submits, so
            // Return is the deliberate second action. Highlighted, as the mockup
            // shows it.
            keyCap(symbol: "return", key: "Enter", primary: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func keyCap(label: String? = nil, symbol: String? = nil, key: String, primary: Bool = false) -> some View {
        Button { send(.key(key)) } label: {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                else { Text(label ?? key).font(Typography.machine(12)) }
            }
            .foregroundStyle(primary ? .white : Palette.textDim)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(primary ? Palette.brand : Palette.surface).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        // Disabled while a pre-fill is pending too: a stray Return during automatic
        // delivery could race the in-flight agent.prompt (and Return into a booting
        // shell is the execute-unintended hazard we are closing).
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(key))
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            TextField("type a reply…", text: $reply)
                .font(Typography.app(15)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Palette.surface).clipShape(Capsule())
            Button { sendTapped() } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Palette.brand : Palette.surface).clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
    }

    /// Routes a reader action through InputRouter, then executes the plan. A
    /// refusal is shown, never a silent no-op.
    private func send(_ action: InputAction) {
        let mode = agent.map { router.mode(for: $0) } ?? .rawKeys
        let plan = router.plan(action: action, pane: paneID, mode: mode)
        Task {
            sending = true
            defer { sending = false }
            do {
                switch plan {
                case .prompt(let pane, let text): try await client.prompt(pane: pane, text: text)
                case .text(let pane, let text): try await client.sendText(pane: pane, text: text)
                case .keys(let pane, let keys): try await client.sendKeys(pane: pane, keys: keys)
                case .refused(let reason): actionNote = "not sent: \(reason)"; return
                }
                actionNote = nil
                if case .submitText = action { reply = "" }
                // Give the pane a beat to reflect the input, then re-read.
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refresh()
            } catch {
                actionNote = "send failed: \(error)"
            }
        }
    }

    // MARK: data

    /// The pane's monospace size — shared by the renderer and the column math so the
    /// two can't drift. IBM Plex Mono's advance is exactly 0.6 em (measured hmtx 600 /
    /// head 1000 upem), so one glyph is `paneFontSize * 0.6` points.
    static let paneFontSize: CGFloat = 12.5
    static let paneAdvance: CGFloat = paneFontSize * 0.6   // 7.5pt at 12.5 (IBM Plex Mono)

    /// Rough monospace column count for the pane font, less the 14pt horizontal
    /// padding on each side. The advance is DERIVED from the font (0.6 em), not a
    /// literal — the old 7.2 was calibrated for SF Mono, which this build replaced.
    private func columnCount(for width: CGFloat) -> Int {
        max(20, Int((width - 28) / Self.paneAdvance))
    }

    /// Folds `rawText` to `columns` into the cached `lines`. Called only from the
    /// width/text `onChange`, so scrolling does not re-fold.
    private func refold(columns: Int) {
        lines = TerminalWrap.fold(rawText.components(separatedBy: "\n"), width: columns).flatMap { $0.lines }
    }

    private func refresh() async {
        await readPane()
        await reresolveAgent()
    }

    /// Reads the pane's recent output into `rawText`. Isolated so a list hiccup in
    /// `reresolveAgent` cannot blank the text we just read (and so the pre-fill
    /// poll can refresh content without a second agent.list per tick).
    private func readPane() async {
        do {
            let read = try await client.read(pane: paneID, source: .recentUnwrapped, format: .text, lines: 200)
            rawText = read.text
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// Re-resolves this pane's agent so the status badge and input mode track the
    /// live pane — a fresh spawn flips rawKeys→intent HERE once its composer is up.
    /// A failed lookup or an absent pane KEEPS the prior value: never downgrade a
    /// known agent to nil (would drop intent → rawKeys). It ALSO keeps the prior
    /// agent when the live entry is the same agent but has transiently LOST its
    /// composer (a server hiccup / restart) — flipping intent → rawKeys there would
    /// re-expose the raw-send path for a pane that was promptable a tick ago.
    private func reresolveAgent() async {
        guard let live = try? await client.agentList().first(where: { $0.paneID == paneID }) else { return }
        // Hold the prior agent ONLY when the SAME NAMED agent transiently loses its
        // composer (a server hiccup) — flipping intent → rawKeys there would
        // re-expose the raw-send path for a pane promptable a tick ago. Identity is
        // the agent NAME, not the kind: replacing one claude with another claude
        // must ADOPT the new one, not inherit stale composer/status. An unnamed or
        // renamed live entry is a different identity → adopt (fail loud, not sticky).
        let sameNamedAgent = live.name != nil && live.name == agent?.name
        let priorWasIntent = agent.map { router.mode(for: $0) == .intent } ?? false
        let liveLostComposer = sameNamedAgent && router.mode(for: live) != .intent
        if priorWasIntent && liveLostComposer { return }
        agent = live
    }

    /// One prompt-only delivery attempt for a pending pre-fill. The tested
    /// `prefillDelivery` decision governs it: with a pending pre-fill it yields
    /// `.prompt` (deliver) or `.waitForComposer` (do nothing) — NEVER a raw path —
    /// so a pre-filled task can never be typed into a booting shell. Returns whether
    /// it delivered.
    @discardableResult
    private func deliverPrefillOnce() async -> Bool {
        let ready = (try? await client.isPromptable(pane: paneID)) == true
        switch router.prefillDelivery(pendingPrefill: pendingPrefill, isPromptable: ready) {
        case .prompt:
            do {
                try await client.prompt(pane: paneID, text: reply)
                reply = ""
                pendingPrefill = false
                actionNote = nil
                await refresh()
                return true
            } catch {
                return false   // composer present but herdr not ready yet, or transient
            }
        case .waitForComposer, .normalReply:
            return false
        }
    }

    /// Auto-delivers a pre-filled task once the agent becomes promptable. Polls
    /// (refreshing the visible pane each tick so the boot is watchable) and delivers
    /// ONLY via prompt. Bounded polling: after ~120s it stops polling to save
    /// round-trips but KEEPS the task protected (pendingPrefill stays true), so the
    /// re-enabled Send still routes through the prompt-only path — never rawKeys.
    /// Nothing is lost and the shell-execution hazard cannot reappear.
    private func deliverPrefillIfNeeded() async {
        guard pendingPrefill else { return }
        autoDelivering = true
        defer { autoDelivering = false }
        let maxTicks = 80                       // 80 × 1.5s ≈ 120s
        var ticks = 0
        while pendingPrefill && !Task.isCancelled {
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pendingPrefill = false; return }
            if await deliverPrefillOnce() { return }
            actionNote = "starting \(title)…"
            ticks += 1
            if ticks >= maxTicks {
                actionNote = "still starting — tap Send when \(title) is ready"
                return   // stop polling; pendingPrefill stays true → Send is prompt-only
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }     // don't issue a stray read after teardown
            await readPane()                   // keep the booting pane visible
        }
    }

    /// The reply-bar send action. A pending pre-fill is delivered PROMPT-ONLY
    /// (never rawKeys, at any time); a normal reply uses the usual routing.
    private func sendTapped() {
        guard pendingPrefill else { send(.submitText(reply)); return }
        Task {
            sending = true
            defer { sending = false }
            if await deliverPrefillOnce() { return }
            actionNote = "still starting — tap Send when \(title) is ready"
        }
    }
}

/// Settings (screen 05): connection status, notification preferences, and the
/// trouble actions. Preferences persist locally via @AppStorage; wiring them to
/// real push delivery is a follow-up, so they record intent, not delivery.
struct SettingsView: View {
    var host: String
    var connected: Bool = true
    /// Whether "Reconnect now" is safe to offer. FALSE while the connection is in
    /// the host-key-rejection state — a bare reconnect there would first-contact-
    /// trust whatever key appears next, routing around the very gate the recovery
    /// screen enforces. The row is disabled with a reason in that state.
    var canReconnect: Bool = true
    var onReconnect: () -> Void = {}
    var onClose: () -> Void = {}

    @AppStorage("notify.needsInput") private var notifyNeedsInput = true
    @AppStorage("notify.dies") private var notifyDies = true
    @AppStorage("notify.finishes") private var notifyFinishes = false
    @State private var copied = false

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    // Grouped into three subviews so the top-level builder stays
                    // well under SwiftUI's 10-child ViewBuilder ceiling.
                    VStack(alignment: .leading, spacing: 0) {
                        connectionSection
                        notifySection
                        troubleSection
                        versionFooter
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // Header sits on the ground with a bottom hairline (not a filled bar); the
    // one accent the kit uses here is the back affordance.
    private var header: some View {
        HStack(spacing: 12) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.brand)
            }
            Text("Settings").font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("CONNECTION")
            HStack(spacing: 10) {
                Circle().fill(connected ? Palette.done : Palette.died).frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Disconnected")
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).layoutPriority(1)
                Text(host).font(Typography.machine(13)).foregroundStyle(Palette.textFaint)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .rowShell()
            .padding(.horizontal, 16).padding(.top, 10)   // align with the toggle/action rows
        }
    }

    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("NOTIFY ME WHEN")
            toggleRow("An agent needs input", $notifyNeedsInput)
            toggleRow("An agent dies", $notifyDies)
            toggleRow("An agent finishes", $notifyFinishes)
            // Honest about delivery: the toggles persist the choice, but push
            // delivery is not wired yet — do not imply live notifications.
            Text("Delivery is coming soon — these save your preference.")
                .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    private var troubleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TROUBLE")
            actionRow("Reconnect now", enabled: canReconnect,
                      note: "verify the host key first") { onReconnect() }
            actionRow(copied ? "Copied ✓" : "Copy diagnostics") { copyDiagnostics() }
        }
    }

    /// The app names itself here — "herdrup mobile <version> (<build>)" — with the
    /// design's one-line stance. Version + build come from the bundle (MARKETING_VERSION
    /// / CFBundleVersion), so they track the shipped build, not a hardcoded string.
    private var versionFooter: some View {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return VStack(spacing: 4) {
            Text("herdrup mobile \(short) (\(build))")
                .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
            Text("dark only, on purpose")
                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private func toggleRow(_ label: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack {
                Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                // ON and OFF are BOTH the primary tier — differentiated by the
                // word, not colour. Brand violet is reserved for the primary
                // action + active tab, never a toggle state.
                Text(value.wrappedValue ? "ON" : "OFF")
                    .font(Typography.machine(13, .bold)).foregroundStyle(Palette.text)
            }
            .rowShell()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 10)
        .accessibilityValue(Text(value.wrappedValue ? "on" : "off"))
    }

    private func actionRow(_ label: String, enabled: Bool = true, note: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(15)).foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                    if !enabled, let note {
                        Text(note).font(Typography.app(11)).foregroundStyle(Palette.textFaint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .rowShell()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private func copyDiagnostics() {
        // Host + app version only — never anything sensitive (no key, ever).
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        UIPasteboard.general.string = "herdr-ios \(version) — host \(host)"
        copied = true
        // Revert the confirmation so a second copy gives feedback.
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}

/// The kit's row shell: transparent fill, a 1px hairline border, and the tap
/// shape confined to the card (so the outer gutter/gap is not a tap target).
private extension View {
    func rowShell() -> some View {
        self
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
/// DEBUG-only screenshot mode: renders the list/pane views from MockTransport —
/// no connection, no key, so the buildbox can screenshot them SAFELY (the app
/// otherwise launches to the empty ConnectView). Enable by launching with env
/// `HERDR_SCREENSHOT_MOCK=list` (default) or `=pane`, or the `-herdrScreenshotMock`
/// launch argument.
enum ScreenshotMock {
    case list, pane, settings, newAgent

    static var mode: ScreenshotMock? {
        let env = ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"]?.lowercased()
        let arg = ProcessInfo.processInfo.arguments.contains("-herdrScreenshotMock")
        guard env != nil || arg else { return nil }
        switch env {
        case "pane": return .pane
        case "settings": return .settings
        case "newagent": return .newAgent
        default: return .list
        }
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
      {"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"},
      {"pane_id":"w1:p2","name":"vetrina","agent":"codex","agent_status":"blocked","cwd":"/root/vetrina","terminal_title_stripped":"overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"trend-scout","agent":"codex","agent_status":"idle","cwd":"/root/trend-scout","terminal_title_stripped":"exited, code 1"},
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs"},
      {"pane_id":"w3:p1","name":"clientloop","agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold"},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","name":"discovery","agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"}
    ]}}
    """#

    /// The panes herdr still lists, for the mock render. Excludes w2:p1 so that
    /// row lands in STOPPED via liveness (not a status string). MUST stay in sync
    /// with the census the fixture test uses.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2",
    ]

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach jarvis\n\n> Ran 146 tests, 0 failures\n> Edited SessionRecoveryTests.swift  +18 -4\n\nRun `swift test` with -Xswiftc -warnings-as-errors?\n  1. yes\n  2. no, skip it\n>\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#

    /// A decoded blocked agent for the pane screenshot: status "blocked" groups
    /// as NEEDS YOU, so the pane renders its status badge. No composer field, so
    /// input falls to rawKeys — fine for a static shot.
    static let demoPaneAgent: AgentInfo? = try? JSONDecoder().decode(
        AgentInfo.self,
        from: Data(#"{"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"}"#.utf8))
}
#endif
