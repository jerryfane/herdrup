import SwiftUI
import Security
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

/// Termius-inspired dark palette.
enum Palette {
    static let bg = Color(red: 0.043, green: 0.055, blue: 0.078)       // ~#0B0E14
    static let surface = Color(red: 0.086, green: 0.102, blue: 0.137)  // ~#161A23
    static let text = Color(red: 0.90, green: 0.91, blue: 0.93)
    static let dim = Color(red: 0.55, green: 0.58, blue: 0.64)
    static let accent = Color(red: 0.30, green: 0.85, blue: 0.68)      // teal-green
}

/// Cross-launch TOFU: the persistent `HostKeyPolicy` the transport contract
/// assigns to the app (HerdrKit's `PinStore` is in-memory only and cannot be
/// Keychain-backed). Fingerprints are stored in the iOS Keychain keyed by
/// host:port; compare-and-pin is one locked operation, so a changed key is
/// hard-stopped ACROSS launches, not just within a process. Lives in the app
/// target because the Security framework is not available on Linux, where
/// HerdrKit still builds.
final class KeychainHostKeyPolicy: HostKeyPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private let service = "dev.herdr.hostkey.pins"

    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        lock.lock(); defer { lock.unlock() }
        let account = "\(host):\(port)"
        if let existing = pinned(account: account) {
            return existing == presented ? .trust : .reject
        }
        store(account: account, fingerprint: presented)
        return .trust
    }

    private func pinned(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func store(account: String, fingerprint: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

struct RootView: View {
    @State private var client: HerdrClient?

    var body: some View {
        Group {
            if let client {
                TerminalHomeView(client: client, onDisconnect: {
                    Task { await client.close() }
                    self.client = nil
                })
            } else {
                ConnectView { client = $0 }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Collects host/key and constructs the transport. Constructing does not connect —
/// the first request does — so this screen never blocks on the network.
struct ConnectView: View {
    var onConnect: (HerdrClient) -> Void

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
            Palette.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("herdr")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                    Text("connect to a host")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(Palette.dim)

                    field("host", text: $host)
                    field("port", text: $port)
                    if portInvalid {
                        Text("invalid port (1–65535)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    field("user", text: $username)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("private key (ed25519 PEM)")
                            .font(.caption).foregroundStyle(Palette.dim)
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
                        let transport = CitadelTransport(
                            credentials: credentials,
                            hostKeyPolicy: KeychainHostKeyPolicy())   // cross-launch TOFU
                        onConnect(HerdrClient(transport: transport))
                    } label: {
                        Text("connect")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canConnect ? Palette.accent : Palette.surface)
                            .foregroundStyle(canConnect ? Palette.bg : Palette.dim)
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
            Text(label).font(.caption).foregroundStyle(Palette.dim)
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

    @State private var agents: [AgentInfo] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("disconnect") { onDisconnect() }
                        .foregroundStyle(Palette.dim)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 14) {
                Text(error)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("retry") { Task { await load() } }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Palette.accent)
            }
            .padding()
        } else if loading {
            ProgressView().tint(Palette.accent)
        } else if agents.isEmpty {
            Text("no agents")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Palette.dim)
        } else {
            List(agents) { agent in
                NavigationLink {
                    TerminalPaneView(client: client, paneID: agent.paneID, title: agent.displayName)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(agent.isWorking ? Palette.accent : Palette.dim)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Palette.text)
                            Text(agent.paneID)
                                .font(.caption)
                                .foregroundStyle(Palette.dim)
                        }
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            agents = try await client.agentList()
        } catch {
            self.error = "\(error)"
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

    @State private var lines: [String] = []
    @State private var error: String?
    @State private var columns = 80

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            GeometryReader { geo in
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
                .task(id: paneID) {
                    columns = columnCount(for: geo.size.width)
                    await refresh()
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button {
                Task { await refresh() }   // reuses the measured `columns`
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(Palette.accent)
            }
        }
    }

    /// Rough monospace column count for the footnote font (~7pt advance).
    private func columnCount(for width: CGFloat) -> Int {
        max(20, Int((width - 24) / 7.2))
    }

    private func refresh() async {
        do {
            let read = try await client.read(pane: paneID, source: .recentUnwrapped, format: .text, lines: 200)
            let raw = read.text.components(separatedBy: "\n")
            lines = TerminalWrap.fold(raw, width: columns).flatMap { $0.lines }
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}
