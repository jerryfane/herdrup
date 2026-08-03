import SwiftUI
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
        .preferredColorScheme(.dark)
    }

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
                        onConnect(credentials)
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
    var onTrustHostKey: (String) -> Bool

    @State private var agents: [AgentInfo] = []
    @State private var error: String?
    @State private var loading = true
    @State private var rejectedFingerprint: String?
    @State private var trustFailed = false

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
                if let fingerprint = rejectedFingerprint {
                    VStack(spacing: 8) {
                        Text("the host key changed. the server now presents:")
                            .font(.caption).foregroundStyle(Palette.dim)
                        Text(fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        Text("trust it ONLY if this exactly matches the key you verified out of band.")
                            .font(.caption).foregroundStyle(Palette.dim)
                            .multilineTextAlignment(.center)
                    }
                    Button("trust this key & reconnect") {
                        trustFailed = !onTrustHostKey(fingerprint)
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
                    if trustFailed {
                        Text("could not save the verified key to the keychain — not reconnecting. try again.")
                            .font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                // Plain retry ONLY for non-host-key errors. After a host-key
                // rejection a bare reconnect could first-contact-trust whatever
                // key next appears (bypassing the fingerprint the user must
                // verify) — so the only routes then are the bound "trust this
                // key" above or disconnect.
                if rejectedFingerprint == nil {
                    Button("retry") { Task { await load() } }
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                }
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
