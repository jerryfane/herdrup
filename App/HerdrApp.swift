import SwiftUI
import HerdrKit

// Phase 4, first real slice: terminal-first. The ProofOfLoop magenta screen did
// its job — the buildbox confirmed this app target builds and links the merged
// pure-Swift transport for iOS (BUILD SUCCEEDED @ 05e601f) — so this is real UI
// on a verified instrument: connect over the Citadel transport, list agents,
// read a pane, render it. Termius-inspired dark. ANSI styling and gestures are
// follow-ups; this renders plain monospace, which is a readable terminal v1.
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

struct RootView: View {
    @State private var client: HerdrClient?

    var body: some View {
        Group {
            if let client {
                TerminalHomeView(client: client)
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

    private var canConnect: Bool {
        !host.isEmpty && !username.isEmpty && !keyPEM.isEmpty
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
                        let credentials = SSHCredentials(
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: UInt16(port) ?? 22,
                            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                            privateKeyPEM: keyPEM,
                            remoteSocketPath: "")
                        onConnect(HerdrClient(transport: CitadelTransport(credentials: credentials)))
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

/// Lists the agents on the host; tapping one opens its pane.
struct TerminalHomeView: View {
    let client: HerdrClient

    @State private var agents: [AgentInfo] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.bg.ignoresSafeArea()
                Group {
                    if let error {
                        Text(error)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding()
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
            }
            .navigationTitle("agents")
            .task { await load() }
        }
    }

    private func load() async {
        do {
            agents = try await client.agentList()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Reads a pane and renders it as folded monospace lines.
struct TerminalPaneView: View {
    let client: HerdrClient
    let paneID: String
    let title: String

    @State private var lines: [String] = []
    @State private var error: String?

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
                .task(id: paneID) { await refresh(columns: columns(for: geo.size.width)) }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button {
                Task { await refresh(columns: 80) }
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(Palette.accent)
            }
        }
    }

    /// Rough monospace column count for the footnote font (~7pt advance).
    private func columns(for width: CGFloat) -> Int {
        max(20, Int((width - 24) / 7.2))
    }

    private func refresh(columns: Int) async {
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
