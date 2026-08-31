import SwiftUI
import Foundation
import Security
import UIKit    // UIPasteboard (Copy diagnostics)
import Darwin   // inet_pton/inet_ntop for IPv6 canonicalization
import StoreKit // Product / tip jar (Settings' Support section)
import UserNotifications // notification authorization status (Settings notify section)
import HerdrKit

// Phase 4, first real slice: terminal-first, on the merged pure-Swift transport.
// Connect over the Citadel transport, list agents, read a pane, render it.
// Termius-inspired dark. ANSI styling and gestures are follow-ups; plain
// monospace is a readable terminal v1.
@main
struct HerdrApp: App {
    // The app is otherwise pure SwiftUI; the adaptor is only for APNs registration + notification
    // callbacks, which have no SwiftUI equivalent. It bridges to PushCenter; RootView does the rest.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start the tip-jar transaction listener at launch (mirroring PushCenter), so a
        // transaction that completes outside a purchase() call — e.g. an Ask-to-Buy
        // approved later — is finished promptly instead of waiting for Settings to open.
        _ = TipStore.shared
    }

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
    // The APNs token + tapped-notification target live here (in PushCenter), not in the
    // `.id(session)` home view, so they survive a reconnect. RootView owns the client, so it is what
    // (re)sends the token to the server whenever a connection exists.
    @ObservedObject private var push = PushCenter.shared
    /// Per-agent push mutes (the terminal header's ⋯ menu). Observed so a toggle
    /// re-registers the device immediately (like the category prefs below).
    @ObservedObject private var mute = MuteStore.shared
    // The #90 Live Activity's per-activity push token lives here (survives reconnect like the
    // device token); RootView registers it with the server so the widget updates in the background.
    @ObservedObject private var liveActivity = LiveActivityController.shared
    // Mirror the Settings push toggles here so a change WHILE CONNECTED re-registers the new prefs
    // with the server (and can surface the permission prompt if a category was just enabled) —
    // otherwise a toggle would only take effect on the next connect/reconnect. Keys + defaults match
    // SettingsView exactly; @AppStorage observes UserDefaults app-wide, so SettingsView's writes fire
    // the onChange handlers below even though they live on different views.
    @AppStorage("notify.needsInput") private var notifyNeedsInput = true
    @AppStorage("notify.dies") private var notifyDies = true
    @AppStorage("notify.finishes") private var notifyFinishes = false
    @AppStorage("notify.gram") private var notifyGram = true
    /// UI text-size multiplier (the "Text size" setting). Applied to `Typography`
    /// so all app chrome scales; the terminal has its own font control.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    #if DEBUG
    /// One stable driver instance for the whole stress-test process. Recreating it
    /// during a SwiftUI body evaluation would reset its call and gesture counters.
    private static let rosterStressDriver = RosterStressDriver()
    #endif

    var body: some View {
        // Apply the user's text-size multiplier before the tree renders. Do NOT
        // key the content on it (`.id()`) — that would change identity and reset
        // the home tab / terminal panes / scroll on every step. Instead, the
        // views that render chrome observe `@AppStorage("ui.fontScale")` (Settings
        // directly; the home reads it too), so their bodies
        // re-run at the new `Typography.scale` with their @State intact.
        Typography.scale = CGFloat(min(1.4, max(0.9, uiFontScale)))
        return Group {
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
                hostKey: HostKey.canonical(host: credentials.host, port: credentials.port),
                onReconnect: { reconnect() },
                onTrustHostKey: { fingerprint in trustAndReconnect(credentials, fingerprint: fingerprint) }
            )
            .id(session)
            // A device token can arrive AFTER connect (the APNs callback is async + independent of
            // SSH); register it whenever it lands while connected.
            .onChange(of: push.deviceToken) { _, _ in registerPush() }
            // The Live Activity push token also arrives async (after start) and can rotate; register
            // it whenever it lands so the server can push widget updates while the app is closed.
            // initial: true so a token that arrived BEFORE this connected subtree mounted (or a
            // reclaimed activity's existing token) is registered on appear, not silently missed.
            .onChange(of: liveActivity.pushToken, initial: true) { _, _ in registerActivityPush() }
            // A push-category toggle flipped in Settings while connected: re-register the new prefs
            // (and prompt if a category was just enabled), instead of waiting for a reconnect.
            .onChange(of: notifyNeedsInput) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyDies) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyFinishes) { _, _ in pushPrefsChanged() }
            .onChange(of: notifyGram) { _, _ in pushPrefsChanged() }
            // A per-agent mute toggled in the terminal header: re-register the new set
            // so the daemon starts/stops skipping that pane's pushes immediately.
            .onChange(of: mute.mutedPanes) { _, _ in registerPush() }
        } else {
            ConnectView { connect($0) }
        }
    }

    /// Send the APNs token (with the current category prefs) to the server, if we have both a live
    /// client and a token. Idempotent + fire-and-forget — a server without the method just throws.
    private func registerPush(with explicitClient: HerdrClient? = nil) {
        // Prefer the client the caller JUST built (connect/reconnect pass it in) over the @State
        // `client`, which the SwiftUI setter may not have published through yet on the same tick.
        guard let client = explicitClient ?? self.client, let token = push.deviceToken else { return }
        let p = PushCenter.Prefs.current
        let muted = Array(MuteStore.shared.mutedPanes)
        Task { try? await client.registerDevice(token: token, needsInput: p.needsInput, dies: p.dies, finishes: p.finishes, gram: p.gram, mutedPanes: muted) }
    }

    /// Register the current Live Activity push token with the server, if we have both a live client
    /// and a token. Idempotent + best-effort — mirrors registerPush; a server without the method
    /// just throws, and the widget still updates in the foreground.
    private func registerActivityPush(with explicitClient: HerdrClient? = nil) {
        guard let client = explicitClient ?? self.client, let token = liveActivity.pushToken else { return }
        Task { try? await client.registerActivity(token: token) }
    }

    /// A push-category toggle changed while connected: re-register the current prefs with the server so the
    /// change takes effect immediately (registerPush is a no-op until a device token exists), AND request the
    /// permission prompt — so a user who connected with every category OFF (nothing to prompt for then) and
    /// later enables one gets asked NOW, instead of never. requestAuthorizationIfWanted self-guards on
    /// `anyEnabled` and skips under ScreenshotMock, and iOS shows the alert at most once per install (later
    /// calls return the existing status silently), so this is safe + idempotent to call on every toggle.
    private func pushPrefsChanged() {
        registerPush()
        AppDelegate.requestAuthorizationIfWanted()
    }

    #if DEBUG
    /// Renders a screen from MockTransport (no connection, no key) so the buildbox
    /// can screenshot the list/pane views safely.
    @ViewBuilder
    private func mockView(_ mode: ScreenshotMock) -> some View {
        let mockClient = HerdrClient(transport: MockTransport())
        switch mode {
        case .onboarding:
            ConnectView { _ in }
        case .pairingGuidance:
            ZStack {
                Palette.ground.ignoresSafeArea()
                PairingCommandGuidance().padding(24)
            }
        case .list:
            TerminalHomeView(client: mockClient, onDisconnect: {}, onTrustHostKey: { _ in false },
                             livePaneIDs: MockTransport.demoLivePaneIDs)
        case .rosterStress:
            // Many rows move between sections while the UI test continuously scrolls.
            // The short poll interval is DEBUG-only and turns several production poll
            // boundaries into a bounded simulator receipt.
            ZStack(alignment: .topTrailing) {
                TerminalHomeView(
                    client: HerdrClient(transport: MockTransport(rosterDriver: Self.rosterStressDriver)),
                    onDisconnect: {},
                    onTrustHostKey: { _ in false },
                    agentListPollIntervalNanoseconds: 50_000_000,
                    forceEagerAgentRosterStack: true,
                    onAgentListScrollPhaseChange: Self.rosterStressDriver.recordScrolling,
                    onEagerAgentRosterStackAppear: Self.rosterStressDriver.recordEagerStackVisible,
                    onAgentListDisplayedRosterChange: Self.rosterStressDriver.recordRosterPublication
                )
                // Let the UI test establish a real top-of-list precondition before
                // scroll-time refreshes begin. This DEBUG-only transparent control
                // avoids making corrective precondition gestures change the roster.
                Button(action: Self.rosterStressDriver.arm) {
                    Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Arm roster refresh stress")
                .accessibilityIdentifier("roster-stress-arm")
            }
        case .pane:
            NavigationStack {
                TerminalPaneContent(client: mockClient, paneID: "w1:p1", title: "jarvis",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .settings:
            SettingsView(client: mockClient, agents: [], host: "mac.tail-scale.ts.net")
        case .newAgent:
            NewAgentView(client: mockClient,
                         initialFolder: "/root/herdr-ios", initialKind: "codex",
                         initialTask: "Fix the failing schema artifact test and push")
        case .scroll:
            // A REAL SwiftTerm pane (not a stub) fed 200 lines of scrollback, so the
            // HerdrUITests swipe exercises the actual library scroll path — the only
            // test that proves the SwiftTerm 1.15.0 scroll fix on device.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(scrollback: true)),
                                 paneID: "w1:p1", title: "scrolltest",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .ccscroll:
            // A REAL SwiftTerm pane in alt-screen + mouse-mode (Claude Code fullscreen
            // shape). CCScrollDriver stands in for Claude Code: it redraws shifted
            // content when the app SENDS it an SGR wheel event, so the HerdrUITests
            // swipe proves the mouse-mode scroll path end to end.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(ccDriver: CCScrollDriver.shared)),
                                 paneID: "w1:p1", title: "claude",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .backfill:
            // A REAL SwiftTerm pane whose LIVE stream carries only the short one-screen seed,
            // while agent.read (source=recent, ansi) returns ~1000 numbered lines of history —
            // so the scrollback a swipe-up reveals can ONLY have come from the connect-time
            // backfill (the scrollback receipt for open/refresh history).
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(backfill: true)),
                                 paneID: "w1:p1", title: "backfill",
                                 agent: MockTransport.demoPaneAgent)
            }
        case .paging:
            // Three distinctively-named agents in the real keep-mounted container. A swipe
            // fronts the neighbour and the header heading changes (ALFA→BRAVO→ALFA) — the
            // swipe-between-agents receipt. The pane ids are NOT in the mock agent.list, so
            // reresolveAgent leaves the seeded identity in place and the header stays stable.
            PagingTestHarness(client: mockClient)
        case .gram:
            // The Gram page over a mock that answers gram.list with a canned owner
            // view. Empty `agents` keeps the recipient picker to the shared queue;
            // onClose nil hides the close X (there is nothing to dismiss to in the
            // standalone screenshot render). The messages + claim states are the FYI.
            GramView(client: mockClient, agents: [], onClose: nil)
        }
    }
    #endif

    private func connect(_ creds: SSHCredentials) {
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        let newClient = HerdrClient(transport: newTransport)
        credentials = creds
        transport = newTransport
        client = newClient
        // Bring up the session Live Activity (#90) in a "connecting" state; the home
        // view's onChange pushes real agent status the moment the first list arrives.
        // Label it with the saved host's NICKNAME when there is one (falling back to the
        // raw host/IP), so the lock screen reads "My Mac" rather than an address. Match the
        // saved record the SAME way connect-from-saved does (HostEndpoint.parse, above):
        // `saved.host` may be "host:port" while `creds.host`/`creds.port` are already parsed
        // apart, so a raw string compare would miss any host saved with an explicit port.
        let savedLabel = SavedHostsStore.shared.hosts.first { saved in
            guard let ep = HostEndpoint.parse(saved.host) else { return false }
            return ep.host == creds.host && ep.port == creds.port && saved.username == creds.username
        }?.label
        LiveActivityController.shared.start(hostLabel: savedLabel ?? creds.host, state: LiveActivityController.connecting)
        // PRE-WARM: start the SSH handshake + first agent fetch the instant Connect
        // is tapped, so it overlaps the ConnectView→TerminalHomeView transition
        // instead of following it. The transport dedups concurrent connects, so this
        // and the home view's own load() coalesce into ONE session — no double
        // connect. Result is discarded; the view re-fetches (and reuses the warm
        // connection). Best-effort: a failure here surfaces normally in load().
        Task { _ = try? await newClient.agentList() }
        registerPush(with: newClient)   // re-send a cached token to the freshly-connected server
        registerActivityPush(with: newClient)   // and any existing Live Activity token (reclaimed activity)
        // Request the notification permission PROMPT here — push can now actually deliver: the build
        // carries the aps-environment entitlement AND the server runs the 2c APNs sender. This is the
        // call the 2b scaffolding deferred: 2b left it out on purpose (iOS grants alert authorization
        // exactly once per install, and prompting while the stack was dormant — no entitlement, no
        // server RPC — would have burned that one-shot grant on a capability that could not deliver, so
        // a "Don't Allow" tap would permanently opt the user out even after push went live). Now that
        // both exist it is safe: requestAuthorizationIfWanted only prompts when a notify.* category is
        // enabled and no screenshot/UITest mock is active, and a later call just returns the existing
        // status silently. On grant it registers for remote notifications; the token reaches the server
        // via AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken → registerPush.
        AppDelegate.requestAuthorizationIfWanted()
    }

    private func disconnect() {
        // Unregister the Live Activity token, THEN close the transport — in ONE task so the
        // unregister reaches the server over the still-open connection before close tears it down.
        // Independent tasks would race, and close winning would strand the registration
        // server-side. Capture token + client before we drop them below.
        let closing = transport
        let activityToken = liveActivity.pushToken
        let liveClient = client
        Task {
            if let token = activityToken, let liveClient {
                try? await liveClient.unregisterActivity(token: token)
            }
            await closing?.close()
        }
        client = nil
        transport = nil
        credentials = nil
        LiveActivityController.shared.end()   // tear down the #90 Live Activity with the session
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
        let newClient = HerdrClient(transport: newTransport)
        transport = newTransport
        client = newClient
        session += 1
        registerPush(with: newClient)   // the reconnect built a fresh client actor — re-register the token with it
        registerActivityPush(with: newClient)   // re-register the Live Activity token with the fresh client too
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

/// The connect screen: a manager of saved machines. Tap a host to connect (one tap);
/// "Add host" and hold-to-Edit open the HostEditor sheet. Constructing the transport
/// does not connect — the first request does — so this never blocks on the network.
/// Setup facts shown on more than one screen.
///
/// One definition, because the first-run screen and the post-failure guidance must not
/// drift apart — a reader who follows one and then the other has to be given the same
/// command both times.
enum HerdrSetup {
    /// Installs the fork on the machine.
    ///
    /// ONE LINE ON PURPOSE. This was four chained commands that wrapped onto four
    /// lines in the first-run card — a wall of text as the very first thing a new
    /// user is asked to do. The script selects the matching prebuilt fork release,
    /// verifies its SHA-256 checksum, and installs it under `~/.local/bin`, so the
    /// reader does not need a source checkout, Rust, Cargo, or Zig.
    ///
    /// It points at the FORK, not `herdr.dev/install.sh`: upstream's installer
    /// produces a herdr with no `api-bridge`, which this app cannot drive.
    static let installCommand =
        "curl -fsSL https://herdrup.themartian.app/install.sh | sh"
    static let pairCommand = "herdr pair"
    static let openQRCommand = "herdr pair --open"
    static let saveQRCommand = "herdr pair --qr-file ~/Desktop/herdr-pair.svg"

    static let tailscalePrerequisite =
        "Tailscale is connected on this iPhone and your computer."
    static let sshPrerequisite =
        "SSH is enabled on the computer. On Mac, turn on Remote Login."
}

struct ConnectView: View {
    var onConnect: (SSHCredentials) -> Void

    @ObservedObject private var savedHosts = SavedHostsStore.shared
    /// The add/edit sheet target; nil = closed.
    @State private var editorTarget: HostEditorTarget?
    /// The scan-to-connect sheet (#126) — the path that needs no key, no host address and
    /// no knowledge of what a daemon is.
    @State private var showingPairing = false
    /// Which command was just copied, so the card can confirm it. Nil = none.
    @State private var copiedCommand: String?

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    // Saved machines — the list you manage + tap to connect. Empty on
                    // first launch, where the Add button below is the way in.
                    if savedHosts.hosts.isEmpty {
                        emptyState
                    } else {
                        savedHostsSection
                    }
                    // Scanning is the PRIMARY action and manual entry the fallback, not
                    // the other way round. The manual path asks for a host address, a
                    // username and an ed25519 private key — three things a new user does
                    // not have and cannot be expected to produce from this screen.
                    scanButton
                    addHostButton
                    captions
                }
                .padding(22)
                // Cap + center the column on iPad/macOS so the host list doesn't
                // stretch edge to edge; inert on iPhone (narrower than the cap).
                .readableColumn()
            }
        }
        // Add / edit a host. Save & Connect (add) hands credentials up via onConnect.
        .sheet(item: $editorTarget) { target in
            HostEditor(target: target, store: savedHosts) { creds in
                editorTarget = nil
                onConnect(creds)
            }
        }
        .sheet(isPresented: $showingPairing) {
            PairingSheet(store: savedHosts) { nickname in
                // Connect straight into what was just paired: the point of scanning is
                // that nothing else is asked for.
                if let paired = savedHosts.hosts.first(where: { $0.nickname == nickname }) {
                    tapSavedHost(paired)
                }
            }
        }
    }

    private var scanButton: some View {
        Button { showingPairing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 16, weight: .semibold))
                Text("Scan pairing code").font(Typography.app(16, .semibold))
            }
            .foregroundStyle(Palette.ground)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(Palette.text).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Centered identity header: the app logo (the Lamb), the name, one line of intent.
    // The icon carries its own dark ground, so it reads as the app mark.
    private var header: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
    }

    /// The first screen a new user ever sees, and the one that blocked one.
    ///
    /// What it said before: "Add a machine to connect over your Tailscale network." That
    /// assumed the reader already knew herdr runs on a computer, that a daemon has to be
    /// installed there, and what Tailscale is — the word "herdr" did not appear anywhere
    /// on this screen, and the page that DOES explain it was unreachable until after a
    /// successful SSH login, i.e. visible only to people who had already solved it.
    ///
    /// So it now says what the app is, and gives the one command that starts everything.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("herdrup controls coding agents running on your computer.")
                .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 7) {
                Text("BEFORE PAIRING")
                    .font(Typography.microLabel).tracking(1.1)
                    .foregroundStyle(Palette.textFaint)
                prerequisiteRow(
                    HerdrSetup.tailscalePrerequisite,
                    systemImage: "network",
                    identifier: "pairing-prerequisite-tailscale")
                prerequisiteRow(
                    HerdrSetup.sshPrerequisite,
                    systemImage: "lock.open",
                    identifier: "pairing-prerequisite-ssh")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            Text("Then, on your computer, run:")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                monoCard(HerdrSetup.installCommand)
                Text("then").font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                monoCard(HerdrSetup.pairCommand)
            }

            Text("Scan the code it prints and you're connected. No keys to copy.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private func prerequisiteRow(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textFaint)
                .frame(width: 15)
            Text(text)
                .font(Typography.app(12.5))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// A command the reader is meant to run on their computer — and can now COPY.
    ///
    /// It looked tappable and did nothing, which is worse than looking inert: the
    /// obvious gesture on a command you are being told to run somewhere else is to
    /// copy it, and this screen is a phone showing a command for a laptop, so
    /// copy-then-paste is the whole point.
    ///
    /// Clipboard WRITE only (`UIPasteboard.general.string`), the same pattern as
    /// `CopyForAgentButton` — a programmatic READ is what triggers the system paste
    /// prompt that failed App Review under 2.1a.
    private func monoCard(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            copiedCommand = text
            // Revert the label rather than leaving a permanent "Copied", which would
            // stop telling the truth the moment the clipboard changed.
            #if DEBUG
            // UI-test/screenshot fixtures may spend several seconds synchronizing
            // after the tap before querying the new accessibility label. Keep the
            // receipt visible in mock mode without changing production UX timing.
            let confirmationNanoseconds: UInt64 = ScreenshotMock.mode == nil
                ? 1_600_000_000
                : 10_000_000_000
            #else
            let confirmationNanoseconds: UInt64 = 1_600_000_000
            #endif
            Task {
                try? await Task.sleep(nanoseconds: confirmationNanoseconds)
                if copiedCommand == text { copiedCommand = nil }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(text)
                    .font(Typography.machine(13)).foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Image(systemName: copiedCommand == text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copiedCommand == text ? Palette.done : Palette.textFaint)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copiedCommand == text ? "Copied" : "Copy command: \(text)"))
    }

    private var addHostButton: some View {
        Button { editorTarget = .add } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                Text("Add host").font(Typography.app(15, .semibold))
            }
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // Two faint captions: what the connection is, and where the key lives.
    private var captions: some View {
        VStack(spacing: 8) {
            Text("Connects privately over your Tailscale network. Nothing is exposed to the public internet.")
                .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center)
            Text("Your key or password stays in this device's Keychain, never uploaded.")
                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var savedHostsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SAVED").font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            ForEach(savedHosts.hosts) { saved in savedHostRow(saved) }
        }
    }

    private func savedHostRow(_ saved: SavedHost) -> some View {
        Button { tapSavedHost(saved) } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textDim)
                    .frame(width: 36, height: 36)
                    .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.label).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(secondaryLine(saved)).font(Typography.machine(12)).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Palette.textDim)
            }
            .padding(12)
            .background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        // Hold to manage: Edit opens the editor pre-filled; Remove drops it.
        .contextMenu {
            Button { editorTarget = .edit(saved) } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { savedHosts.delete(saved) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// The secondary line: with a nickname, show `user@host`; without, just the user
    /// (the host is already the row's title, so it isn't repeated).
    private func secondaryLine(_ saved: SavedHost) -> String {
        let hasNickname = (saved.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return hasNickname ? "\(saved.username)@\(saved.host)" : saved.username
    }

    /// One-tap connect from a saved host. If the key is unreadable (deleted / device
    /// locked), open the editor so it can be re-added rather than a silent dead tap.
    private func tapSavedHost(_ saved: SavedHost) {
        guard let ep = HostEndpoint.parse(saved.host) else {
            editorTarget = .edit(saved)
            return
        }
        let creds: SSHCredentials
        switch saved.auth {
        case .key:
            // A missing secret opens the editor rather than a silent dead tap.
            guard let key = savedHosts.key(for: saved)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                editorTarget = .edit(saved)
                return
            }
            creds = SSHCredentials(host: ep.host, port: ep.port, username: saved.username,
                                   privateKeyPEM: key, remoteSocketPath: "")
        case .password:
            // Not trimmed — a password's leading/trailing spaces can be significant.
            guard let password = savedHosts.password(for: saved), !password.isEmpty else {
                editorTarget = .edit(saved)
                return
            }
            creds = SSHCredentials(host: ep.host, port: ep.port, username: saved.username,
                                   password: password, remoteSocketPath: "")
        }
        onConnect(creds)
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
    /// The harnesses actually installed on the connected machine (`agent.kinds`), fetched on appear.
    /// Empty until loaded, or on a daemon too old to report them — then the static fallback is used.
    @State private var installedKinds: [String] = []
    /// The remote folder browser sheet (`fs.list_dir`).
    @State private var showFolderBrowser = false

    /// Static fallback kinds for a daemon that can't report installed harnesses.
    private static let kinds = ["claude", "codex", "gemini"]

    /// The kinds the picker offers: the installed harnesses, or the static list on an older daemon.
    private var menuKinds: [String] { installedKinds.isEmpty ? Self.kinds : installedKinds }

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
        // Under a .sheet a swipe-down is an unguarded exit, but a spawn keeps running
        // off-screen and its queued pane would be stranded (pendingOpenSlot never
        // drains, then fires on an unrelated sheet close). Block interactive dismissal
        // mid-spawn — the same invariant the Cancel button's .disabled(starting) holds.
        .interactiveDismissDisabled(starting)
        // Fetch the machine's installed harnesses so the picker offers only those. `try?` degrades to
        // the static list on an older daemon (no agent.kinds). Keep the selection valid.
        .task {
            let kinds = (try? await client.agentKinds())?.filter { $0.installed }.map(\.kind) ?? []
            if !kinds.isEmpty {
                installedKinds = kinds
                if !kinds.contains(kind) { kind = kinds.first ?? kind }
            }
        }
        // The remote folder browser (fs.list_dir). On pick, fill the folder field.
        .sheet(isPresented: $showFolderBrowser) {
            FolderBrowser(client: client, initialPath: trimmedFolder.isEmpty ? nil : trimmedFolder) { picked in
                folder = picked
            }
        }
    }

    private var header: some View {
        // Title centered (ZStack) with Cancel pinned left — the design centers screen
        // titles. Cancel is a secondary affordance → dim, not the retired violet accent.
        ZStack {
            Text("New agent").font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
            HStack {
                Button("Cancel") { onCancel() }.font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    .disabled(starting)   // no dismiss mid-spawn — the op would keep running off-screen
                Spacer()
            }
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
            HStack(spacing: 8) {
                Text("Folder").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                TextField("/root/project", text: $folder)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Typography.machine(15)).foregroundStyle(Palette.text)
                // Browse the machine's folders instead of typing (fs.list_dir). Manual entry stays.
                Button { showFolderBrowser = true } label: {
                    Image(systemName: "folder").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                .accessibilityLabel("Browse folders")
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
                ForEach(menuKinds, id: \.self) { k in Button(k) { kind = k } }
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
            .background(canStart ? Palette.text : Palette.surface)
            .foregroundStyle(canStart ? Palette.ground : Palette.textFaint)
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
                            + "clean up the empty pane (\(error)). It may need closing manually"
                    }
                } else {
                    errorMessage = "couldn't create the pane: \(startError)"
                }
            }
        }
    }
}

/// A remote folder browser over `fs.list_dir`, for choosing an agent's working directory. Lists the
/// current directory's SUBFOLDERS (files are hidden — a cwd is a folder), tap to descend, ".." to go
/// up, "Use this folder" to pick the resolved path. Degrades with a clear message on a daemon that
/// lacks the method — the caller's manual path field stays available.
struct FolderBrowser: View {
    let client: HerdrClient
    let initialPath: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var dirs: [String] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    Text(path.isEmpty ? "…" : path)
                        .font(Typography.machine(13)).foregroundStyle(Palette.textDim)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider().overlay(Palette.hairlineQuiet)
                    content
                    Button { onPick(path); dismiss() } label: {
                        Text("Use this folder").font(Typography.app(16, .semibold)).foregroundStyle(Palette.ground)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
                    }
                    .disabled(loading || error != nil || path.isEmpty)
                    .opacity((loading || error != nil || path.isEmpty) ? 0.5 : 1)
                    .padding(16)
                }
            }
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
            .task { await load(initialPath) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack { ProgressView().tint(Palette.textDim) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 40)
        } else if let error {
            VStack(spacing: 8) {
                Text(error).font(Typography.app(13)).foregroundStyle(Palette.died).multilineTextAlignment(.center)
                Text("Type a path in the folder field instead.")
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if path != "/" {
                        folderRow(icon: "arrow.up", label: "..") { Task { await load(parent(of: path)) } }
                        divider
                    }
                    ForEach(dirs, id: \.self) { name in
                        folderRow(icon: "folder", label: name) { Task { await load(join(path, name)) } }
                        if name != dirs.last { divider }
                    }
                    if dirs.isEmpty {
                        Text("No subfolders here").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
            }
        }
    }

    private func folderRow(icon: String, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textDim).frame(width: 22)
                Text(label).font(Typography.machine(15)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 16)
    }

    private func load(_ target: String?) async {
        loading = true
        error = nil
        do {
            let listing = try await client.listDir(path: target)
            path = listing.path
            dirs = listing.entries.filter(\.isDir).map(\.name)
        } catch let apiError as APIError {
            // `self.error` — a bare `catch` binds an implicit `error`, so unqualified would shadow.
            self.error = "Couldn't open that folder (\(apiError.code))."
        } catch {
            self.error = "Folder browsing needs the herdr fork updated on this machine."
        }
        loading = false
    }

    /// The parent path, staying absolute (root's parent is root).
    private func parent(of p: String) -> String {
        let trimmed = (p != "/" && p.hasSuffix("/")) ? String(p.dropLast()) : p
        let up = (trimmed as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}

/// Non-observable storage for a roster fetched while the list is scrolling.
/// Mutating this reference deliberately does NOT invalidate SwiftUI. Only promoting
/// its value into `displayedRoster` when scrolling becomes idle redraws the list.
private final class AgentRosterPendingBuffer {
    var snapshot: AgentRosterSnapshot?
}

/// Non-observable generation storage for overlapping async roster loads. Advancing
/// this gate every poll must not itself invalidate the SwiftUI tree.
private final class AgentRosterLoadGateBuffer {
    private var gate = AgentRosterLoadGate()

    func begin() -> UInt64 { gate.begin() }
    func accepts(_ token: UInt64) -> Bool { gate.accepts(token) }
}

/// Non-observable gesture state. Scroll activity changes on the first frame of a
/// drag, so storing it in `@State` would rebuild every eager Mac row at exactly the
/// wrong time. The recovery task also lives here so arming it is render-free.
private final class AgentRosterScrollBuffer {
    var isScrolling = false
    var recoveryTask: Task<Void, Never>?

    deinit { recoveryTask?.cancel() }
}

/// Cross-version scroll-phase observation. The probe sits inside the SwiftUI
/// ScrollView content, finds its UIKit ancestor, and samples UIKit's authoritative
/// tracking/deceleration flags on the display link. This is the same path on iOS 17,
/// iOS 18+, and macOS Designed-for-iPad, so the oldest supported runtime is not left
/// on an unprotected fallback path.
private struct ScrollActivityObserver: UIViewRepresentable {
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onChange: onChange)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.setEnabled(isEnabled)
        context.coordinator.attach(from: uiView)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let onChange: (Bool) -> Void
        private weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var isEnabled: Bool
        private var isActive = false
        private var lastHeartbeatTimestamp: CFTimeInterval = 0
        private var attachmentAttempts = 0

        init(isEnabled: Bool, onChange: @escaping (Bool) -> Void) {
            self.isEnabled = isEnabled
            self.onChange = onChange
        }

        func setEnabled(_ enabled: Bool) {
            guard enabled != isEnabled else { return }
            isEnabled = enabled
            displayLink?.isPaused = !enabled
            if !enabled, isActive {
                isActive = false
                onChange(false)
            }
        }

        func attach(from probe: UIView) {
            guard scrollView == nil else { return }
            var ancestor = probe.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    self.scrollView = scrollView
                    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                    link.isPaused = !isEnabled
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                    return
                }
                ancestor = view.superview
            }
            guard probe.window != nil, attachmentAttempts < 4 else { return }
            attachmentAttempts += 1
            DispatchQueue.main.async { [weak self, weak probe] in
                guard let self, let probe else { return }
                self.attach(from: probe)
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard isEnabled, let scrollView else { return }
            let active = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            if active {
                if !isActive {
                    isActive = true
                    lastHeartbeatTimestamp = link.timestamp
                    onChange(true)
                } else if link.timestamp - lastHeartbeatTimestamp >= 1 {
                    // Rearm the fail-safe without touching SwiftUI state. This also
                    // lets a deliberate long drag exceed the watchdog duration.
                    lastHeartbeatTimestamp = link.timestamp
                    onChange(true)
                }
            } else if isActive {
                isActive = false
                onChange(false)
            }
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            scrollView = nil
            if isActive {
                isActive = false
                onChange(false)
            }
        }
    }

    @MainActor
    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(from: self)
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attach(from: self)
        }
    }
}

/// Lists the agents on the host; tapping one opens its pane. A failed load is
/// recoverable (retry, or disconnect back to the connect form).
struct TerminalHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let client: HerdrClient
    var onDisconnect: () -> Void
    var host: String = ""   // shown in the Settings sheet's connection row
    /// Canonical `host:port` key that scopes saved terminals to THIS connection (a terminal is a pane
    /// on one daemon). Empty only in the DEBUG mock, which has no real terminals.
    var hostKey: String = ""
    var onReconnect: () -> Void = {}
    var onTrustHostKey: (String) -> Bool
    /// The set of panes herdr still lists; anything absent is `stopped`. `nil`
    /// means no census is available yet (the live default) — every agent is
    /// treated as live, the only safe reading. The DEBUG mock passes one so the
    /// stopped section has something to show.
    var livePaneIDs: Set<String>? = nil

    /// How often the connected agent list is re-fetched to stay live. Five seconds is
    /// the production default. The DEBUG scroll-stress harness injects a shorter value
    /// so one UI test crosses many refresh boundaries without becoming a minute-long
    /// wall-clock test.
    var agentListPollIntervalNanoseconds: UInt64 = 5_000_000_000
    /// DEBUG stress receipt: exercise the eager Mac stack on the iOS simulator.
    var forceEagerAgentRosterStack = false
    /// DEBUG stress-receipt hook. Normal callers leave it nil.
    var onAgentListScrollPhaseChange: ((Bool) -> Void)? = nil
    /// DEBUG branch receipt. Normal callers leave it nil.
    var onEagerAgentRosterStackAppear: (() -> Void)? = nil
    /// DEBUG invariant hook. This observes the published `@State` value independently
    /// of the state-machine decision that produced it, so an assignment bypass cannot
    /// make the receipt agree with the code under test.
    var onAgentListDisplayedRosterChange: ((Bool) -> Void)? = nil
    /// Agents, account labels, and the already-sorted list are published as one value.
    /// An unchanged fetch leaves this `@State` untouched. Scroll-time fetches go into
    /// the non-observable buffer above, so even recording a pending result cannot ask
    /// SwiftUI to lay the moving list out again.
    @State private var displayedRoster = AgentRosterSnapshot()
    @State private var pendingRoster = AgentRosterPendingBuffer()
    @State private var rosterLoadGate = AgentRosterLoadGateBuffer()
    @State private var rosterScroll = AgentRosterScrollBuffer()
    /// One shared time source for every status-age badge. It updates at most once
    /// per production poll interval, never once per row.
    @State private var rosterNow = Date()
    private var agents: [AgentInfo] { displayedRoster.agents }
    private var accounts: [CredentialAccount] { displayedRoster.accounts }
    @State private var error: String?
    @State private var loading = true
    @State private var rejectedFingerprint: String?
    @State private var trustFailed = false
    /// Set when the connect failed because herdr is not installed on the host
    /// (`TransportError.herdrNotInstalled`). Drives the install-guidance branch in
    /// `errorView` instead of surfacing the raw stderr. Reset at the start of each load.
    @State private var herdrMissing = false
    /// When `herdrMissing` was triggered because the host's herdr is present but too
    /// old / not the fork (`TransportError.herdrIncompatible`) rather than absent.
    /// Only swaps the guidance heading/subtitle; the fix (install/update the fork) is
    /// the same, so it reuses the same recovery screen.
    @State private var herdrIncompatibleBuild = false
    /// Latches the "Copied ✓" state on the install-command copy button.
    @State private var installCmdCopied = false
    @State private var search = ""
    /// The agent a pending "Restart agent" confirmation is about (nil = no
    /// dialog). Set from the agent card's context menu; a restart interrupts a
    /// busy agent's turn, so it is confirmed before firing.
    @State private var restartCandidate: AgentRow?
    /// A pending "Swap subscription" confirmation: which agent, and the target
    /// account. A swap IS a full restart (kills + --resume) onto a different
    /// credential account, so it interrupts a busy turn exactly like the plain
    /// restart above — and is confirmed before firing for the same reason.
    private struct PendingSwap {
        let row: AgentRow
        let account: CredentialAccount
    }
    @State private var swapCandidate: PendingSwap?
    /// Capability-gated native harness transfer. Unlike a subscription
    /// swap, this stages a translated native session and requires review before
    /// the source runtime is interrupted.
    private struct PendingHarnessTransfer: Identifiable {
        let row: AgentRow
        let source: AgentSessionTransferHarness
        let target: AgentSessionTransferHarness
        var id: String {
            "\(row.info.paneID):\(source.rawValue):\(target.rawValue)"
        }
    }
    @State private var transferCandidate: PendingHarnessTransfer?
    @State private var sessionTransferSupported = false
    @State private var sessionTransferHarnesses: Set<AgentSessionTransferHarness> = []
    @State private var checkedSessionTransferCapability = false
    /// A pending rename (nil = no sheet). An agent sets its daemon `name` (a resolvable mention
    /// target — `herdr agent read <name>`); a terminal sets its pane `label` (shown in
    /// `herdr pane list`) plus the app-local row label. Identifiable so it drives a `.sheet(item:)`.
    private enum RenameTarget: Identifiable {
        case agent(AgentRow)
        case terminal(SavedTerminal)
        var id: String {
            switch self {
            case .agent(let row): return "agent:\(row.info.paneID)"
            case .terminal(let terminal): return "terminal:\(terminal.id.uuidString)"
            }
        }
    }
    @State private var renameTarget: RenameTarget?
    @State private var activeCover: ActiveCover?
    /// The selected bottom tab (Agents / Gram / Settings). Terminal is NOT a tab — it
    /// fronts a keep-mounted pane OVER the tabs (see PaneKeepAliveContainer). Gram and
    /// Settings were modal covers before #88; they are persistent tabs now.
    @State private var selectedTab: HomeTab = .agents
    /// On iPad (regular width) the app becomes a NavigationSplitView (sidebar + detail);
    /// on iPhone / narrow it stays the tab bar + terminal-over layout. Same views either way.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// iPad: which grouped detail the sidebar index has selected (rendered in the split's
    /// detail column). Defaults to Machines so the split opens on a section, not blank.
    @State private var settingsAnchor: SettingsSection? = .machines
    /// iPad: the ⌘/ keyboard-shortcut reference sheet.
    @State private var showShortcuts = false
    /// Terminal font size preference (points), shared app-wide via UserDefaults with the
    /// per-pane ⋯ control; driven here by ⌘+ / ⌘- / ⌘0 (Mac + hardware keyboard).
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5
    /// The UI text-size setting. Read in `body` purely to observe it, so the home
    /// re-renders at the new `Typography.scale` when it changes — WITHOUT the
    /// identity churn `.id()` would cause (which reset the tab / terminal panes).
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0
    /// Unread agent→owner grams, badged on the Gram tab. Session-scoped; written
    /// by GramView while visible and by an ambient poll (below) while it isn't.
    @StateObject private var gramUnread = GramUnreadTracker()
    /// First launch shows the gestures tutorial once; the "Gestures" tab reopens it.
    @AppStorage("hasSeenGesturesHelp") private var hasSeenGesturesHelp = false

    /// DEBUG screenshot/UI-test modes are deterministic fixtures, not first-run
    /// product sessions. Suppress the one-time tutorial for every current and future
    /// mock mode so a clean simulator cannot cover the surface a test is measuring.
    private var shouldShowFirstRunGesturesHelp: Bool {
        #if DEBUG
        ScreenshotMock.mode == nil
        #else
        true
        #endif
    }
    /// Shown once per connect when the daemon lacks the fork features (probe ==
    /// .notFork). Advisory, dismissable — the base daemon still lists/controls agents.
    @State private var showForkNotice = false
    /// Set when the probe returns .notFork WHILE a cover (e.g. the first-run gestures
    /// sheet) is up — draining it from the sheet's onDismiss serializes the notice
    /// with `activeCover`, so the two presentations are never armed at once.
    @State private var pendingForkNotice = false

    /// The bottom tabs. Terminal is deliberately absent — a terminal fronts a
    /// keep-mounted pane over the tabs rather than being one.
    private enum HomeTab: Hashable { case agents, gram, settings, call }

    /// The only remaining MODAL covers: the new-agent form and the first-run gestures
    /// tutorial. Gram and Settings became persistent tabs (#88).
    private enum ActiveCover: Int, Identifiable {
        case newAgent, gestures
        var id: Int { rawValue }
    }

    /// Recently-opened terminals, kept MOUNTED (in `PaneKeepAliveContainer`) so reopening is
    /// instant. Most-recently-used LAST; the pane whose id == `frontID` is the one on screen,
    /// `nil` means the agents list is showing. Bounded to `maxLivePanes` (LRU eviction ⇒ that
    /// slot's view unmounts ⇒ its stream/SSH connection closes). See `open(_:)`.
    @State private var slots: [PaneSlot] = []
    @State private var frontID: String?
    /// Pane ids ever OBSERVED live in `agent.list`. A slot is pruned only once it has been seen
    /// live and then vanishes — so a still-BOOTING spawn pane (absent from agent.list by design
    /// while its composer comes up) is never reaped mid-delivery.
    @State private var everLive: Set<String> = []
    /// A tapped push deep-links to its agent (see PushCenter). Observed here (a singleton, so it
    /// survives this view's `.id(session)` remount); consumed once the list has loaded.
    @ObservedObject private var push = PushCenter.shared
    /// A freshly-spawned pane held while the New-agent cover animates away, then opened in the
    /// cover's onDismiss (fronting a keep-mounted pane, not a nav push, so the historically
    /// fragile "push while dismissing a cover" no longer applies — but the deferral is kept as
    /// cheap safety).
    @State private var pendingOpenSlot: PaneSlot?
    /// The user's opened plain-shell terminals (a singleton, so it survives this view's
    /// `.id(session)` remount). Shell panes never appear in `agent.list`, so the app tracks
    /// them here to relist and reopen. See `SavedTerminalsStore`.
    @ObservedObject private var terminalsStore = SavedTerminalsStore.shared
    /// Re-entry guard while a `New Terminal` split is in flight (also dims the row).
    @State private var creatingTerminal = false
    private static let maxLivePanes = 3
    // Only the quiet tail (idle) starts collapsed — the model forbids a
    // collapsed group from ever hiding something that wants attention.
    @State private var collapsed: Set<AgentGroup> = Set(AgentGroup.allCases.filter { $0.startsCollapsed })
    /// The Terminals section starts collapsed like the idle agents — a compact header row
    /// (TERMINALS · N) the reader expands on demand, so it never competes with the herd.
    @State private var terminalsCollapsed = true
    /// The Archived section (issue #173) starts collapsed too — archived agents are
    /// the least-active thing on screen, so they stay tucked behind an ARCHIVED · N row.
    @State private var archivedCollapsed = true

    /// The whole list derived once when the displayed roster changes. The grouping,
    /// fail-closed placement, stable order, count and quiet flag all live in
    /// HerdrKit's tested `AgentList`, not in SwiftUI's render path.
    private var fullList: AgentList { displayedRoster.agentList }

    /// The ordered LIVE agents a pushed pane can page through with a horizontal swipe.
    /// DELIBERATELY the full sorted live list (`AgentList.rows`, needs-you first), NOT the
    /// search-filtered/collapsed `visibleSections` — paging navigates the whole herd, not
    /// the current search view; a stopped pane is excluded since it has no stream to open.
    /// Snapshotted into the pushed pane at open time.
    private var orderedSiblings: [AgentInfo] { fullList.rows.filter(\.isLive).map(\.info) }

    /// Front a terminal, keeping it (and up to `maxLivePanes-1` others) MOUNTED. Re-opening a
    /// still-mounted pane just LRU-bumps it — instant, its stream never closed. A new pane is
    /// appended (MRU) and the least-recently-used non-front slot is evicted past the cap
    /// (removal unmounts it → `Coordinator.stop()` closes its stream + SSH connection).
    private func open(_ slot: PaneSlot) {
        if let i = slots.firstIndex(where: { $0.paneID == slot.paneID }) {
            // Already mounted → keep it warm (instant), but REFRESH its metadata: a re-open from
            // the list carries a fresh title/agent/roster. Identity is the pane id (`.id`), so
            // replacing the struct does NOT remount the pane or reset its @State. Guard so a spawn
            // re-open (`siblings:[]`, which must not page mid-delivery) can't clobber a good
            // roster, and keep the ORIGINAL one-shot prefill.
            let existing = slots.remove(at: i)
            slots.append(PaneSlot(paneID: existing.paneID, title: slot.title,
                                  agent: slot.agent ?? existing.agent,
                                  initialReply: existing.initialReply,
                                  siblings: slot.siblings.isEmpty ? existing.siblings : slot.siblings))
        } else {
            slots.append(slot)
            while slots.count > Self.maxLivePanes {
                slots.removeFirst()         // LRU is index 0 and never the just-appended new front
            }
        }
        // A fronted pane must overlay the AGENTS tab: that is where the tab-bar hide is
        // declared, so a pane opened from a push deep-link while Gram/Settings is showing
        // would otherwise leave the tab bar drawing over it. Selecting Agents keeps every
        // open path (row tap, deep-link, spawn, swipe-paging) consistent.
        selectedTab = .agents
        frontID = slot.paneID
    }

    /// Open a fresh plain-shell terminal: `pane.split` with NO `agent.start` yields a booting
    /// shell PTY (the same split the new-agent flow does, minus turning it into an agent).
    /// Remember it (so it relists — a shell pane is absent from `agent.list` by construction)
    /// and front it. The terminal drives the shell through the SAME pane-id path as any agent
    /// pane: raw keystrokes + the control bar (see `TerminalPaneContent`, `InputRouter`).
    private func createTerminal() async {
        guard !creatingTerminal else { return }   // re-entry invariant, not just .disabled
        creatingTerminal = true
        defer { creatingTerminal = false }
        do {
            let paneID = try await client.splitPane(cwd: nil)
            let terminal = terminalsStore.add(paneID: paneID, host: hostKey)
            open(PaneSlot(paneID: paneID, title: terminal.label, agent: nil,
                          initialReply: "", siblings: []))
        } catch let e {
            // `\(e)` surfaces the APIError's "code: message" (CustomStringConvertible);
            // `.localizedDescription` bridges to a useless generic NSError string.
            error = "couldn't open a terminal: \(e)"
        }
    }

    /// Close a terminal: end its shell pane server-side (best-effort — it may already have
    /// exited), unmount any live slot, and forget it. Deleting is the user's intent, so a
    /// close that fails (a gone pane) still forgets it rather than stranding a dead row.
    private func deleteTerminal(_ terminal: SavedTerminal) async {
        try? await client.closePane(paneID: terminal.paneID)
        if frontID == terminal.paneID { frontID = nil }
        slots.removeAll { $0.paneID == terminal.paneID }
        terminalsStore.delete(terminal.id, host: hostKey)
    }

    /// Front the pane a tapped push targeted (PushCenter.pendingPaneID), once the agent list has
    /// loaded so the swipe roster + identity resolve. Opens best-effort even if the agent has since
    /// gone (the pane then shows its exited state). Consumes the target so it fires once.
    private func applyDeepLink(afterLoad: Bool = false) {
        guard let paneID = push.pendingPaneID else { return }
        // A refresh completed during momentum scrolling may be buffered rather than
        // displayed. An explicit push should still resolve against that newest data;
        // reading it here does not publish or relayout the roster under the gesture.
        let sourceRoster = afterLoad ? (pendingRoster.snapshot ?? displayedRoster) : displayedRoster
        let info = sourceRoster.agents.first { $0.paneID == paneID }
        // On the onChange path (not post-load), only open once the target RESOLVES against the roster.
        // If it doesn't — an empty roster (first load) OR a stale one (agent spawned from the desktop
        // since the last refresh) — opening now would give a bare paneID title AND a sibling list that
        // doesn't contain it, so swipe-paging would be dead for that slot's whole life. Instead kick a
        // refresh (if one isn't already running) and let the post-load `afterLoad: true` call open it
        // with the fresh identity + roster. The afterLoad call always proceeds — even an unresolved
        // target opens best-effort then (the agent is genuinely gone → its pane shows the exited state).
        if !afterLoad, info == nil {
            if !loading { Task { await load() } }
            return
        }
        push.pendingPaneID = nil
        let siblings = sourceRoster.agentList.rows.filter(\.isLive).map(\.info)
        open(PaneSlot(paneID: paneID, title: info?.displayName ?? paneID, agent: info,
                      initialReply: "", siblings: siblings))
    }

    /// A tapped gram push selects the Gram tab. Like `applyDeepLink`, it is consumed on
    /// the onChange path (app already up) AND post-load (a cold-launch tap set the flag
    /// before this view existed). Leaving it armed lets a later trigger re-invoke it.
    private func openGramIfPending() {
        guard push.pendingGram else { return }
        // The fork notice (a fullScreenCover) is up: don't switch under it; its
        // onDismiss re-invokes this once it's gone.
        if showForkNotice { return }
        // A modal sheet is up, OR a spawned pane is queued to open: DEFER, do not
        // consume. Consuming here would dismiss the sheet out from under the user (e.g.
        // mid new-agent entry) and swallow the tap. Leave the push armed; the sheet's
        // onDismiss re-invokes this once it's gone (and a queued spawn wins there,
        // deliberately leaving the push pending rather than yanking the new terminal).
        if activeCover != nil || pendingOpenSlot != nil { return }
        push.pendingGram = false
        // Drop any fronted terminal so the Gram tab is visible (the pane stays MOUNTED,
        // so reopening it later is instant).
        frontID = nil
        selectedTab = .gram
    }

    /// Swipe-page from the fronted pane to its prev/next sibling (clamped). `open()`s the
    /// neighbour — instant if it is already mounted.
    private func navigate(from slot: PaneSlot, delta: Int) {
        guard let i = slot.siblings.firstIndex(where: { $0.paneID == frontID }),
              slot.siblings.indices.contains(i + delta) else { return }
        let next = slot.siblings[i + delta]
        open(PaneSlot(paneID: next.paneID, title: next.displayName, agent: next,
                      initialReply: "", siblings: slot.siblings))
    }

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

    /// The iPad (regular-width) layout: a two-column `NavigationSplitView`. Sidebar = the section
    /// pill + the agents list; detail = the selected agent's LIVE TERMINAL (or Gram / Settings for
    /// those sections). Reuses the SAME views + terminal machinery as the phone layout — only the
    /// arrangement differs. iPhone / narrow width keeps the tab-bar-with-terminal-over layout.
    private var iPadLayout: some View {
        agentActions(
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    sidebarSectionPicker
                    switch selectedTab {
                    case .agents:
                        header
                        if let error {
                            errorView(error)
                        } else if loading && agents.isEmpty {
                            Spacer(); ProgressView().tint(Palette.textDim); Spacer()
                        } else {
                            agentList
                        }
                    case .settings:
                        settingsIndex   // the section index; each jumps the detail pane
                    default:
                        Spacer()   // Gram / Call live in the detail pane
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 460)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            ZStack {
                Palette.groundMachine.ignoresSafeArea()
                // Base layer: the switch renders Gram / Settings / Call and the agents
                // placeholder. The terminal container is deliberately NOT in here — it is the
                // always-mounted overlay below.
                switch selectedTab {
                case .agents:
                    if frontID == nil {
                        detailPlaceholder("Select an agent", "square.grid.2x2")
                    }
                case .gram:
                    GramView(client: client, agents: agents, unread: gramUnread)
                case .settings:
                    SettingsView(
                        client: client,
                        agents: agents,
                        host: host,
                        connected: error == nil && !loading,
                        canReconnect: rejectedFingerprint == nil,
                        onReconnect: onReconnect,
                        detail: settingsAnchor ?? .machines)
                case .call:
                    detailPlaceholder("Voice call is coming soon", "phone")
                }
                // Keep-mounted terminal container, hoisted ABOVE the `switch` so switching to
                // Settings/Gram never removes it from the view tree. Previously it lived inside
                // `case .agents`, so navigating away unmounted every pane and closed its
                // pane.stream — which is what forced a full reconnect/reload on return. Now it
                // mirrors the phone's sibling overlay (`:1297`): visible + interactive only when
                // an agent pane is fronted, otherwise fully inert, and the panes stay warm.
                PaneKeepAliveContainer(
                    client: client, slots: slots, frontID: frontID,
                    // Hidden behind Settings/Gram (frontID stays set here) → not presented, so
                    // the front pane drops key focus + the PTY lock instead of leaking input.
                    isPresented: selectedTab == .agents,
                    onClose: { frontID = nil; Task { await load() } },
                    onNavigate: { slot, delta in navigate(from: slot, delta: delta) })
                    .opacity(selectedTab == .agents && frontID != nil ? 1 : 0)
                    .allowsHitTesting(selectedTab == .agents && frontID != nil)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Palette.brand)
        // Hardware-keyboard shortcuts (iPad): ⌘K collapses/shows the sidebar, ⌘/ opens the
        // shortcut reference. Hidden zero-size buttons carry the key bindings.
        .background { keyboardShortcuts }
        .sheet(isPresented: $showShortcuts) {
            ShortcutsSheet(onClose: { showShortcuts = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        )
    }

    /// Zero-opacity buttons that exist only to register ⌘K / ⌘/ with the responder chain.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Toggle sidebar") {
                withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Shortcuts") { showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
            // Terminal font zoom (Mac + hardware keyboard). ⌘+ registers from "=" (its
            // unshifted key), ⌘- shrinks, ⌘0 resets — the standard zoom idiom.
            Button("Zoom in") { terminalFontSize = min(terminalFontSize + 1, 24) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom out") { terminalFontSize = max(terminalFontSize - 1, 9) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset zoom") { terminalFontSize = 12.5 }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The iPad Settings sidebar index: one row per grouped destination (Machines /
    /// Accounts / Notifications / App & About), each selecting the detail rendered in the
    /// split's detail column (violet selection highlight as today).
    @ViewBuilder
    private var settingsIndex: some View {
        VStack(spacing: 4) {
            // App & About first (owner request), then the config sections. Explicit order
            // rather than `SettingsSection.allCases` so it's local to the sidebar and the
            // enum's declaration order stays untouched.
            ForEach([SettingsSection.about, .machines, .accounts, .notifications, .appearance], id: \.self) { section in
                Button {
                    settingsAnchor = section
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(settingsAnchor == section ? Palette.brand : Palette.textDim)
                            .frame(width: 22)
                        Text(section.label)
                            .font(Typography.app(15, settingsAnchor == section ? .semibold : .regular))
                            .foregroundStyle(settingsAnchor == section ? Palette.text : Palette.textDim)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(settingsAnchor == section ? Palette.surfaceRaised : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
        Spacer(minLength: 0)
    }

    /// The four top-level sections, a pill at the top of the iPad sidebar (the phone's tab bar,
    /// rotated up here — same sections, so the future Call tab already has its slot).
    private var sidebarSectionPicker: some View {
        HStack(spacing: 4) {
            sectionButton(.agents, "Agents", "square.grid.2x2.fill")
            sectionButton(.gram, "Gram", "bubble.left.and.bubble.right", badge: gramUnread.count)
            sectionButton(.call, "Call", "phone")
            sectionButton(.settings, "Settings", "gearshape")
        }
        .padding(5)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
    }

    private func sectionButton(_ tab: HomeTab, _ label: String, _ icon: String, badge: Int = 0) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Circle().fill(Palette.waiting).frame(width: 7, height: 7).offset(x: 5, y: -2)
                        }
                    }
                Text(label).font(Typography.app(9, .medium))
            }
            .foregroundStyle(selectedTab == tab ? Palette.text : Palette.textFaint)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(selectedTab == tab ? Palette.surfaceRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func detailPlaceholder(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Palette.textFaint)
            Text(text).font(Typography.app(15, .medium)).foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        // Observe the text-size setting so the home re-renders at the new
        // `Typography.scale` on change (identity unchanged → @State preserved).
        let _ = uiFontScale
        return Group {
            if hSizeClass == .regular {
                iPadLayout
            } else {
            ZStack {
            // Apple's standard tab bar (Liquid Glass automatically on iOS 26, the clean
            // standard bar below that) replaces the old hand-built pill (#88). Terminal
            // is NOT a tab — it fronts a keep-mounted pane over everything (below).
            TabView(selection: $selectedTab) {
                agentsTab
                    .tag(HomeTab.agents)
                    .tabItem { Label("Agents", systemImage: "square.grid.2x2.fill") }

                // Gram and Settings were modal covers; they are persistent tabs now.
                // Both are nav-agnostic and take no onClose as tabs (no close button).
                GramView(client: client, agents: agents, unread: gramUnread)
                    .tag(HomeTab.gram)
                    .tabItem { Label("Gram", systemImage: "bubble.left.and.bubble.right") }
                    .badge(gramUnread.count == 0 ? nil : Text("\(gramUnread.count)"))

                SettingsView(
                    client: client,
                    agents: agents,
                    host: host,
                    connected: error == nil && !loading,
                    // Withhold reconnect during a host-key rejection — reconnecting then
                    // would first-contact-trust the next key (same gate as the recovery
                    // screen's withheld retry).
                    canReconnect: rejectedFingerprint == nil,
                    onReconnect: onReconnect)
                    .tag(HomeTab.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Palette.text)
            // Recently-opened terminals kept MOUNTED so reopening + swiping between them is
            // instant (nothing torn down or re-streamed). Overlays the list: a fronted pane
            // covers it and captures touches; otherwise the overlay is fully inert.
            PaneKeepAliveContainer(
                client: client, slots: slots, frontID: frontID,
                // Always presented on iPhone: a fronted pane covers the whole screen and the
                // tab bar hides, so there is no foreground-while-hidden state to guard against.
                isPresented: true,
                onClose: { frontID = nil; Task { await load() } },
                onNavigate: { slot, delta in navigate(from: slot, delta: delta) })
                .opacity(frontID != nil ? 1 : 0)
                // Ease the list<->terminal transition instead of a hard cut: the terminal
                // slides in from the right (and back out on close) while it fades. We animate
                // the `frontID` STATE, not a gesture, so BOTH entry points — the header
                // chevron and the left-edge swipe (EdgeSwipeBack fires a discrete onClose) —
                // get the same motion, and neither EdgeSwipeBack nor the pane's
                // foreground/PTY handoff is touched. Only nil<->non-nil animates; paging
                // between panes (frontID stays non-nil) is unaffected.
                .offset(x: frontID != nil ? 0 : 40)
                .allowsHitTesting(frontID != nil)
                // Key the animation on the BOOLEAN (shown vs not), NOT on frontID itself:
                // frontID also changes when swipe-paging A->B (both non-nil), and
                // `value: frontID` would fire the animation into the subtree then —
                // cross-fading the inner pane swap and disturbing the paging XCUITest.
                // `frontID != nil` only flips on the list<->terminal open/close.
                .animation(.easeOut(duration: 0.26), value: frontID != nil)
            }
            }
        }
        // Connect-scoped lifecycle, attached to the PERSISTENT ROOT, not a tab: a
        // TabView re-runs a tab's .task / .onAppear every time that tab re-appears, so
        // keeping these here fires load / fork-probe / first-run / deep-links ONCE per
        // connect (this view is .id(session)-scoped) rather than on every tab switch —
        // which otherwise re-showed the fork notice and cancelled an in-flight load.
        //
        // Load the agent list on connect, then keep it LIVE with a periodic refresh.
        // Without the poll the list was fetched only once per connect (plus after a
        // local spawn / close), so a server-side change — a new agent, a
        // working → needs-you → exit transition, an agent that died — stayed invisible
        // until the user reconnected to force a fresh load. agent.list is small JSON
        // (cheap, unlike a screen fetch), and load() is stale-while-revalidate: a
        // failed refresh keeps the last-good list rather than blanking it, and the
        // spinner shows only while the list is empty. Still one .task, .id(session)-
        // scoped, so tab switches never restart or duplicate it.
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: agentListPollIntervalNanoseconds)
                await load()
            }
        }
        // Ambient unread-gram poll for the tab badge, running ONLY while the Gram
        // tab is not showing — GramView keeps its own 6s poll while visible and
        // writes the count on load / mark-read. Keyed on selectedTab so it
        // restarts on tab change and idles on Gram: exactly one poller is live.
        .task(id: selectedTab) {
            guard selectedTab != .gram else { return }
            while !Task.isCancelled {
                if let count = try? await client.gramList(unreadOnly: true).count {
                    gramUnread.count = count
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        // Keep the session Live Activity (#90) in step with the herd: push a fresh
        // summary whenever the derived list changes, and once on appear so a
        // freshly-connected session reflects its agents right away. A no-op when the
        // user has Live Activities off — the controller guards that.
        .onChange(of: fullList, initial: true) { _, list in
            LiveActivityController.shared.update(LiveActivityController.state(from: list))
        }
        // If the daemon lacks the fork features, surface the advisory notice. Only a
        // DEFINITIVE not-fork flips it — network/other errors stay quiet (see
        // probeFork). If a cover is already up (e.g. the first-run gestures sheet the
        // onAppear below opens), DEFER — the sheet's onDismiss drains it.
        .task {
            guard await client.probeFork() == .notFork else { return }
            if activeCover == nil { showForkNotice = true } else { pendingForkNotice = true }
        }
        // One-time: fold any pre-per-host (global) terminal list into THIS host on first connect, so
        // the owner keeps their named terminals on their main box. Idempotent — a no-op after the
        // first migration and when there's nothing legacy pending.
        .task(id: hostKey) {
            if !hostKey.isEmpty { terminalsStore.migrateLegacyIfNeeded(host: hostKey) }
        }
        // First launch: show the gestures tutorial once — but NOT over a pending push
        // deep-link (openGramIfPending / applyDeepLink would dismiss it to show Gram or
        // the pane, wasting the one-shot). Burn the seen-flag ONLY when we present.
        .onAppear {
            if shouldShowFirstRunGesturesHelp,
                !hasSeenGesturesHelp,
                activeCover == nil,
                !push.pendingGram,
                push.pendingPaneID == nil
            {
                hasSeenGesturesHelp = true
                activeCover = .gestures
            }
        }
        // A push tapped while already loaded deep-links immediately, regardless of the
        // selected tab (open() selects Agents); the cold-launch / just-loaded case is
        // handled at the end of load().
        .onChange(of: push.pendingPaneID) { _, newValue in if newValue != nil { applyDeepLink() } }
        .onChange(of: push.pendingGram) { _, newValue in if newValue { openGramIfPending() } }
        // ONE item-based sheet, not two stacked isPresented presentations (stacked
        // presentation modifiers on a single view are historically fragile). A SHEET
        // (not a full-screen cover) so it presents bottom-up and swipe-down dismisses
        // it — the header close buttons still work too. onDismiss applies a queued
        // open AFTER the sheet is fully gone.
        .sheet(item: $activeCover, onDismiss: {
            // A just-spawned pane wins the foreground: open it and DON'T let a racing
            // gram push immediately drop it (the push stays pending — its notification
            // is still there — so the new agent's terminal is not yanked away). Else
            // apply any deferred gram tap now that the sheet is fully gone.
            if let slot = pendingOpenSlot {
                pendingOpenSlot = nil
                open(slot)
            } else {
                openGramIfPending()
            }
            // A fork notice deferred behind this sheet fires now — but only if nothing
            // else claimed the foreground, so the fullScreenCover never races the sheet.
            if pendingForkNotice && activeCover == nil {
                pendingForkNotice = false
                showForkNotice = true
            }
        }) { cover in
            Group {
                switch cover {
                case .newAgent:
                    NewAgentView(
                        client: client,
                        // Spawn done: queue the new pane, then dismiss the sheet; the
                        // onDismiss opens the pane with the task pre-filled.
                        onStarted: { paneID, name, task in
                            pendingOpenSlot = PaneSlot(paneID: paneID, title: name, agent: nil,
                                                       initialReply: task, siblings: [])
                            activeCover = nil
                        },
                        onCancel: { activeCover = nil })
                case .gestures:
                    GesturesHelpView(onClose: { activeCover = nil })
                }
            }
            // Full-height bottom-up sheet with a grabber, so swipe-down closes it.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Advisory full-screen notice when the daemon lacks the fork features.
        // Dismissable — it never blocks basic use. onDismiss drains anything that
        // arrived WHILE it was up (a gram push / pane deep-link deferred against it),
        // so those never armed a competing presentation over the cover.
        .fullScreenCover(isPresented: $showForkNotice, onDismiss: {
            openGramIfPending()
            applyDeepLink()
        }) {
            ForkNoticeView(onDismiss: { showForkNotice = false })
        }
    }

    /// The Agents tab: the app-drawn header plus the agents list (or the first-load
    /// spinner / error). It carries the connect lifecycle — load, fork-probe, the
    /// first-run gestures tutorial, and the push deep-link hooks. Terminal is not a
    /// tab; it fronts a keep-mounted pane over the whole TabView.
    /// The per-agent action presenters — the Restart / Swap-subscription confirmation dialogs and the
    /// Rename sheet — applied to BOTH `agentsTab` (iPhone) and `iPadLayout` (iPad/Mac). The shared
    /// `agentList` context menus set `restartCandidate` / `swapCandidate` / `renameTarget`; these
    /// presenters used to live only on the iPhone tab, so on iPad and Mac the menu actions set state
    /// nothing observed and rename/restart/swap were silent no-ops.
    @ViewBuilder
    private func agentActions<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog(
                "Restart agent?",
                isPresented: Binding(
                    get: { restartCandidate != nil },
                    set: { if !$0 { restartCandidate = nil } }
                ),
                presenting: restartCandidate
            ) { row in
                Button("Restart", role: .destructive) {
                    let target = row.info.paneID
                    let title = row.title
                    Task {
                        do {
                            try await client.restartAgent(target: target)
                            await load()
                        } catch let e {
                            error = "couldn't restart \(title): \(e)"
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text(
                    "Interrupts \(row.title)'s current turn. Its session is preserved and reopened with --resume."
                )
            }
            .confirmationDialog(
                "Swap subscription?",
                isPresented: Binding(
                    get: { swapCandidate != nil },
                    set: { if !$0 { swapCandidate = nil } }
                ),
                presenting: swapCandidate
            ) { cand in
                Button("Swap", role: .destructive) {
                    let target = cand.row.info.paneID
                    let title = cand.row.title
                    let accountID = cand.account.id
                    Task {
                        do {
                            try await client.restartAgent(target: target, account: accountID)
                            await load()
                        } catch let e {
                            error = "couldn't swap \(title): \(e)"
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { cand in
                Text(
                    "Switches \(cand.row.title) to \(cand.account.label) and restarts it. This interrupts its current turn. The session is reopened with --resume on the new subscription."
                )
            }
            .sheet(item: $renameTarget) { target in
                renameSheet(for: target)
            }
            .sheet(item: $transferCandidate) { candidate in
                AgentSessionTransferSheet(
                    client: client,
                    agent: candidate.row.info,
                    title: candidate.row.title,
                    source: candidate.source,
                    target: candidate.target,
                    accounts: accounts,
                    onRefresh: { Task { await load() } }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }

    private var agentsTab: some View {
        agentActions(
            NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if let error {
                        errorView(error)
                    } else if loading && agents.isEmpty {
                        // Spinner ONLY on a genuine first load (or after reconnect clears
                        // `agents`). A re-entry with data in hand refreshes silently rather
                        // than blanking the still-valid list to a spinner.
                        Spacer(); ProgressView().tint(Palette.textDim); Spacer()
                    } else {
                        agentList
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Hide the tab bar while a terminal is fronted so the pane is truly
            // full-screen (the pane overlay covers it too; this animates it away and
            // guards against the bar drawing over the overlay on some iOS versions).
            .toolbar(frontID != nil ? .hidden : .automatic, for: .tabBar)
        }
        )
    }

    /// The rename form for an agent or a terminal. Agent names are coerced to the server grammar
    /// (`AgentName.normalize`) and set daemon-side (`agent.rename`) so they resolve as mention
    /// targets; the list refreshes via `load()`. Terminal names are free-form and dual-written —
    /// `pane.rename` (daemon label, visible in `herdr pane list`) plus the app-local row label.
    @ViewBuilder
    private func renameSheet(for target: RenameTarget) -> some View {
        switch target {
        case .agent(let row):
            RenameSheet(
                title: "Rename agent",
                fieldLabel: "AGENT NAME",
                placeholder: "e.g. planner",
                current: row.info.name ?? "",
                footnote: "Lowercase letters, digits, - and _. Another agent can then read this one by name.",
                normalize: AgentName.normalize
            ) { newName in
                let paneID = row.info.paneID
                let title = row.title
                Task {
                    do {
                        try await client.renameAgent(target: paneID, name: newName)
                        await load()
                    } catch let e {
                        error = "couldn't rename \(title): \(e)"
                    }
                }
            }
        case .terminal(let terminal):
            RenameSheet(
                title: "Rename terminal",
                fieldLabel: "TERMINAL NAME",
                placeholder: "e.g. build logs",
                current: terminal.label,
                footnote: "Shows in herdr pane list, so you can tell an agent to check this terminal by name.",
                normalize: { $0 }
            ) { newLabel in
                let paneID = terminal.paneID
                let id = terminal.id
                Task {
                    do {
                        try await client.renamePane(paneID: paneID, label: newLabel)
                        terminalsStore.rename(id, to: newLabel, host: hostKey)
                    } catch let e {
                        error = "couldn't rename terminal: \(e)"
                    }
                }
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
            HStack(spacing: 8) {
                // Open a plain shell terminal — a small icon so agents stay the priority
                // (the re-entry guard in createTerminal absorbs an eager double-tap).
                circleButton("terminal") { Task { await createTerminal() } }
                circleButton("plus") { activeCover = .newAgent }
            }
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

    // MARK: list

    private var agentList: some View {
        VStack(spacing: 0) {
            searchField   // pinned above the scroll, as the mockup/Termius have it
            agentRosterScroll
        }
    }

    /// macOS runs this iOS target through UIKit's Designed-for-iPad compatibility
    /// runtime. Mutating a lazy stack's sections during momentum scrolling could pin
    /// SwiftUI's main thread, so Mac alone uses an eager stack. Native iPhone/iPad keep
    /// lazy rows so large herds do not build every card and status badge off-screen.
    private var agentRosterScroll: some View {
        agentRosterScrollContent
            .onDisappear { setAgentListScrolling(false) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { setAgentListScrolling(false) }
            }
    }

    private var agentRosterScrollContent: some View {
        ScrollView {
            agentRosterStack
                .background {
                    ScrollActivityObserver(
                        isEnabled: agentRosterIsVisible,
                        onChange: setAgentListScrolling
                    )
                }
        }
        .accessibilityIdentifier("agent-roster-scroll")
        // Keep the complete displayed population available to VoiceOver and UI
        // receipts. Unlike counting row Buttons, this includes collapsed sections.
        .accessibilityValue("\(fullList.rows.count) agents")
        .onChange(of: displayedRoster) { _, _ in
            onAgentListDisplayedRosterChange?(rosterScroll.isScrolling)
        }
    }

    /// Compact layouts cover the roster when a terminal is fronted. Regular-width
    /// Mac/iPad layouts keep it visible in the split-view sidebar, unless that column
    /// is explicitly collapsed to detail-only. Bind observation to that actual
    /// presentation instead of treating any selected terminal as list disappearance.
    private var agentRosterIsVisible: Bool {
        guard selectedTab == .agents, scenePhase == .active else { return false }
        if hSizeClass == .regular {
            return columnVisibility != .detailOnly
        }
        return frontID == nil
    }

    @ViewBuilder
    private var agentRosterStack: some View {
        if ProcessInfo.processInfo.isiOSAppOnMac || forceEagerAgentRosterStack {
            VStack(alignment: .leading, spacing: 0) {
                agentRosterRows
            }
            .onAppear { onEagerAgentRosterStackAppear?() }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                agentRosterRows
            }
        }
    }

    @ViewBuilder
    private var agentRosterRows: some View {
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
        // Archived agents sit below the live herd (above terminals) and only
        // when there are some. Hidden during a search (that filters live agents).
        if search.isEmpty && !fullList.archived.isEmpty {
            archivedSection
        }
        // Terminals sit BELOW the herd and only when you have some — agents
        // are the priority. Open one from the header's terminal button.
        // Hidden during an agent search (that filters agents, not shells).
        if search.isEmpty && !terminalsStore.terminals(host: hostKey).isEmpty {
            terminalsSection
        }
    }

    @MainActor
    private func rosterRefreshState() -> AgentRosterRefreshState {
        AgentRosterRefreshState(
            displayed: displayedRoster,
            pending: pendingRoster.snapshot,
            isScrolling: rosterScroll.isScrolling
        )
    }

    @MainActor
    private func armAgentListScrollRecovery() {
        let buffer = rosterScroll
        buffer.recoveryTask?.cancel()
        buffer.recoveryTask = Task { @MainActor [weak buffer] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            guard buffer?.isScrolling == true else { return }
            // A missing framework idle transition must degrade to one delayed roster
            // promotion, never permanent suppression of every future refresh.
            setAgentListScrolling(false)
        }
    }

    @MainActor
    private func setAgentListScrolling(_ scrolling: Bool) {
        if scrolling {
            armAgentListScrollRecovery()
        } else {
            rosterScroll.recoveryTask?.cancel()
            rosterScroll.recoveryTask = nil
        }
        let current = rosterRefreshState()
        let next = current.settingScrolling(scrolling)
        guard next != current else { return }
        pendingRoster.snapshot = next.pending
        if next.displayed != displayedRoster { displayedRoster = next.displayed }
        rosterScroll.isScrolling = next.isScrolling
        if !next.isScrolling {
            rosterNow = Date()
            updateLiveAgentBookkeeping()
        }
        onAgentListScrollPhaseChange?(next.isScrolling)
    }

    /// Publish one internally-consistent roster, or coalesce it into the
    /// non-observable scroll-time buffer. Equality gating inside the pure state
    /// transform means an unchanged response performs no SwiftUI state write.
    @MainActor
    private func receiveRoster(agents: [AgentInfo], accounts: [CredentialAccount]) {
        let snapshot = AgentRosterSnapshot(
            agents: agents,
            accounts: accounts,
            livePaneIDs: livePaneIDs
        )
        let current = rosterRefreshState()
        let next = current.receiving(snapshot)
        pendingRoster.snapshot = next.pending
        if next.displayed != displayedRoster { displayedRoster = next.displayed }
        let now = Date()
        if !rosterScroll.isScrolling,
           now.timeIntervalSince(rosterNow) >= 5 {
            rosterNow = now
        }
    }

    /// Clear a recovered load's error flags without assigning identical `@State`
    /// values on every poll. Those no-op writes still invalidate SwiftUI and can force
    /// the eager Mac roster through layout during a gesture.
    @MainActor
    private func clearSuccessfulLoadState() {
        if error != nil { error = nil }
        if rejectedFingerprint != nil { rejectedFingerprint = nil }
        if trustFailed { trustFailed = false }
        if herdrMissing { herdrMissing = false }
        if herdrIncompatibleBuild { herdrIncompatibleBuild = false }
        if loading { loading = false }
    }

    /// Reconcile pane liveness only against the roster that is actually displayed.
    /// A scroll-time fetch stays entirely in the non-observable pending buffer, so a
    /// newly-added or removed pane cannot invalidate the list before idle promotion.
    @MainActor
    private func updateLiveAgentBookkeeping() {
        guard !rosterScroll.isScrolling else { return }
        let live = Set(displayedRoster.agents.map(\.paneID))
        if !live.isSubset(of: everLive) {
            everLive.formUnion(live)
        }
        let retainedSlots = slots.filter {
            $0.paneID == frontID || !everLive.contains($0.paneID) || live.contains($0.paneID)
        }
        if retainedSlots.count != slots.count {
            slots = retainedSlots
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            .frame(maxWidth: .infinity).padding(.top, 44)
    }

    // MARK: terminals

    /// The Terminals section: the user's opened shell panes (each reopens its live PTY). Shown
    /// below the agents and only when non-empty, so agents stay the priority. Open a new one
    /// from the header's terminal button; long-press a row to close it.
    private var terminalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                terminalsCollapsed.toggle()
            } label: {
                HStack(spacing: 8) {
                    // Count shown when collapsed (so the tally is legible while shut);
                    // expanded, the rows speak for themselves.
                    Text(terminalsCollapsed
                        ? "TERMINALS · \(terminalsStore.terminals(host: hostKey).count)" : "TERMINALS")
                        .font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Image(systemName: terminalsCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 10)

            if !terminalsCollapsed {
                ForEach(terminalsStore.terminals(host: hostKey)) { terminal in
                    Button {
                        open(PaneSlot(paneID: terminal.paneID, title: terminal.label, agent: nil,
                                      initialReply: "", siblings: []))
                    } label: {
                        terminalCard(terminal)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // Rename = set the pane's daemon `label` (shown in `herdr pane list`) so you
                        // can tell an agent to check this terminal by name, + the app-local row label.
                        Button {
                            renameTarget = .terminal(terminal)
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) {
                            Task { await deleteTerminal(terminal) }
                        } label: { Label("Close terminal", systemImage: "xmark.circle") }
                    }
                }
            }
        }
    }

    // MARK: archived

    /// The Archived section (issue #173): agents whose pane was released but whose
    /// session the daemon preserved, so they can be resumed. Collapsed by default and
    /// pinned at the bottom (below agents, above terminals) — an archived agent needs
    /// nothing from you. Structurally mirrors `terminalsSection`. Long-press a row to
    /// Unarchive (resume it into a fresh pane). Archived rows are NOT tappable to a
    /// terminal — there is no live pane to open.
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                archivedCollapsed.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(archivedCollapsed
                        ? "ARCHIVED · \(fullList.archived.count)" : "ARCHIVED")
                        .font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Image(systemName: archivedCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 10)

            if !archivedCollapsed {
                ForEach(fullList.archived) { row in
                    archivedCard(row)
                        .contextMenu {
                            // Unarchive = resume the preserved session into a fresh pane,
                            // restoring the agent's identity. Target by name (or terminal id)
                            // since the pane id no longer resolves once archived.
                            Button {
                                Task {
                                    do {
                                        try await client.unarchiveAgent(target: unarchiveTarget(row.info))
                                        await load()
                                    } catch let e {
                                        error = "couldn't unarchive \(row.title): \(e)"
                                    }
                                }
                            } label: { Label("Unarchive", systemImage: "arrow.uturn.up") }
                        }
                }
            }
        }
    }

    /// The unarchive target: an archived agent's pane id is released, so resolve it by
    /// name, falling back to the terminal id, then pane id.
    private func unarchiveTarget(_ info: AgentInfo) -> String {
        info.name ?? info.terminalID ?? info.paneID
    }

    /// A dimmed agent card for the Archived section: same shape as `card`, an archive
    /// glyph instead of the live status badge, and provenance ("archived by X · reason")
    /// as the subtitle.
    private func archivedCard(_ row: AgentRow) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: row.info.agent))
                    .frame(width: 40, height: 40).opacity(0.5)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(Typography.app(16, .semibold)).foregroundStyle(Palette.textDim)
                Text(archivedSubtitle(row.info))
                    .font(Typography.machine(12)).foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 16).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "archived by X · reason" from the `archived` provenance block; degrades to
    /// "archived" when the daemon didn't record a `by`.
    private func archivedSubtitle(_ info: AgentInfo) -> String {
        let by = (info.archived?.by).map { "archived by \($0)" } ?? "archived"
        if let reason = info.archived?.reason, !reason.isEmpty { return "\(by) · \(reason)" }
        return by
    }

    private func terminalCard(_ terminal: SavedTerminal) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette.surfaceRaised)
                    .frame(width: 40, height: 40)
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.textDim)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.label).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
                Text("shell").font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Reopen a durable transaction from its recorded target even while the row's
    /// detected agent is nil or already changed. Without a transaction, only exact
    /// native harness kinds participate; guessing would offer a transfer the server
    /// must refuse.
    private func sessionTransferSource(for info: AgentInfo) -> AgentSessionTransferHarness? {
        if let activeTransfer = info.sessionTransfer,
           !activeTransfer.phase.isConclusive {
            return activeTransfer.source
        }
        switch info.agent?.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        case "omp": return .omp
        default: return nil
        }
    }

    private func sessionTransferTargets(for info: AgentInfo) -> [AgentSessionTransferHarness] {
        if let activeTransfer = info.sessionTransfer,
           !activeTransfer.phase.isConclusive {
            return [activeTransfer.target]
        }
        guard let source = sessionTransferSource(for: info),
              sessionTransferHarnesses.contains(source) else { return [] }
        return [AgentSessionTransferHarness.claude, .codex, .omp].filter {
            $0 != source && sessionTransferHarnesses.contains($0)
        }
    }

    private func sectionView(_ group: AgentGroup, _ rows: [AgentRow]) -> some View {
        // An active search overrides collapse — a match inside IDLE must not stay
        // hidden behind a shut section the user did not open.
        let isCollapsed = search.isEmpty && collapsed.contains(group)
        // Compute the paging list once per section, not inside the per-row button closure
        // (which SwiftUI evaluates eagerly for every row). `orderedSiblings` now filters
        // the cached roster list and performs no sorting.
        let siblings = orderedSiblings
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
                    Button {
                        open(PaneSlot(paneID: row.info.paneID, title: row.title,
                                      agent: row.info, initialReply: "", siblings: siblings))
                    } label: {
                        card(row)
                    }
                    .buttonStyle(.plain)
                    // Bind UI receipts to the tappable row, not a Text child whose
                    // `isHittable` is false because the parent Button owns the hit.
                    .accessibilityIdentifier("agent-row-\(row.info.paneID)")
                    // VoiceOver should expose the same status section that visually
                    // classifies this agent. The scroll receipt also uses this value
                    // to prove an existing row moved, independently of row count.
                    .accessibilityValue(row.group.label)
                    // Long-press an agent → quick actions. Stop = close the pane
                    // (`pane.close`, the only stop RPC — its inverse is start), then reload;
                    // disclose a failure rather than swallowing it (file convention).
                    .contextMenu {
                        Button(role: .destructive) {
                            Task {
                                do {
                                    try await client.closePane(paneID: row.info.paneID)
                                    await load()
                                } catch let e {
                                    // `\(e)` surfaces the APIError's "code: message"
                                    // (CustomStringConvertible); `.localizedDescription`
                                    // would bridge to a useless generic NSError string.
                                    error = "couldn't stop \(row.title): \(e)"
                                }
                            }
                        } label: { Label("Stop agent", systemImage: "stop.circle") }
                        // Rename = set the agent's daemon `name`, which becomes a resolvable
                        // mention target (another agent can `herdr agent read <name>`).
                        Button {
                            renameTarget = .agent(row)
                        } label: { Label("Rename", systemImage: "pencil") }
                        // Restart = close the agent's session and reopen it with
                        // --resume in place (keeps the pane). It interrupts a busy
                        // agent's turn, so it routes through a confirmation.
                        Button {
                            restartCandidate = row
                        } label: { Label("Restart agent", systemImage: "arrow.clockwise") }
                        // Harness transfer is deliberately not a restart shortcut. It
                        // first builds and verifies a native destination transcript,
                        // then opens a review sheet whose explicit confirm performs the
                        // cutover. Local-only: the server denies filesystem-authority
                        // transfer requests over federation.
                        let transferTargets = sessionTransferTargets(for: row.info)
                        let hasActiveTransfer = row.info.sessionTransfer
                            .map { !$0.phase.isConclusive } ?? false
                        if row.info.machineID == nil,
                           (sessionTransferSupported || hasActiveTransfer),
                           let source = sessionTransferSource(for: row.info),
                           !transferTargets.isEmpty {
                            Menu {
                                ForEach(transferTargets, id: \.rawValue) { target in
                                    Button {
                                        transferCandidate = PendingHarnessTransfer(
                                            row: row,
                                            source: source,
                                            target: target
                                        )
                                    } label: {
                                        Label(target.displayName, systemImage: "arrow.right")
                                    }
                                }
                            } label: {
                                Label(
                                    transferTargets.count == 1
                                        ? "Switch to \(transferTargets[0].displayName)"
                                        : "Switch harness",
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }
                        }
                        // Swap = restart the agent onto a DIFFERENT credential account
                        // of the same kind (an agent runs only on its own kind's
                        // subscriptions). Shown only when the daemon reported at least
                        // one same-kind account. The list still INCLUDES the account the
                        // agent is already on — swapping to it is a legitimate way to
                        // restart — but that one is now marked, because the daemon reports
                        // the current account (`account`) and the menu no longer has to
                        // guess. Picking an account does NOT fire immediately: it stages a
                        // confirmation (swapCandidate), because a swap is a full
                        // turn-interrupting restart, and even swapping to the current
                        // account restarts (interrupts) the agent rather than being a no-op.
                        let swapTargets = accounts.filter { $0.kind == row.info.agent }
                        if !swapTargets.isEmpty {
                            Menu {
                                ForEach(swapTargets) { acct in
                                    Button {
                                        swapCandidate = PendingSwap(row: row, account: acct)
                                    } label: {
                                        Label(
                                            acct.label
                                                + (acct.id == row.info.account ? " (current)" : "")
                                                + (acct.active ? "" : " (exhausted)"),
                                            systemImage: acct.id == row.info.account
                                                ? "person.crop.circle.fill"
                                                : "person.crop.circle"
                                        )
                                    }
                                }
                            } label: { Label("Swap subscription", systemImage: "arrow.left.arrow.right") }
                        }
                        // Archive = release the pane but PRESERVE the session so it can be
                        // resumed later (`agent.archive`, issue #173). Reversible via the
                        // Archived section's Unarchive, so it fires directly (no confirm).
                        // The daemon REJECTS archiving a mid-turn agent unless forced, so a
                        // working agent surfaces that error rather than being torn off a turn.
                        Button {
                            Task {
                                do {
                                    // Attributed on purpose. Without `by`/`reason` the
                                    // daemon records `by: "api"` and no reason — the same
                                    // shape it writes for a pane that merely died, so a
                                    // deliberate archive would be indistinguishable from
                                    // bookkeeping to anything reading the record later.
                                    try await client.archiveAgent(
                                        target: row.info.paneID,
                                        reason: HerdrKit.appArchiveReason,
                                        by: HerdrKit.appArchiveActor)
                                    await load()
                                } catch let e {
                                    error = "couldn't archive \(row.title): \(e)"
                                }
                            }
                        } label: { Label("Archive", systemImage: "archivebox") }
                    }
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
                // Which account this agent is actually on. Shown only when the daemon
                // reports one, so an older server or a default-account agent renders
                // exactly as before rather than gaining an empty line.
                if let account = accountDisplayLabel(
                    accountID: row.info.account,
                    accounts: accounts
                ) {
                    Text(account)
                        .font(Typography.machine(11))
                        .foregroundStyle(row.info.hasUnresolvedAccount ? Palette.died : Palette.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // How long the agent has been in its current state ("5m/2h/3d"), derived
            // from the daemon's status_since (#173). Absent on an older server / before
            // the first transition — then no badge, never a wrong one. `rosterNow`
            // is one shared clock advanced by successful idle polls, rather than a
            // separate TimelineView and timer for every off-screen agent row.
            if let age = compactTimeInState(
                sinceUnixMs: row.info.statusSinceUnixMs,
                nowUnixMs: UInt64(rosterNow.timeIntervalSince1970 * 1000)
            ) {
                Text(age)
                    .font(Typography.machine(11))
                    .foregroundStyle(Palette.textFaint)
                    .monospacedDigit()
            }
            // The recorded account is gone from the registry, so this agent REFUSES to
            // resume rather than come back on the default account and write to the wrong
            // transcript. A person has to re-register the account, so it is a pill with
            // text, not a colour cue: shape and colour, never colour alone.
            if row.info.hasUnresolvedAccount {
                Text("no account")
                    .font(Typography.app(11, .semibold)).foregroundStyle(Palette.died)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.died.opacity(0.12)))
                    .overlay(Capsule().stroke(Palette.died.opacity(0.5), lineWidth: 1))
            }
            // A remote agent whose machine is unreachable has a stale status, so
            // it reads as offline rather than showing a misleading live badge.
            if row.info.isUnreachable {
                offlineBadge()
            } else {
                statusBadge(row.group)
            }
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

    /// A remote agent whose owning machine is unreachable: its live status is a
    /// stale last-known value, so show a muted "offline" mark, never a live badge.
    /// The stopped SQUARE shape (gone, not a live state) but in faint ink, not the
    /// stopped red — offline is quiet, not an alarm.
    private func offlineBadge() -> some View {
        badgeSquare("wifi.slash", Palette.textDim).accessibilityLabel(Text("offline"))
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
            // A connect that failed because herdr is not installed gets its OWN
            // recovery screen (heading + install command + instructions link),
            // not the raw stderr — a brand-new user has no way to read the shell
            // diagnostic and know they need to go install the fork.
            if herdrMissing {
                herdrInstallGuidance
            } else {
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
                        Text("could not save the verified key to the keychain; not reconnecting. try again.")
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
        }
        .padding(24)
        Spacer()
    }

    /// The install one-liner, kept where BOTH screens that show it can reach it.
    ///
    /// It used to be `private static` on this view alone, which is why the first-run
    /// screen could not show it: the only place explaining how to install herdr was
    /// `herdrInstallGuidance`, reachable only AFTER a successful SSH login — visible
    /// solely to people who had already solved the problem it explains.
    private static var herdrInstallCommand: String { HerdrSetup.installCommand }

    /// Shown in place of the raw stderr when the connect failed because herdr is not
    /// installed (`herdrMissing`). Mirrors `ForkNoticeView`'s language and reuses the
    /// Gram setup card's command-box + Copy idiom, plus the shared install link.
    @ViewBuilder private var herdrInstallGuidance: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(Palette.waiting)
        VStack(spacing: 8) {
            Text(herdrIncompatibleBuild ? "herdr here is too old" : "herdr isn't installed here")
                .font(Typography.app(20, .bold)).foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(herdrIncompatibleBuild
                 ? "herdrup runs the herdr daemon on your machine over SSH. The herdr on this host can't run the app bridge. It's too old, or isn't the jerryfane/herdr fork. Update or install the fork, then reconnect."
                 : "herdrup runs the herdr daemon on your machine over SSH. It isn't installed yet. Install the jerryfane/herdr fork, then reconnect.")
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Copy box: run this on the machine, then reconnect.
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this on your machine, then reconnect:")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.herdrInstallCommand)
                .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.groundMachine))
            Button {
                UIPasteboard.general.string = Self.herdrInstallCommand
                installCmdCopied = true
            } label: {
                Text(installCmdCopied ? "Copied ✓" : "Copy command")
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.ground)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.text))
            }
        }
        .padding(.top, 4)
        // Full instructions (every install variant) + retry once it's installed.
        InstallInstructionsLink(label: "Full install instructions")
        Button("retry") { Task { await load() } }
            .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
            .padding(.top, 2)
    }

    @MainActor
    private func load() async {
        // Main-actor isolation prevents simultaneous mutation, not out-of-order
        // completion across awaits. Only the most recently STARTED load may publish.
        let loadToken = rosterLoadGate.begin()
        // Spinner ONLY when there is nothing to show yet (genuine first load, or after a
        // reconnect cleared `agents` via `.id(session)`). A re-entry with a populated list
        // refreshes silently — stale-while-revalidate — instead of blanking to a spinner.
        if agents.isEmpty, !loading { loading = true }
        defer {
            if rosterLoadGate.accepts(loadToken), loading { loading = false }
        }
        do {
            let fetched = try await client.agentList()
            guard rosterLoadGate.accepts(loadToken) else { return }

            // Agent state is the latency-sensitive payload. Publish it immediately
            // with the freshest account roster already in memory; never make visible
            // statuses wait behind the best-effort accounts.list request. A later
            // account response causes a second publication only when account data
            // actually changed, because receiveRoster is equality-gated.
            let latestAccounts = rosterRefreshState().latest.accounts
            receiveRoster(agents: fetched, accounts: latestAccounts)

            clearSuccessfulLoadState()
            // Prune keep-mounted panes whose agent is gone (Stopped / vanished) so no dead
            // terminal lingers warm — but only a slot that was ONCE seen live and has now
            // vanished (never a still-booting spawn pane, which is absent by design while its
            // composer comes up — pruning it would cancel its one-shot prefill delivery). Never
            // prune the FRONT pane, so the reader isn't yanked off an exited terminal.
            updateLiveAgentBookkeeping()
            applyDeepLink(afterLoad: true)   // agents + roster loaded — front any pending push target
            openGramIfPending()              // a cold-launch gram tap opens the Gram page once loaded

            // Refresh account labels independently. A transient failure, or an older
            // daemon without accounts.list, keeps the freshest successful value. The
            // post-await generation check prevents a stalled older load from replacing
            // either the visible or pending snapshot after a newer load completes.
            if let fetchedAccounts = try? await client.accountsList() {
                guard rosterLoadGate.accepts(loadToken) else { return }
                receiveRoster(agents: fetched, accounts: fetchedAccounts)
            } else {
                guard rosterLoadGate.accepts(loadToken) else { return }
            }

            // Ping once per connected HomeView to feature-detect the transactional
            // transfer API. Missing capabilities on an older daemon are a successful
            // negative result; a transport error is retried on the next load.
            if !checkedSessionTransferCapability {
                do {
                    let capabilities = try await client.serverCapabilities()
                    guard rosterLoadGate.accepts(loadToken) else { return }
                    sessionTransferSupported = capabilities?.agentSessionTransfer == true
                    // PARSED HERE, IN THE SAME BLOCK THAT MARKS THE CHECK DONE.
                    //
                    // My first conflict resolution kept BOTH this gated probe and the
                    // one main added, so a transient failure of the first left
                    // `sessionTransferHarnesses` empty while the second set
                    // `checkedSessionTransferCapability` and suppressed any retry — an
                    // OMP-capable daemon would then offer NO transfer target for the
                    // lifetime of this HomeView. Consolidated to one probe, and
                    // populating the set and setting the flag are now inseparable.
                    if sessionTransferSupported {
                        if let advertised = capabilities?.agentSessionTransferHarnesses {
                            sessionTransferHarnesses = Set(advertised.filter { harness in
                                switch harness {
                                case .claude, .codex, .omp:
                                    return true
                                case .unrecognised:
                                    return false
                                }
                            })
                        } else {
                            // Older transfer-capable daemons predate the explicit list
                            // and support exactly Claude Code and Codex.
                            sessionTransferHarnesses = [.claude, .codex]
                        }
                    } else {
                        sessionTransferHarnesses = []
                    }
                    checkedSessionTransferCapability = true
                } catch {
                    guard rosterLoadGate.accepts(loadToken) else { return }
                    // Keep the control hidden and retry on a later refresh. Existing
                    // transfer state still makes the menu visible so a Ready/rollback
                    // transaction can always be reopened.
                }
            }
        } catch {
            // A stale failure must not replace a newer success, clear its deep link,
            // or turn a recovered connection back into an error screen.
            guard rosterLoadGate.accepts(loadToken) else { return }
            let rejected: String?
            var notInstalled = false
            var incompatibleBuild = false
            if let transportError = error as? TransportError {
                if case .hostKeyRejected(_, let fingerprint) = transportError {
                    rejected = fingerprint
                } else {
                    rejected = nil
                    if case .herdrNotInstalled = transportError { notInstalled = true }
                    // herdr is present but can't run the app bridge (too old / not the
                    // fork). Same recovery screen — the remedy is install/update the fork
                    // — with a heading that fits (see `herdrInstallGuidance`).
                    if case .herdrIncompatible = transportError {
                        notInstalled = true
                        incompatibleBuild = true
                    }
                }
            } else {
                rejected = nil
            }
            // A BACKGROUND refresh failure keeps the stale-but-good list rather than blowing it
            // away into the error screen. Surface the error only when there is nothing to show —
            // EXCEPT a host-key rejection, which always surfaces (a mid-session key change must
            // never be hidden behind a cached list).
            if agents.isEmpty || rejected != nil {
                self.error = "\(error)"
                rejectedFingerprint = rejected
                // Only when this is the surfaced error do we drive the install-guidance
                // branch; a no-herdr connect always has an empty list, so it surfaces here.
                herdrMissing = notInstalled
                herdrIncompatibleBuild = incompatibleBuild
            }
            // DROP a pending deep-link this failed load couldn't service, rather than leave it armed:
            // a push targets a just-now event, so firing it after some much-later successful load would
            // yank the reader into a stale pane (an agent that may have finished long ago). If it was
            // already opened by the onChange path, this is nil already. They can reopen from the list.
            push.pendingPaneID = nil
            // Same for a pending gram tap: a message does not go stale like a pane,
            // but popping the Gram cover on some much-later successful load is a
            // surprise; drop it for the same reason and consistency.
            push.pendingGram = false
        }
    }
}

/// One agent's pane: a styled header, the folded monospace output, and the input
/// surface (a control-key row with a Return cap, and a reply box). Input goes
/// through HerdrKit's InputRouter so intent-mode prompts submit while shell/TUI
/// keys pass through literally — the "send intent, not keystrokes" contract, not
/// a raw byte pipe. Answering a blocked agent is by typing the choice + Return;
/// there are deliberately no Approve/Reject buttons (a fixed 1/2 mapping cannot be
/// verified against an agent-specific menu — structured menu actions are a follow-up).
/// A LEFT-EDGE swipe-back for a view whose nav bar is hidden (which disables UIKit's
/// default interactive-pop). The recognizer is attached to a SHARED ANCESTOR (the window),
/// with a delegate that recognizes SIMULTANEOUSLY with everything, so it coexists with the
/// terminal scroll + the buttons rather than carving a touch dead-zone. This view itself
/// never intercepts a touch (`hitTest` → nil). Fires `action` (dismiss) on a committed
/// rightward edge swipe; removes the recognizer on teardown.
struct EdgeSwipeBack: UIViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coord { Coord(action: action) }
    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.action = action }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coord) { coordinator.detach() }

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        private weak var host: UIView?
        private var edge: UIScreenEdgePanGestureRecognizer?
        /// Set once `detach` runs so a still-QUEUED attach retry (attach defers via
        /// DispatchQueue.main.async while the window is nil) no-ops instead of installing a
        /// recognizer onto the window that nothing will ever remove. Without this the pane's
        /// in-place agent swaps — which dismantle+remake this overlay on every swipe — could
        /// leak an orphaned edge recognizer per swap.
        private var detached = false
        init(action: @escaping () -> Void) { self.action = action }
        func attach(from v: UIView) {
            guard !detached, edge == nil else { return }
            guard let window = v.window else {   // not in the hierarchy yet — retry next runloop
                DispatchQueue.main.async { [weak self, weak v] in
                    guard let self, !self.detached, let v else { return }
                    self.attach(from: v)
                }
                return
            }
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(fired(_:)))
            g.edges = .left
            g.delegate = self
            window.addGestureRecognizer(g)
            host = window; edge = g
        }
        func detach() { detached = true; if let g = edge { host?.removeGestureRecognizer(g) }; edge = nil; host = nil }
        @objc func fired(_ gr: UIScreenEdgePanGestureRecognizer) {
            guard gr.state == .ended, let v = gr.view else { return }
            if gr.translation(in: v).x > 40 || gr.velocity(in: v).x > 300 { action() }   // real swipe, not a twitch
        }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    /// Never intercepts touches — the recognizer lives on the window, not this view.
    final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

/// One agent's live terminal + controls. Its identity (pane id, per-pane @State, terminal
/// stream) is fixed for its lifetime — it is hosted MOUNTED by `PaneKeepAliveContainer` and
/// never torn down while its slot exists, so reopening it (and swiping/paging to it) is
/// instant, with scroll position and any typed draft preserved. `onNavigate` reports a
/// horizontal swipe (+1 next / -1 previous) up to the container, which fronts the neighbour;
/// `isForeground` drives the PTY width-lock hand-off when the pane hides/shows.
struct TerminalPaneContent: View {
    let client: HerdrClient
    let paneID: String
    let title: String
    let onNavigate: (Int) -> Void
    /// True while this pane is the one on screen. Drives the PTY-lock release/re-take
    /// (via `LiveTerminalView.isForeground`) and a status refresh on re-show; a
    /// backgrounded keep-mounted pane stays warm but drops the keyboard and stops holding
    /// the width-lock.
    let isForeground: Bool
    /// Back out to the agents list (header chevron / left-edge swipe). Replaces the old
    /// NavigationStack `dismiss` now that panes live in a keep-alive container, not a push.
    let onClose: () -> Void

    @State private var reply: String
    /// The agent this pane hosts (drives identity, status badge, and input mode).
    /// Seeded from the caller's list context, then RE-RESOLVED from agent.list on
    /// every refresh so status + input mode track the LIVE pane instead of freezing
    /// at open time. Nil until the server names an agent for this pane — input
    /// stays rawKeys (the safe reading) until then. This live re-resolution is what
    /// lets a freshly-spawned agent flip rawKeys→intent once its composer appears,
    /// so a pre-filled task sends as a proper prompt.
    @State private var agent: AgentInfo?
    /// Per-agent push mute, toggled from the header's ⋯ menu (keyed by this pane's
    /// public id — the same id the push payload carries).
    @ObservedObject private var mute = MuteStore.shared
    /// Saved prompts, shown from the reply bar when the input is empty (the send arrow would be
    /// dead then). Tapping one inserts it and sends it via the normal path.
    @ObservedObject private var savedPrompts = SavedPromptsStore.shared
    /// Presents the "save a new prompt" sheet.
    @State private var showSavePrompt = false
    @State private var sending = false
    @State private var actionNote: String?
    /// In-flight guard for the [Switch] banner action, so repeated taps don't queue multiple
    /// `/tui default` prompts (the reply box's send is gated by `sending`; this is its analogue).
    @State private var switchingTui = false
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
    /// Bumped by the header refresh button to RECONNECT the pane: changing the id below re-creates
    /// the LiveTerminalView (new Coordinator → a fresh pane.stream over a new connection, re-seeded
    /// from the current server state). Useful when the stream has gone stale or its connection dropped.
    @State private var streamGen = 0
    /// Terminal font size preference (points), app-wide via UserDefaults. Read here to
    /// drive `LiveTerminalView.fontSize` (applied in-place, no view recreation) and
    /// mutated by ⌘± and the ⋯ "Text size" control. Clamped to [9, 24].
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5
    /// App foreground/background phase. On return to `.active` the front pane's
    /// live `pane.stream` has stalled (no network while backgrounded) and
    /// reconnects from the live tail, missing output produced while away — so we
    /// reseed the front pane from durable scrollback (issue #62 follow-up).
    @Environment(\.scenePhase) private var scenePhase
    /// Set when the app actually goes `.background`, so the reseed on the next
    /// `.active` fires only after a real background — not a transient `.inactive`
    /// (Control Center / a notification banner), which would flash needlessly.
    @State private var wasBackgrounded = false
    /// STICKY Ctrl modifier: tapping the `ctrl` cap arms it; the next character
    /// typed in the reply field is then sent as its control byte (and consumed, not
    /// added to the message), and the modifier disarms. See `handleReplyChange`.
    @State private var ctrlArmed = false
    /// True while dictating into the reply: disables the field (so typing can't be
    /// overwritten by the next partial) and suppresses the ctrl-chord interception (so a
    /// single-char dictation partial can't be misread as a control chord).
    @State private var replyDictating = false
    /// Focus of the reply field, so the software keyboard can be DISMISSED — via the
    /// keyboard-toolbar chevron or a tap on the (read-only) terminal.
    @FocusState private var replyFocused: Bool
    /// Terminal-input focus is explicit on touch devices. A terminal tap enables
    /// direct PTY typing; reply submission and keyboard collapse clear it so the
    /// software keyboard can genuinely dismiss instead of immediately moving focus
    /// back to the terminal.
    @State private var terminalInputFocused = false
    /// Incremented to ask the pane to jump to its newest output. LiveTerminalView
    /// performs exactly one jump per increment.
    @State private var jumpToTailToken = 0
    /// False while the pane is scrolled away from its newest output. Drives the
    /// "Latest" pill. Starts true so the pill stays hidden until the reader scrolls.
    @State private var terminalAtTail = true
    /// One-time gate for the "switch Claude Code to smooth (classic) scrolling" banner.
    /// Persisted app-wide via UserDefaults, so once the reader answers it once — Switch
    /// OR dismiss, for ANY Claude Code pane — it never shows again. See `showTuiBanner`.
    @AppStorage("tui.classicPrompted") private var tuiClassicPrompted = false

    private let router = InputRouter()

    /// `initialReply` pre-fills the reply box — used when opening a freshly-spawned
    /// agent's pane with the new-agent task ready to send. The agent is not
    /// promptable at spawn; the task is delivered automatically (as a prompt) the
    /// moment the pane reports a composer — never typed raw into the still-booting
    /// pane. A non-empty `initialReply` puts the view into the pending-delivery
    /// state.
    init(client: HerdrClient, paneID: String, title: String, agent: AgentInfo? = nil,
         initialReply: String = "", isForeground: Bool = true,
         onNavigate: @escaping (Int) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.client = client
        self.paneID = paneID
        self.title = title
        self.isForeground = isForeground
        self.onNavigate = onNavigate
        self.onClose = onClose
        _agent = State(initialValue: agent)
        _reply = State(initialValue: initialReply)
        _pendingPrefill = State(initialValue: !initialReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var group: AgentGroup? { agent.map { AgentRow(info: $0).group } }
    /// The pane header label: the agent's NAME first (matching the list), then the model (kind) and
    /// the cwd folder as context — each appended only when it adds information. E.g.
    /// "herdr-app · claude · herdr-ios"; a name equal to its kind or folder collapses to just the name.
    private var heading: String {
        let name = agent?.displayName ?? title
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }                       // never a leading " · " for an empty name
        if let kind = agent?.agent, !kind.isEmpty, !parts.contains(kind) { parts.append(kind) }
        if let cwd = agent?.cwd {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            // Dedup the folder against BOTH name and kind, and drop the non-folders URL yields for a
            // root/empty cwd ("/" and "." respectively).
            if !folder.isEmpty, folder != "/", folder != ".", !parts.contains(folder) { parts.append(folder) }
        }
        return parts.isEmpty ? title : parts.joined(separator: " · ")   // fall back so the header is never blank
    }
    // Send is withheld only while the auto-delivery loop is actively polling (it
    // owns delivery then). A pending pre-fill does NOT disable the button once the
    // loop stops — instead the button ROUTES a pre-fill through the prompt-only
    // path (see the replyBar action), so it can never fall to rawKeys send_text.
    private var canSend: Bool { !reply.trimmingCharacters(in: .whitespaces).isEmpty && !sending && !replyDictating }

    /// Whether to offer the one-time "switch to smooth (classic) scrolling" banner:
    /// ONLY for Claude Code panes (agent kind contains "claude") and only until the reader
    /// has answered it once (`tuiClassicPrompted`). Deliberately gates on agent KIND + the
    /// one-shot flag, not on probing the alt-screen/mouse state — simpler, and correct
    /// even after the switch since the flag suppresses any re-show. codex/gemini/plain
    /// shells never see it.
    private var showTuiBanner: Bool {
        // Never render during a buildbox screenshot or an XCUITest run. The banner takes its own
        // ~150pt of flow space above the terminal, which would push the scroll receipts' hard-coded
        // dy:0.35 drag origin off the scroll view — their scroll/ccscroll mocks seat a claude-kind
        // pane — reproducing the exact movedDiff~0 dead-scroll failure those receipts exist to catch.
        // ScreenshotMock is #if DEBUG-only and this view builds in ALL configs, so the guard is
        // DEBUG-gated (a bare reference breaks the Release/Distribution archive; release has no mock
        // harness, so nothing to suppress there). Same guard shape AppDelegate uses for push/prompts.
        #if DEBUG
        if ScreenshotMock.mode != nil { return false }
        #endif
        // contains("claude") to stay consistent with DesignSystem's agent-kind colour/glyph mapping,
        // so a claude-family kind is classified uniformly everywhere.
        return (agent?.agent?.contains("claude") ?? false) && !tuiClassicPrompted
    }

    /// The UI text-size setting. Read in `body` only to observe it, so the pane
    /// CHROME (header/keycaps, which use Typography) re-renders at the new
    /// Typography.scale even while kept mounted. Terminal CONTENT is insulated —
    /// it uses its own `terminal.fontSize`, unaffected by this.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    var body: some View {
        // Observe the text-size setting so the pane chrome re-renders at the new scale.
        let _ = uiFontScale
        return ZStack {
            // The terminal is its own ground — one shade under the app (groundMachine
            // #0B0D1C vs ground #13162A). Per the design, the output IS the ground and
            // the chrome floats over it; this is that base shade.
            Palette.groundMachine.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                // A one-time, dismissible offer to move Claude Code off its laggy
                // fullscreen renderer onto the smooth inline "classic" one. Sits BELOW
                // the header and ABOVE the terminal so it takes its own flow space and
                // never covers output or fights the header/edge-back gestures; Claude
                // Code panes only, shown at most once (see showTuiBanner).
                if showTuiBanner { tuiBanner }
                // The live terminal: a real SwiftTerm VT fed by the pane.stream raw
                // byte firehose (#40), full-bleed as the machine ground. A terminal
                // tap enables direct PTY input; the reply bar remains the deliberate
                // prompt path for agent messages.
                LiveTerminalView(client: client, paneID: paneID,
                                 onNavigate: onNavigate, isForeground: isForeground,
                                 wantsTerminalKeyFocus: isForeground && !replyFocused
                                     && (terminalInputFocused || UIDevice.current.userInterfaceIdiom == .pad),
                                 onTerminalFocusRequest: { terminalInputFocused = true },
                                 jumpToTailToken: jumpToTailToken,
                                 onTailStateChange: { terminalAtTail = $0 },
                                 // The host's current belief, so a `streamGen` remount seeds a
                                 // fresh Coordinator instead of replaying the last jump.
                                 isAtTail: terminalAtTail,
                                 fontSize: CGFloat(terminalFontSize),
                                 // A federated/remote pane routes key-drive input via pane.send_text
                                 // (home can't proxy the persistent pane.input.stream channel). (#139)
                                 isFederated: agent?.machineID != nil)
                    // Reconnect on refresh: a new id re-creates the view → fresh stream/connection.
                    .id(streamGen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A small horizontal inset so the grid gets a clean, symmetric
                    // margin instead of the last column hugging the right edge.
                    .padding(.horizontal, 8)
                    // NOTE: do NOT attach a SwiftUI .onTapGesture here. A tap gesture on
                    // this UIViewRepresentable competes with the wrapped UIScrollView's
                    // native pan and starves terminal scroll drags. LiveTerminalView's
                    // UIKit recognizer owns the explicit direct-input tap instead.
                    // A visible, one-finger replacement for the double tap that used to
                    // jump to the tail (given back to SwiftTerm, which needs it for word
                    // select). An OVERLAY, not a gesture, for the reason stated above:
                    // only the pill itself hit-tests, taps elsewhere reach the terminal.
                    .overlay(alignment: .bottomTrailing) {
                        if !terminalAtTail { jumpToLatestPill }
                    }
                    .animation(.easeInOut(duration: 0.15), value: terminalAtTail)
                if let note = actionNote {
                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                }
                controlBar
                replyBar
            }
        }
        // Left-edge swipe → back to the agents list. Edge-only, so it never fights the
        // terminal scroll. Rendered ONLY for the front pane: EdgeSwipeBack attaches its
        // recognizer to the WINDOW, so N keep-mounted panes would otherwise stack N
        // recognizers that all fire on one edge swipe.
        .overlay { if isForeground { EdgeSwipeBack { onClose() } } }
        // Runs ONCE per slot lifetime now (the pane stays mounted, so paneID never changes):
        // the one-shot prefill delivery + first status resolve.
        .task(id: paneID) {
            await refresh()
            await deliverPrefillIfNeeded()
        }
        // Re-resolve status each time the pane returns to the front; drop either
        // keyboard owner when it backgrounds so a hidden keep-mounted pane cannot
        // retain the software keyboard.
        .onChange(of: isForeground) { _, nowFront in
            if nowFront { Task { await refresh() }
            } else {
                replyFocused = false
                terminalInputFocused = false
            }
        }
        // When the app returns to the foreground after a real background, reseed the
        // FRONT pane the same way the header refresh button does (bump streamGen →
        // remount → startBackfill() reads the durable current screen + scrollback).
        // Its live stream stalled while backgrounded and reconnects from the live
        // tail, so output produced while away is otherwise lost until a manual
        // refresh (issue #62 follow-up). Gated on isForeground so only the visible
        // pane pays the reseed; hidden keep-mounted panes reseed when next front.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active:
                if wasBackgrounded && isForeground { streamGen += 1 }
                wasBackgrounded = false
            default:
                break
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
                Text(heading).font(Typography.app(16, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Spacer()
                Button {
                    streamGen += 1            // reconnect the pane's stream (re-create LiveTerminalView)
                    Task { await refresh() }   // and re-resolve the agent's status/identity
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15)).foregroundStyle(Palette.textDim)
                }
            }
            if let group {
                HStack(spacing: 8) {
                    // Left: the pulsing status pill (dot + status word).
                    HStack(spacing: 6) {
                        PulsingDot(color: group.color, active: group == .working)
                        Text(group.sectionTitle).font(Typography.microLabel).tracking(1)
                            .foregroundStyle(group.color)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(group.color.opacity(0.12)).clipShape(Capsule())

                    Spacer(minLength: 6)

                    // Center: how long the agent has been in this status (live).
                    if let sinceMs = statusSinceMs {
                        let start = Date(timeIntervalSince1970: Double(sinceMs) / 1000)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(elapsedLabel(ctx.date.timeIntervalSince(start)))
                                .font(Typography.machine(12)).monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                        }
                    }

                    Spacer(minLength: 6)

                    // Right: per-agent actions (⋯) — mute lives here.
                    agentActionsMenu
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(Palette.surface)
    }

    /// When the agent entered its current status — the SAME anchor the list card's
    /// time-in-state badge uses (`status_since_unix_ms`, daemon #173), so the two
    /// screens cannot disagree about one fact.
    ///
    /// This used to read `lastCompletedTurn.completedUnixMs` and call it an
    /// approximation of the current turn's start. For an IDLE agent that happens to be
    /// exact — it went idle precisely when its last turn completed — which is why idle
    /// always matched and the bug hid. For a WORKING agent it is the moment the
    /// PREVIOUS turn finished, so the header over-counted by the entire idle gap before
    /// the current turn began. The real field existed all along; the header was never
    /// repointed at it when the list badge was.
    ///
    /// The completed-turn value stays as the fallback for a daemon too old to report
    /// `status_since` — a slightly-off timer beats no timer.
    private var statusSinceMs: Int64? {
        statusAnchorUnixMs(statusSinceUnixMs: agent?.statusSinceUnixMs,
                           lastCompletedUnixMs: agent?.lastCompletedTurn?.completedUnixMs)
    }

    /// Compact elapsed-time label: "45s", "1m 20s", "12m", "1h 5m". Seconds show only
    /// for the first ten minutes, where they read as motion; past that the minute (then
    /// hour) is enough.
    private func elapsedLabel(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        if h > 0 { return "\(h)h \(m)m" }
        if m >= 10 { return "\(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// The header's ⋯ overflow — the per-agent mute today, and the home for future
    /// per-agent actions. When muted, the button shows a struck bell so the state reads
    /// at a glance without opening the menu.
    private var agentActionsMenu: some View {
        Menu {
            Section {
                Button {
                    Task {
                        if let out = try? await client.read(pane: paneID, source: .visible, format: .text) {
                            UIPasteboard.general.string = out.text
                        }
                    }
                } label: { Label("Copy screen", systemImage: "doc.on.doc") }
                Button {
                    Task {
                        if let out = try? await client.read(pane: paneID, source: .recentUnwrapped, format: .text) {
                            UIPasteboard.general.string = out.text
                        }
                    }
                } label: { Label("Copy recent output", systemImage: "doc.on.clipboard") }
            }
            Section("Text size") {
                Button {
                    terminalFontSize = min(terminalFontSize + 1, 24)
                } label: { Label("Increase", systemImage: "textformat.size.larger") }
                Button {
                    terminalFontSize = max(terminalFontSize - 1, 9)
                } label: { Label("Decrease", systemImage: "textformat.size.smaller") }
                Button {
                    terminalFontSize = 12.5
                } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            Button {
                mute.toggle(paneID)
            } label: {
                Label(mute.isMuted(paneID) ? "Unmute notifications" : "Mute notifications",
                      systemImage: mute.isMuted(paneID) ? "bell" : "bell.slash")
            }
            Button(role: .destructive) {
                Task {
                    try? await client.closePane(paneID: paneID)
                    onClose()   // the pane is gone → back to the agents list
                }
            } label: {
                Label("Close agent", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: mute.isMuted(paneID) ? "bell.slash" : "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(mute.isMuted(paneID) ? Palette.waiting : Palette.textDim)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
    }

    /// Shown only while the pane is scrolled away from its newest output, so it is out
    /// of the way the rest of the time. Uses the app's primary ink-fill treatment, the
    /// same one the send arrow and the banner's Switch button use.
    private var jumpToLatestPill: some View {
        Button { jumpToTailToken += 1 } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                Text("Latest").font(Typography.app(12, .semibold))
            }
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Palette.text).clipShape(Capsule())
        }
        .padding(.trailing, 16).padding(.bottom, 12)
        .accessibilityLabel(Text("Jump to latest output"))
    }

    // MARK: classic-renderer banner

    /// The one-time offer to switch Claude Code from its laggy fullscreen renderer to the
    /// smooth inline "classic" one. A compact `surface` card with a hairline border (the
    /// kit's card shell), reusing the existing tokens: Geist app voice, ink text tiers, and
    /// the same ink-fill primary button as the send/keycap controls. Purely additive — it
    /// touches neither the scroll code, the PTY width-lock, nor the pane lifecycle.
    private var tuiBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                Text("Smoother scrolling for Claude Code")
                    .font(Typography.app(14, .semibold)).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Button { dismissTuiBanner() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint).frame(width: 28, height: 28)
                }
                .accessibilityLabel(Text("Dismiss"))
            }
            Text("Claude Code opens in fullscreen mode, which makes scrolling here laggy. "
                 + "Switch to smooth (classic) scrolling? You can switch back to fullscreen "
                 + "anytime with /tui fullscreen.")
                .font(Typography.app(12)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { switchToClassicTui() } label: {
                    Text("Switch").font(Typography.app(13, .semibold)).foregroundStyle(Palette.ground)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Palette.text).clipShape(Capsule())
                }
                .disabled(switchingTui)
                .opacity(switchingTui ? 0.5 : 1)
                Button { dismissTuiBanner() } label: {
                    Text("Not now").font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Palette.surfaceRaised).clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
    }

    /// [Switch] — send `/tui default` through the SAME confirmed-delivery prompt path the reply
    /// box uses (`client.prompt` with `waitUntil: anyAgentStatus`), then close the banner for good
    /// ONLY on a clean delivery. `/tui default` runs as a Claude Code slash command AND persists to
    /// the host's ~/.claude/settings.json, so this one switch both flips the current agent live and
    /// makes every future Claude Code agent open in classic (smooth-scroll) mode. `waitUntil` makes
    /// the server report a truthful delivery and THROW on a stranded draft / not-ready composer,
    /// rather than the unconditional written-to-pty a bare prompt returns — which would dismiss the
    /// banner while nothing actually switched (the round-1 failure, in a narrower form).
    private func switchToClassicTui() {
        // Coalesce repeated taps: without this each tap would queue another /tui default prompt
        // (the reply box's send is already gated by `sending`; the banner had no equivalent).
        guard !switchingTui else { return }
        switchingTui = true
        let pane = paneID
        // Mark the one-time prompt answered ONLY after the send is CONFIRMED delivered. If it fails
        // (agent not at a ready composer, a stranded draft, a transient error), keep the banner so the
        // reader can retry instead of silently believing they switched while scrolling stays laggy. On
        // success the banner is dismissed for ALL agents (Claude Code persists the classic setting).
        Task {
            defer { switchingTui = false }
            do {
                _ = try await client.prompt(pane: pane, text: "/tui default",
                                            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
                tuiClassicPrompted = true
                actionNote = "Switched. Claude Code will open in smooth-scroll mode from now on"
            } catch {
                actionNote = "Couldn't switch. Tap Switch to try again"
            }
        }
    }

    /// [Not now] / ✕ — asked once, for ALL agents: set the one-time flag so the banner
    /// never nags again (persisted app-wide via @AppStorage).
    private func dismissTuiBanner() { tuiClassicPrompted = true }

    // MARK: input

    // No Approve/Reject buttons: a fixed "1"/"2" mapping assumes a two-option
    // menu shape the server never guarantees, and both reviewers found it could
    // submit the OPPOSITE of the label (a menu with a broader grant at 2). Until
    // the option list is delivered as structured data, the reader answers by
    // typing the choice and pressing Return — which is the safe, verifiable path.
    // The keycap row is HORIZONTALLY SCROLLABLE so it can hold more than fits the
    // phone's width (esc/arrows/tab plus Shift+Tab, Ctrl, ^C, Return) without
    // collapsing each cap. Caps are intrinsic width (not maxWidth:.infinity, which
    // would expand infinitely inside a horizontal scroll view).
    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyCap(label: "esc", key: "Escape")
                keyCap(symbol: "chevron.left", key: "Left")
                keyCap(symbol: "chevron.up", key: "Up")
                keyCap(symbol: "chevron.down", key: "Down")
                keyCap(symbol: "chevron.right", key: "Right")
                // End (end-of-line cursor) + the two scroll jumps for a mouse-mode agent
                // like Claude Code: Ctrl+Home = jump to TOP, Ctrl+End = jump to BOTTOM
                // (and re-enable auto-follow). ESC[1;5H / ESC[1;5F are the xterm Ctrl+Home
                // / Ctrl+End sequences Claude Code's readline keymap honors (End alone is a
                // cursor key there, not a scroll — hence the two Ctrl jumps for scrolling).
                keyCap(label: "end", key: "End")
                rawCap(symbol: "arrow.up.to.line", sequence: "\u{1b}[1;5H")
                // Jump to the newest output. Routed through the pane rather than a raw
                // byte sequence, so a plain shell scrolls its own scrollback while a
                // mouse-mode agent gets Ctrl+End. Deliberately NOT disabled on
                // `sending || pendingPrefill` like the keycaps: this is local view
                // navigation, not input to the agent.
                Button { jumpToTailToken += 1 } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 44, minHeight: 34)
                        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(Text("Jump to latest output"))
                keyCap(label: "tab", key: "Tab")
                // Shift+Tab (CBT / back-tab, ESC[Z) — cycles Claude-Code modes. A
                // raw escape sequence, not a named key: delivered verbatim to the PTY.
                rawCap(label: "S-Tab", sequence: "\u{1b}[Z")
                // Sticky Ctrl: arm, then the next typed char becomes its control byte.
                ctrlCap
                // ^P (previous prompt/history) — a one-tap control sequence for
                // navigating OMP's prompt history without first arming Ctrl.
                rawCap(label: "^P", sequence: "\u{10}")
                // ^C (interrupt) — the common one-tap case; a raw control byte.
                rawCap(label: "^C", sequence: "\u{03}")
                // The submit affordance rawKeys needs — typing never submits, so
                // Return is the deliberate second action. Highlighted, as the mockup
                // shows it.
                keyCap(symbol: "return", key: "Enter", primary: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func keyCap(label: String? = nil, symbol: String? = nil, key: String, primary: Bool = false) -> some View {
        Button { send(.key(key)) } label: {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                else { Text(label ?? key).font(Typography.machine(12)) }
            }
            .foregroundStyle(primary ? Palette.ground : Palette.textDim)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 34)
            .background(primary ? Palette.text : Palette.surface).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        // Disabled while a pre-fill is pending too: a stray Return during automatic
        // delivery could race the in-flight agent.prompt (and Return into a booting
        // shell is the execute-unintended hazard we are closing).
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(key))
    }

    /// A cap that sends a raw byte SEQUENCE (a control byte or an escape sequence)
    /// straight to the PTY via `pane.send_text` — for keys herdr's named allow-list
    /// does not cover (Shift+Tab = `ESC[Z`, `^C` = `\u{03}`). Routed through the
    /// `.rawSequence` action so it is delivered verbatim, not newline-refused.
    private func rawCap(label: String? = nil, symbol: String? = nil, sequence: String) -> some View {
        Button { send(.rawSequence(sequence)) } label: {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                else { Text(label ?? "").font(Typography.machine(12)) }
            }
            .foregroundStyle(Palette.textDim)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 34)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(label ?? symbol ?? "key"))
    }

    /// The sticky Ctrl toggle. Tap to arm (it highlights in the working blue); the
    /// next character typed in the reply field is consumed and sent as its control
    /// byte (see `handleReplyChange`), then it disarms. Tapping again while armed
    /// cancels it.
    private var ctrlCap: some View {
        Button { ctrlArmed.toggle() } label: {
            Text("ctrl").font(Typography.machine(12))
                .foregroundStyle(ctrlArmed ? Palette.ground : Palette.textDim)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 34)
                .background(ctrlArmed ? Palette.working : Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(ctrlArmed ? "control armed" : "control"))
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            // Collapse-keyboard button — shown only while the keyboard is up. It lives
            // INSIDE the bar's HStack (laid out beside the field/send), NOT in a
            // `.keyboard` accessory toolbar: that toolbar floated on top of the send
            // button. Matched to the send button's circular footprint.
            if replyFocused {
                Button {
                    replyFocused = false
                    terminalInputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                        .frame(width: 40, height: 40)
                        .background(Palette.surface).clipShape(Circle())
                }
                .accessibilityLabel("Collapse keyboard")
            }
            TextField("type a reply…", text: $reply)
                .font(Typography.app(15)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Palette.surface).clipShape(Capsule())
                .focused($replyFocused)
                .disabled(replyDictating)   // dictation owns the field while live
                // Ctrl-toggle interception: while armed, the next character typed
                // here becomes a control byte instead of message text.
                .onChange(of: reply) { oldValue, newValue in
                    handleReplyChange(old: oldValue, new: newValue)
                }
                .submitLabel(.send)
                // Return sends the reply then releases both input owners on iPhone and
                // iPad, so the software keyboard dismisses instead of re-focusing the
                // terminal. A terminal tap explicitly re-enables direct PTY input.
                .onSubmit {
                    if canSend { sendTapped() }
                    replyFocused = false
                    terminalInputFocused = false
                }
            // Dictate into the reply (on-device). isActive: isForeground stops the mic
            // if this pane stops being the front one (no hot mic behind a hidden pane);
            // onStart disarms any pending ctrl chord and `replyDictating` suppresses the
            // chord interception, so a dictation partial is never read as a control byte.
            MicButton(text: $reply, diameter: 40, iconSize: 15,
                      isActive: isForeground && !autoDelivering, recording: $replyDictating,
                      onStart: { ctrlArmed = false })
                // Mutually gated with Send AND the programmatic pre-fill auto-deliver:
                // isActive drops on autoDelivering so an in-flight dictation stops before
                // the auto-deliver clears the reply, and it can't be started during either.
                .disabled(sending || autoDelivering)
            // When the input is EMPTY the send arrow is dead, so offer saved prompts in its
            // place; otherwise the normal send arrow (same 40x40 circle, mutually exclusive
            // by the same empty predicate `canSend` uses).
            if reply.trimmingCharacters(in: .whitespaces).isEmpty {
                savedPromptsButton
            } else {
                Button { sendTapped() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Palette.ground : Palette.textFaint)
                        .frame(width: 40, height: 40)
                        .background(canSend ? Palette.text : Palette.surface).clipShape(Circle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        .sheet(isPresented: $showSavePrompt) {
            SavePromptSheet { nick, txt in savedPrompts.add(nickname: nick, text: txt) }
        }
    }

    /// Replaces the (dead) send arrow when the input is empty: a menu of saved prompts. Tap one
    /// to insert + send it; "Save new prompt…" opens the editor; the submenu deletes.
    private var savedPromptsButton: some View {
        Menu {
            ForEach(savedPrompts.prompts) { p in
                Button { usePrompt(p) } label: { Label(p.label, systemImage: "text.quote") }
            }
            if !savedPrompts.prompts.isEmpty { Divider() }
            Button { showSavePrompt = true } label: { Label("Save new prompt…", systemImage: "plus") }
            if !savedPrompts.prompts.isEmpty {
                Menu {
                    ForEach(savedPrompts.prompts) { p in
                        Button(role: .destructive) { savedPrompts.delete(p.id) } label: { Text(p.label) }
                    }
                } label: { Label("Delete a prompt", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "bookmark").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textDim)
                .frame(width: 40, height: 40)
                .background(Palette.surface).clipShape(Circle())
        }
        .disabled(sending || autoDelivering)
    }

    /// Insert a saved prompt into the reply field and send it — the same path a typed reply
    /// takes (`sendTapped` → mode-aware `send(.submitText)` → confirmed `agent.prompt`).
    private func usePrompt(_ p: SavedPrompt) {
        reply = p.text
        sendTapped()
    }

    /// Routes a reader action through InputRouter, then executes the plan. A
    /// refusal is shown, never a silent no-op; a rejection surfaces a clear reason.
    private func send(_ action: InputAction) {
        let mode = agent.map { router.mode(for: $0) } ?? .rawKeys
        let plan = router.plan(action: action, pane: paneID, mode: mode)
        Task {
            sending = true
            defer { sending = false }
            do {
                switch plan {
                case .prompt(let pane, let text):
                    // submitPrompt confirms delivery and sets the note from it.
                    try await submitPrompt(pane: pane, text: text)
                case .text(let pane, let text):
                    try await client.sendText(pane: pane, text: text); actionNote = nil
                case .rawText(let pane, let text):
                    try await client.sendText(pane: pane, text: text); actionNote = nil
                case .keys(let pane, let keys):
                    try await client.sendKeys(pane: pane, keys: keys); actionNote = nil
                case .refused(let reason):
                    actionNote = "not sent: \(reason)"; return
                }
                if case .submitText = action { reply = "" }
                // Give the pane a beat to reflect the input, then re-read.
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refresh()
            } catch let apiError as APIError {
                actionNote = Self.promptFailureNote(for: apiError)
            } catch {
                actionNote = "send failed: \(error)"
            }
        }
    }

    /// While the Ctrl toggle is armed, consume the next TYPED character and send it
    /// as its control byte instead of adding it to the message. Only reacts to a
    /// single added character (typing) — not deletion or the programmatic clear
    /// after a send — so a backspace can never be misread as a chord.
    private func handleReplyChange(old: String, new: String) {
        // A dictation append (even a single-char first partial) must never be read as a
        // ctrl chord — only real typing arms and fires one.
        guard !replyDictating else { return }
        guard ctrlArmed else { return }
        // Treat ONLY a clean single-char APPEND as a chord: `new` must be `old`
        // plus one trailing character. A mid-cursor insertion or paste (where the
        // added char is NOT the suffix) must NOT be read as a chord — otherwise
        // `removeLast()` would delete the wrong character and `new.last` would send
        // the wrong Ctrl byte (a spurious ^C could interrupt the pane; review HIGH).
        // In that case leave the text untouched and just disarm.
        guard new.count == old.count + 1, new.hasPrefix(old), let typed = new.last else {
            ctrlArmed = false
            return
        }
        guard let ctrl = InputRouter.controlByte(for: typed) else {
            // No control code for this character (a digit, space, emoji…): disarm
            // without consuming it, so the character stays as ordinary text.
            ctrlArmed = false
            return
        }
        ctrlArmed = false
        reply.removeLast()     // the appended char was a chord, not message text
        send(.rawSequence(String(ctrl)))
    }

    /// Submits a reply as a prompt WITH delivery confirmation. Sets the visible note
    /// from herdr's `delivery`: a confirmed turn (`submitted`) clears it, while a
    /// stranded draft (`writtenToPty` — bytes in the composer but no turn started,
    /// the herdr#18/#26 state) is surfaced rather than shown as sent. Throws the
    /// server's APIError on rejection so `send` can show a clear reason.
    private func submitPrompt(pane: String, text: String) async throws {
        // agent.prompt writes the text AND schedules a guarded Enter, so the reply
        // submits regardless of the immediate `delivery` — which on the fast
        // wait-match path is always `written_to_pty` (the Enter is still ~300ms
        // out). Showing a "waiting to submit" note after every reply would read as
        // "it didn't send" for the very bug this fixes, and invite a re-send. A
        // GENUINE non-delivery (occupant changed, agent not ready, input pending)
        // THROWS an APIError that `send` surfaces via `promptFailureNote`; so on a
        // clean return, clear the note.
        _ = try await client.prompt(
            pane: pane, text: text,
            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
        actionNote = nil
    }

    /// Maps a prompt rejection to a note the reader can act on — no more silent
    /// non-delivery.
    private static func promptFailureNote(for error: APIError) -> String {
        switch error.code {
        case "agent_blocked", "agent_input_pending":
            // The agent is showing a menu (plan-approval / question). Routing normally
            // switches to raw keys when this is detected; if a send still races the
            // status here, tell the reader they can type the answer or use the keycaps.
            return "agent is asking — type your answer or use the keys, then Enter"
        case "agent_not_ready":
            return "agent not ready, try again"
        case "agent_prompt_not_received":
            return "not delivered, try again"
        case "timeout":
            return "sent, awaiting confirmation"
        default:
            return "send failed: \(error)"
        }
    }

    // MARK: data

    /// The live terminal (`LiveTerminalView`) renders the pane output itself from
    /// the raw byte stream, so refreshing here is only about the agent: re-resolve
    /// it so the status badge and input mode track the live pane. (There is no
    /// snapshot read anymore — the stream is the source of truth for output.)
    private func refresh() async {
        await reresolveAgent()
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
        // A genuine MENU/blocked state is NOT a transient composer hiccup — adopt it so
        // the app can drive the menu with raw keys (answer a plan-approval / AskUserQuestion).
        // Only hold the prior intent agent for a true composer blip (composer nil, not blocked).
        if priorWasIntent && liveLostComposer && !live.isAwaitingMenuInput { return }
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
                // Give up the AUTO-deliver but NEVER trap the reader: release the lock so
                // the reply bar is fully usable and a manual Send goes through the normal
                // path. The typed task stays in the field for one tap.
                pendingPrefill = false
                actionNote = "couldn't auto-send, tap Send to deliver it"
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }     // don't spin after teardown
            // The live terminal already shows the boot as it streams; no snapshot
            // read is needed to keep the pane visible while we wait to deliver.
        }
    }

    /// The reply-bar send action. A pending pre-fill is delivered PROMPT-ONLY
    /// (never rawKeys, at any time); a normal reply uses the usual routing.
    private func sendTapped() {
        // An explicit Send ALWAYS takes over from any pending auto-deliver and goes
        // through the normal prompt path (`send` → agent.prompt, server-gated). It must
        // never be gated on the pre-fill delivery succeeding — that is exactly what could
        // trap the reader on a stuck pre-fill with the reply bar locked.
        pendingPrefill = false
        send(.submitText(reply))
    }
}

/// Settings (screen 05): connection status, notification preferences, and the
/// trouble actions. Preferences persist locally via @AppStorage; wiring them to
/// real push delivery is a follow-up, so they record intent, not delivery.
/// A jump target within Settings. The iPad sidebar index uses it to scroll the detail pane's
/// SettingsView to a section; iPhone tabs and modal presentations leave it nil (no scrolling).
/// The Settings index→detail destinations (redesign #144). `machines` folds
/// Connection + Federation (the box you talk to and the boxes it aggregates);
/// `accounts` and `notifications` each own a screen; `about` bundles the light
/// sections (Trouble / Help / Support / About) — rendered INLINE on the iPhone
/// index, and as a single "App & About" detail on the iPad split.
enum SettingsSection: Hashable, CaseIterable {
    case machines, accounts, notifications, about, appearance

    var label: String {
        switch self {
        case .machines:      return "Machines"
        case .accounts:      return "Accounts"
        case .notifications: return "Notifications"
        case .about:         return "App & About"
        case .appearance:    return "Text size"
        }
    }

    var icon: String {
        switch self {
        case .machines:      return "server.rack"
        case .accounts:      return "key.horizontal"
        case .notifications: return "bell"
        case .about:         return "info.circle"
        case .appearance:    return "textformat.size"
        }
    }
}

/// A compact reference of the iPad hardware-keyboard shortcuts, shown by ⌘/.
struct ShortcutsSheet: View {
    var onClose: () -> Void = {}

    private let rows: [(keys: String, label: String)] = [
        ("⌘ K", "Show or hide the sidebar"),
        ("⌘ /", "This shortcut list"),
        ("⌘ +", "Increase terminal font size"),
        ("⌘ −", "Decrease terminal font size"),
        ("⌘ 0", "Reset terminal font size"),
    ]

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(Typography.app(20, .semibold))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textDim)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Divider().overlay(Palette.hairlineQuiet)
                VStack(spacing: 0) {
                    ForEach(rows, id: \.keys) { row in
                        HStack(spacing: 14) {
                            Text(row.keys)
                                .font(Typography.machine(14, .semibold))
                                .foregroundStyle(Palette.text)
                                .frame(minWidth: 54, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                            Text(row.label)
                                .font(Typography.app(15))
                                .foregroundStyle(Palette.textDim)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                Text("Arrow keys, Tab and control keys pass straight through to the focused terminal.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The back affordance on a pushed Settings detail (iPhone). It is its OWN view so its
/// `@Environment(\.dismiss)` resolves to the NavigationStack push it sits under and pops
/// exactly that — reading dismiss on `SettingsView` itself would target the enclosing
/// tab/sheet, the wrong level. The iPad split passes `showBack: false` (its sidebar is
/// the navigation, so there is nothing to pop).
private struct SettingsBackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            ZStack {
                Circle().fill(Palette.surfaceRaised).frame(width: 32, height: 32)
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Back"))
    }
}

/// Left-edge swipe-back for a pushed Settings detail screen. Holds its OWN
/// `@Environment(\.dismiss)` — like `SettingsBackButton` — so the swipe pops
/// exactly the NavigationStack push it sits under, not the enclosing tab/sheet.
/// Reuses the app's window-level `EdgeSwipeBack` recognizer (the same one the
/// terminal pane uses), which works even though the nav bar is hidden.
private struct DetailSwipeBack: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        EdgeSwipeBack { dismiss() }
    }
}

struct SettingsView: View {
    let client: HerdrClient
    /// Live agents, mirrored in from the home view exactly like GramView's — the
    /// Federation section derives its remote-machine (peer) list from these.
    let agents: [AgentInfo]
    var host: String
    var connected: Bool = true
    /// Whether "Reconnect now" is safe to offer. FALSE while the connection is in
    /// the host-key-rejection state — a bare reconnect there would first-contact-
    /// trust whatever key appears next, routing around the very gate the recovery
    /// screen enforces. The row is disabled with a reason in that state.
    var canReconnect: Bool = true
    var onReconnect: () -> Void = {}
    /// Nil when Settings is a persistent tab (no close button); a modal sheet passes
    /// one and the header shows an xmark — mirrors GramView's nav-agnostic contract.
    var onClose: (() -> Void)?
    /// iPad only: which grouped detail the sidebar index selected, rendered directly in
    /// the split's detail column (no NavigationStack — the split view IS the nav). Nil =
    /// iPhone (and the screenshot mock): the whole index → detail flow in a NavigationStack.
    var detail: SettingsSection? = nil

    @AppStorage("notify.needsInput") private var notifyNeedsInput = true
    @AppStorage("notify.dies") private var notifyDies = true
    @AppStorage("notify.finishes") private var notifyFinishes = false
    @AppStorage("notify.gram") private var notifyGram = true
    @State private var copied = false
    /// The credential accounts (subscriptions) for the Accounts section. Fetched by
    /// this view itself (`.task` below) via the injected `client`, mirroring how the
    /// Federation section derives from the injected agents. Empty until loaded, and
    /// on an older daemon lacking `accounts.list` (the fetch is `try?`).
    @State private var accounts: [CredentialAccount] = []
    /// A pending "use this account for ALL agents of its harness" bulk swap (nil =
    /// no dialog). Set from an account row's long-press menu; the confirm fans the
    /// per-agent swap out over every same-kind agent.
    @State private var bulkSwapTarget: CredentialAccount?
    /// The account whose in-app sign-in sheet is open (nil = closed).
    @State private var loginAccount: CredentialAccount?
    /// Whether the "Add account" sheet is open.
    @State private var showAddAccount = false
    /// The account staged for a log-out confirmation (nil = none).
    @State private var logoutAccount: CredentialAccount?
    /// The account staged for a remove-from-list confirmation (nil = none).
    @State private var removeAccount: CredentialAccount?
    /// The result summary of the last bulk swap ("Moved 3 of 4 …"), shown in an
    /// alert. nil = no alert.
    @State private var bulkResult: String?
    /// The "how to set up accounts" guide sheet, opened from the Accounts section.
    @State private var showAccountsSetup = false
    /// The gestures tutorial, opened from the Help row (its persistent home now that
    /// it's no longer a tab). Presented as a child sheet over Settings.
    @State private var showGestures = false
    /// The "add a machine" federation setup guide, opened from the Federation
    /// section's "How to add a machine" row. A child sheet over Settings.
    @State private var showFederationSetup = false
    /// The tip jar (StoreKit 2). Renders nothing until products load, so the section
    /// is invisible before the App Store Connect products exist.
    @ObservedObject private var tipStore = TipStore.shared
    /// Opens the Privacy/Terms/GitHub links in the system browser. Overridable in
    /// previews/UI-tests so automated runs never actually leave the app.
    @Environment(\.openURL) private var openURL
    /// The system notification permission, so the notify section can prompt for it
    /// (notDetermined) or point to iOS Settings (denied) instead of toggling silently
    /// into a dead end. Refreshed on appear and on foreground (after a Settings trip).
    @State private var notifyAuth: UNAuthorizationStatus = .notDetermined
    @Environment(\.scenePhase) private var scenePhase
    /// The connected daemon's version + any staged self-update, from `server.staged_update`.
    /// Fetched by this view (`.task` below) with `try?`, so a daemon too old to know the method
    /// (or a transient failure) simply leaves it nil — the version line and update callout then
    /// don't render, exactly the pre-fork/older-daemon degrade the notify + accounts rows use.
    @State private var stagedUpdate: StagedUpdate?
    /// The "Update & restart the daemon?" confirmation (the apply restarts the daemon in place).
    @State private var showUpdateConfirm = false
    /// True while `server.apply_staged_update` is in flight and we re-poll for the swap to land.
    @State private var applyingUpdate = false
    /// The apply outcome, shown in an alert (nil = no alert). Distinguishes a clean update, a
    /// partial disk-stale warning, a rolled-back failure, and an unconfirmed "still restarting".
    @State private var updateResult: String?

    var body: some View {
        Group {
            if let detail {
                // iPad split: the sidebar is the index, so render ONLY the selected
                // group's detail here (no NavigationStack — the split view IS the nav).
                detailColumn(detail)
            } else {
                // iPhone (and the screenshot mock): the index → detail flow. A
                // NavigationStack whose root is the AT A GLANCE / MANAGE index; the
                // MANAGE rows push the same detail bodies the iPad renders inline.
                indexStack
            }
        }
        // The gestures reference lives here now (moved out of the main tab bar);
        // reuse the same self-contained help view the first-run popup shows.
        .sheet(isPresented: $showGestures) {
            GesturesHelpView(onClose: { showGestures = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // The federation setup guide, opened from the Federation section.
        .sheet(isPresented: $showFederationSetup) {
            FederationSetupView(onClose: { showFederationSetup = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Load the tip products when Settings opens. No-ops after a successful load;
        // re-tries after a prior failure, so products created in ASC later appear.
        .task { await tipStore.loadProducts() }
        // Fetch the credential accounts for the Accounts section when Settings opens.
        // `try?` so an older daemon without `accounts.list` (or a transient failure)
        // just leaves the section empty rather than surfacing an error here.
        .task { accounts = (try? await client.accountsList()) ?? [] }
        // Fetch the daemon version + any staged self-update. `try?` so an older daemon without
        // `server.staged_update` leaves it nil (version line + update callout simply absent).
        .task { stagedUpdate = try? await client.stagedUpdate() }
        // "How to set up accounts" — a step-by-step guide for adding another
        // subscription on the box (accounts live there, not in the app).
        .sheet(isPresented: $showAccountsSetup) {
            AccountsSetupView(onClose: { showAccountsSetup = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Bulk swap: "use this account for all <kind> agents". Confirms (naming the
        // count, since it restarts each one's turn), then fans the per-agent swap
        // out sequentially and reports the outcome in an alert.
        .confirmationDialog(
            bulkSwapTarget.map { "Use \($0.label) for all \($0.kind.capitalized) agents?" } ?? "",
            isPresented: Binding(
                get: { bulkSwapTarget != nil },
                set: { if !$0 { bulkSwapTarget = nil } }
            ),
            presenting: bulkSwapTarget
        ) { account in
            let targets = agents.filter { $0.agent == account.kind }
            Button("Move \(targets.count) agent\(targets.count == 1 ? "" : "s")", role: .destructive) {
                let accountID = account.id
                let label = account.label
                let total = targets.count
                Task {
                    var moved = 0
                    var failed = 0
                    var lastError: String?
                    for info in targets {
                        do {
                            try await client.restartAgent(target: info.paneID, account: accountID)
                            moved += 1
                        } catch {
                            // Any failure (no_resumable_session OR anything else):
                            // count it generically and keep the REAL error to surface,
                            // rather than mislabelling every failure as "no resumable
                            // session". `\(error)` is the APIError's "code: message" —
                            // same interpolation the per-agent swap uses.
                            failed += 1
                            lastError = "\(error)"
                        }
                    }
                    if failed == 0 {
                        bulkResult = "Moved all \(moved) agent\(moved == 1 ? "" : "s") to \(label)."
                    } else {
                        bulkResult = "Moved \(moved) of \(total). \(failed) couldn't be moved"
                            + (lastError.map { ": \($0)" } ?? "") + "."
                    }
                    accounts = (try? await client.accountsList()) ?? []
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            let n = agents.filter { $0.agent == account.kind }.count
            Text("Restarts \(n) \(account.kind.capitalized) agent\(n == 1 ? "" : "s") onto "
                + "\(account.label). This interrupts each one's current turn. "
                + "Sessions reopen with --resume.")
        }
        .alert(
            "Swap subscription",
            isPresented: Binding(
                get: { bulkResult != nil },
                set: { if !$0 { bulkResult = nil } }
            ),
            presenting: bulkResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result)
        }
        // Update & restart: confirm (it restarts the daemon in place — agents keep running via
        // live-handoff), then apply and re-poll for the swap to land.
        .confirmationDialog(
            "Update & restart the daemon?",
            isPresented: $showUpdateConfirm
        ) {
            Button("Update & restart") { applyUpdate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let staged = stagedUpdate?.staged {
                Text("Swaps the daemon to build \(staged.sha) and restarts it in place. Your "
                    + "agents keep running — their sessions are preserved across the restart.")
            }
        }
        .alert(
            "Daemon update",
            isPresented: Binding(
                get: { updateResult != nil },
                set: { if !$0 { updateResult = nil } }
            ),
            presenting: updateResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result)
        }
        // Keep the notify section's permission state honest: on open, and again when the
        // app returns to the foreground (the user may have flipped it in iOS Settings).
        .onAppear { refreshNotifyAuth() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshNotifyAuth() } }
    }

    // MARK: Index → detail (iPhone NavigationStack)

    /// The iPhone Settings index: an AT A GLANCE status card and a MANAGE group of
    /// drill-in rows above the fold, the light sections (Trouble / Help / Support /
    /// About) inline below. The MANAGE rows are value-based `NavigationLink`s; the one
    /// `navigationDestination` renders the shared detail bodies with a back button.
    private var indexStack: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Palette.hairlineQuiet)
                    ScrollView {
                        // Grouped subviews keep this builder well under SwiftUI's 10-child
                        // ViewBuilder ceiling (7 children + the footers Group).
                        VStack(alignment: .leading, spacing: 0) {
                            atAGlanceSection
                            manageSection
                            appearanceSection
                            troubleSection
                            helpSection
                            supportSection
                            aboutSection
                            Group {
                                versionFooter
                                githubFooter
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsSection.self) { section in
                detailScreen(section, showBack: true)
            }
        }
    }

    /// The iPad detail column: one group's detail, on the app ground, no back button
    /// (the sidebar index is the navigation).
    private func detailColumn(_ section: SettingsSection) -> some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            detailScreen(section, showBack: false)
        }
    }

    /// Maps a grouped destination to its detail body. Machines folds Connection +
    /// Federation; Accounts and Notifications reuse their section views verbatim; About
    /// bundles the light sections (only reached as a destination on iPad — inline on the
    /// iPhone index).
    @ViewBuilder
    private func detailScreen(_ section: SettingsSection, showBack: Bool) -> some View {
        switch section {
        case .machines:      machinesDetail(showBack: showBack)
        case .accounts:      accountsDetail(showBack: showBack)
        case .notifications: notificationsDetail(showBack: showBack)
        case .about:         aboutDetail(showBack: showBack)
        case .appearance:    appearanceDetail(showBack: showBack)
        }
    }

    /// iPad/Mac "Text size": the same control the iPhone index shows inline, given its
    /// own split-view detail so the setting is reachable on regular-width layouts.
    private func appearanceDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Text size", subtitle: "App & terminal text", showBack: showBack) {
            appearanceControls
        }
    }

    private func machinesDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Machines", subtitle: machinesSubtitle, showBack: showBack) {
            connectionSection
            federationSection
        }
    }

    private func accountsDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Accounts", subtitle: accountsHeaderSubtitle,
                       subtitleTint: accountsHeaderTint, showBack: showBack) {
            accountsSection
                .sheet(item: $loginAccount) { account in
                    AccountLoginSheet(client: client, account: account) {
                        Task { accounts = (try? await client.accountsList()) ?? [] }
                    }
                    // The chrome every other sheet in the app gets and this one did not:
                    // full height with a grabber, so swipe-down closes it.
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showAddAccount) {
                    AddAccountSheet(client: client) { refreshed, created in
                        accounts = refreshed
                        // Chain into sign-in for the new account once the add sheet
                        // has dismissed (sequential sheets on the same anchor).
                        if let created {
                            Task {
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                loginAccount = created
                            }
                        }
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .confirmationDialog(
                    logoutAccount.map { "Log out \($0.label)?" } ?? "",
                    isPresented: Binding(
                        get: { logoutAccount != nil },
                        set: { if !$0 { logoutAccount = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: logoutAccount
                ) { account in
                    Button("Log out", role: .destructive) {
                        Task { await performLogout(account) }
                    }
                } message: { account in
                    Text("This clears \(account.label)'s saved credentials on your box. "
                        + "You can sign back in from here anytime.")
                }
                .confirmationDialog(
                    removeAccount.map { "Remove \($0.label)?" } ?? "",
                    isPresented: Binding(
                        get: { removeAccount != nil },
                        set: { if !$0 { removeAccount = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: removeAccount
                ) { account in
                    Button("Remove", role: .destructive) {
                        Task { await performRemove(account) }
                    }
                } message: { account in
                    Text("This removes \(account.label) from the accounts list. "
                        + "Its saved credentials stay on your box, so you can add it back later.")
                }
        }
    }

    /// Remove an account from the list (`accounts.remove`): the daemon drops it from
    /// config.toml and returns the refreshed list. Credentials are left in place.
    private func performRemove(_ account: CredentialAccount) async {
        do {
            accounts = try await client.accountsRemove(id: account.id)
        } catch {
            bulkResult = "Couldn't remove \(account.label): \(error)"
        }
    }

    /// Log an account out by running claude's own `auth logout` in a short-lived pane
    /// pinned to the account's config-home (token cleared), then refresh the list.
    private func performLogout(_ account: CredentialAccount) async {
        guard let configDir = account.configDir,
              let cmd = claudeLogoutCommand(kind: account.kind, configDir: configDir)
        else { return }
        do {
            // Same as sign-in: a short-lived background pane the user never sees.
            let pane = try await client.splitPane(cwd: nil, focus: false)
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            accounts = (try? await client.accountsList()) ?? accounts
            try? await client.closePane(paneID: pane)
        } catch let err {
            bulkResult = "Couldn't log out \(account.label): \(err)"
        }
    }

    private func notificationsDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Notifications", subtitle: notifyHeaderSubtitle,
                       subtitleTint: notifyBlocked ? Palette.waiting : Palette.textFaint,
                       showBack: showBack) {
            notifySection
        }
    }

    /// iPad "App & About": the light sections that stay inline on the iPhone index.
    private func aboutDetail(showBack: Bool) -> some View {
        detailScaffold(title: "App & About", subtitle: "Trouble, help, support & legal",
                       showBack: showBack) {
            troubleSection
            helpSection
            supportSection
            aboutSection
            Group {
                versionFooter
                githubFooter
            }
        }
    }

    /// A detail screen shell: the custom dark header (title + subtitle + optional back
    /// button) over a scroll of the composed section views. Hides the system nav bar so
    /// the app's own header is the only chrome, matching the Gram / Gestures sheets.
    @ViewBuilder
    private func detailScaffold<Content: View>(
        title: String, subtitle: String, subtitleTint: Color = Palette.textFaint,
        showBack: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                detailHeader(title, subtitle: subtitle, tint: subtitleTint, showBack: showBack)
                Divider().overlay(Palette.hairlineQuiet)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content()
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Hiding the nav bar kills UIKit's default interactive-pop, so re-add a
        // left-edge swipe-back on pushed detail screens (iPhone). iPad's split
        // view is the nav (showBack:false), so no gesture there.
        .overlay { if showBack { DetailSwipeBack() } }
    }

    /// The detail header: an optional circular back button, then a title in the app
    /// voice with a machine-voice subtitle beneath it.
    private func detailHeader(_ title: String, subtitle: String, tint: Color, showBack: Bool) -> some View {
        HStack(spacing: 12) {
            if showBack { SettingsBackButton() }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typography.app(20, .semibold)).foregroundStyle(Palette.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Typography.machine(12)).foregroundStyle(tint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: AT A GLANCE (index status card)

    /// The first card answers "is anything wrong?" in three lines: the connection, any
    /// exhausted account (a shortcut into Accounts), and the machines/agents reach.
    private var atAGlanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("AT A GLANCE")
            VStack(spacing: 0) {
                glanceConnectionRow
                if let exhausted = exhaustedAccounts.first {
                    rowDivider
                    glanceExhaustedRow(exhausted)
                }
                rowDivider
                glanceMachinesRow
                if daemonUpdateAvailable {
                    rowDivider
                    glanceUpdateRow
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    /// A quiet shortcut into Machines when the daemon has a staged update — the section that owns
    /// the "Update & restart" action is one tap away (mirrors `glanceExhaustedRow`).
    private var glanceUpdateRow: some View {
        NavigationLink(value: SettingsSection.machines) {
            HStack(spacing: 10) {
                Circle().fill(Palette.waiting).frame(width: 8, height: 8)
                Text("Daemon update available")
                    .font(Typography.app(14)).foregroundStyle(Palette.textDim).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glanceConnectionRow: some View {
        HStack(spacing: 10) {
            Circle().fill(connected ? Palette.done : Palette.died).frame(width: 8, height: 8)
            Text(connected ? "Connected" : "Disconnected")
                .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).layoutPriority(1)
            Text(host).font(Typography.machine(13)).foregroundStyle(Palette.textFaint)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    /// The amber shortcut line — a `NavigationLink` into the Accounts detail, since the
    /// section that owns the problem is one tap away.
    private func glanceExhaustedRow(_ account: CredentialAccount) -> some View {
        NavigationLink(value: SettingsSection.accounts) {
            HStack(spacing: 10) {
                Circle().fill(Palette.waiting).frame(width: 8, height: 8)
                Text("\(account.label) is exhausted")
                    .font(Typography.app(14)).foregroundStyle(Palette.textDim).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glanceMachinesRow: some View {
        let reach = machinesReachability
        return HStack(spacing: 10) {
            Text("\(machineCount) machine\(machineCount == 1 ? "" : "s") · \(agents.count) agent\(agents.count == 1 ? "" : "s")")
                .font(Typography.machine(13)).foregroundStyle(Palette.textFaint)
            Spacer(minLength: 0)
            Text(reach.text).font(Typography.machine(13)).foregroundStyle(reach.color)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    // MARK: MANAGE (drill-in rows)

    /// The three drill-in rows → Machines / Accounts / Notifications, each a value-based
    /// `NavigationLink` with a one-line live summary and a status trailing.
    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("MANAGE")
            VStack(spacing: 0) {
                manageRow(.machines, subtitle: machinesSubtitle) { manageMachinesTrailing }
                rowDivider
                manageRow(.accounts, subtitle: accountsSubtitle) { manageAccountsTrailing }
                rowDivider
                manageRow(.notifications, subtitle: "Push via the herdr fork") { manageNotifyTrailing }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func manageRow<Trailing: View>(
        _ section: SettingsSection, subtitle: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.label).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                    Text(subtitle).font(Typography.app(12)).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var manageMachinesTrailing: some View {
        if daemonUpdateAvailable {
            Text("Update")
                .font(Typography.app(11, .semibold)).foregroundStyle(Palette.waiting)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.waiting.opacity(0.12)))
                .overlay(Capsule().stroke(Palette.waiting.opacity(0.5), lineWidth: 1))
        }
        Text("\(agents.count) agent\(agents.count == 1 ? "" : "s")")
            .font(Typography.machine(12)).foregroundStyle(Palette.textDim)
        Circle().fill(machinesReachability.color).frame(width: 8, height: 8)
    }

    @ViewBuilder private var manageAccountsTrailing: some View {
        if !exhaustedAccounts.isEmpty {
            Text("\(exhaustedAccounts.count) exhausted")
                .font(Typography.app(11, .semibold)).foregroundStyle(Palette.died)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Palette.died.opacity(0.12)))
                .overlay(Capsule().stroke(Palette.died.opacity(0.5), lineWidth: 1))
        }
    }

    @ViewBuilder private var manageNotifyTrailing: some View {
        Text(notifyManageValue).font(Typography.machine(12)).foregroundStyle(notifyManageTint)
    }

    // MARK: Index summaries (computed from live state)

    /// The federation peers, derived from the injected agents (the same source the
    /// Machines detail's `federationSection` uses).
    private var machinePeers: [PeerSummary] { PeerSummary.peerSummaries(from: agents) }

    /// This box + its federated peers.
    private var machineCount: Int { machinePeers.count + 1 }

    /// "This box only" / "This box + N peers" — the Machines row + detail subtitle.
    private var machinesSubtitle: String {
        let n = machinePeers.count
        if n == 0 { return "This box only" }
        return "This box + \(n) federated peer\(n == 1 ? "" : "s")"
    }

    /// Aggregate reachability across the peers, worst case wins — a word + its colour.
    private var machinesReachability: (text: String, color: Color) {
        let offline = machinePeers.filter { $0.reachability == .offline }.count
        if offline > 0 { return ("\(offline) offline", Palette.textDim) }
        if machinePeers.contains(where: { $0.reachability == .degraded }) {
            return ("some slow", Palette.waiting)
        }
        return ("all reachable", Palette.done)
    }

    private var exhaustedAccounts: [CredentialAccount] { accounts.filter { !$0.active } }

    /// The distinct account kinds, in first-seen order (for "claude, codex, kimi").
    private var accountKinds: [String] {
        var seen = Set<String>(); var out: [String] = []
        for account in accounts where !seen.contains(account.kind) {
            seen.insert(account.kind); out.append(account.kind)
        }
        return out
    }

    /// "N subscriptions · claude, codex, kimi" — the Accounts MANAGE-row subtitle.
    private var accountsSubtitle: String {
        guard !accounts.isEmpty else { return "None configured yet" }
        let n = accounts.count
        return "\(n) subscription\(n == 1 ? "" : "s") · \(accountKinds.joined(separator: ", "))"
    }

    /// "N subscriptions · M exhausted" — the Accounts detail-header subtitle (amber when
    /// any is exhausted).
    private var accountsHeaderSubtitle: String {
        guard !accounts.isEmpty else { return "None configured yet" }
        let n = accounts.count
        var text = "\(n) subscription\(n == 1 ? "" : "s")"
        let exhausted = exhaustedAccounts.count
        if exhausted > 0 { text += " · \(exhausted) exhausted" }
        return text
    }
    private var accountsHeaderTint: Color { exhaustedAccounts.isEmpty ? Palette.textFaint : Palette.waiting }

    private var notifyOnCount: Int { [notifyNeedsInput, notifyDies, notifyFinishes, notifyGram].filter { $0 }.count }

    /// iOS is blocking the alerts the user asked for (at least one on, permission denied).
    private var notifyBlocked: Bool { anyNotifyOn && notifyAuth == .denied }

    /// "N of 4 alerts on" — the Notifications detail-header subtitle.
    private var notifyHeaderSubtitle: String { "\(notifyOnCount) of 4 alerts on" }

    /// "N on · blocked" (amber) when iOS is blocking, else "N of 4 on".
    private var notifyManageValue: String {
        notifyBlocked ? "\(notifyOnCount) on · blocked" : "\(notifyOnCount) of 4 on"
    }
    private var notifyManageTint: Color { notifyBlocked ? Palette.waiting : Palette.textDim }

    // Matches the Gram/Gestures header exactly: a left-aligned title in the app
    // voice at .semibold, a bare xmark close on the right, and NO baked-in hairline
    // (the body draws a separate Divider under it, like its sibling sheets). This is
    // a sheet, not a nav push — xmark and swipe-down both dismiss, so there's no back.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(Typography.app(20, .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            // Only a modal presentation gets a close button; as a tab there is none.
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textDim)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("CONNECTION")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle().fill(connected ? Palette.done : Palette.died).frame(width: 8, height: 8)
                    Text(connected ? "Connected" : "Disconnected")
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).layoutPriority(1)
                    Text(host).font(Typography.machine(13)).foregroundStyle(Palette.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                // The connected daemon's own version + commit (distinct from the app version in the
                // footer). Only shown once `server.staged_update` has answered — absent on an older
                // daemon. The version is static across commits, so the sha is what identifies the
                // build; a daemon too old to report it shows just the version.
                if let running = stagedUpdate?.runningVersion {
                    Text(stagedUpdate?.runningSha.map { "herdr daemon \(running) · \($0)" }
                        ?? "herdr daemon \(running)")
                        .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
                }
            }
            .rowShell()
            .padding(.horizontal, 16).padding(.top, 10)   // align with the toggle/action rows
            daemonUpdateCallout
        }
    }

    /// True when the connected daemon has a newer build staged and ready to activate — a staged
    /// build whose sha differs from what's running (HerdrKit's `updateAvailable`), so a stale/equal
    /// manifest never shows a phantom update.
    private var daemonUpdateAvailable: Bool { stagedUpdate?.updateAvailable ?? false }

    /// Shown only when the daemon has a staged self-update: an icon chip + "Update available" + the
    /// staged build's id/date, then an "Update & restart" action (a spinner replaces it while the
    /// apply is in flight). Mirrors `notifyInfoRow`'s callout shape, in its own hairline card.
    @ViewBuilder
    private var daemonUpdateCallout: some View {
        if let staged = stagedUpdate?.staged {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.waiting)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.surfaceRaised))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available")
                        .font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                    Text("Build \(staged.sha) · staged \(String(staged.builtAt.prefix(10)))")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    if applyingUpdate {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Palette.textDim)
                            Text("Updating & restarting…")
                                .font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                        }
                        .padding(.top, 2)
                    } else {
                        Button("Update & restart") { showUpdateConfirm = true }
                            .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .rowShell()
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    /// Activate the staged build. The daemon swaps its binary and re-execs via live-handoff, so the
    /// one-shot apply call may return the `ok` ack OR drop mid-handoff — both mean "restart under
    /// way", so we then re-poll `stagedUpdate()` until the applied build clears its staged manifest.
    /// A server `APIError` is a real verdict, not a dropped socket, and is surfaced distinctly:
    /// `apply_staged_update_disk_stale` = running-new/disk-old (a warning); anything else = the
    /// handoff rolled back and the OLD build is still serving.
    private func applyUpdate() {
        guard !applyingUpdate else { return }
        applyingUpdate = true
        Task {
            do {
                try await client.applyStagedUpdate()
            } catch let apiError as APIError {
                applyingUpdate = false
                if apiError.code == "apply_staged_update_disk_stale" {
                    updateResult = "Updated, with a warning: the new build is running, but the daemon "
                        + "couldn't update its on-disk copy, so a full restart would fall back to the "
                        + "old build until re-applied."
                } else {
                    updateResult = "Update failed: \(apiError). Your daemon is unchanged and still "
                        + "running the current build."
                }
                if let refreshed = try? await client.stagedUpdate() { stagedUpdate = refreshed }
                return
            } catch {
                // Transport dropped mid-handoff — expected: the daemon replaced itself before it
                // could answer on the single-shot socket. Fall through to confirm by re-polling.
            }
            let confirmed = await confirmUpdateApplied()
            applyingUpdate = false
            // Only overwrite on a SUCCESSFUL read: a failed read here means the daemon is still
            // mid-restart, and blanking the state would wrongly hide the banner. The next `.task`
            // (on the view reappearing) re-fetches the true state once the daemon is back.
            if let refreshed = try? await client.stagedUpdate() { stagedUpdate = refreshed }
            updateResult = confirmed
                ? "Updated. The daemon restarted on the new build; your agents kept running."
                : "Update sent — the daemon may still be restarting. Reopen Settings in a moment to "
                    + "confirm the new build."
        }
    }

    /// Poll `stagedUpdate()` until the applied build has cleared its staged manifest (`staged ==
    /// nil`), tolerating the brief window where the daemon is mid-handoff and the socket refuses.
    private func confirmUpdateApplied() async -> Bool {
        for _ in 0..<12 {   // ~12 × 2s = 24s, comfortably past a few-second handoff
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let current = try? await client.stagedUpdate(), current.staged == nil { return true }
        }
        return false
    }

    /// The remote machines (federation peers) whose agents this home box lists —
    /// one row per peer, derived from the injected `agents` (grouped by machineID,
    /// reachability aggregated worst-case in HerdrKit's `PeerSummary`). Empty until
    /// a machine running the herdr fork is added; the "How to add a machine" row
    /// opens the setup guide.
    @ViewBuilder
    private var federationSection: some View {
        let peers = PeerSummary.peerSummaries(from: agents)
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("FEDERATION")
            if peers.isEmpty {
                federationEmpty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                        peerRow(peer)
                        if index < peers.count - 1 { rowDivider }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
                .padding(.horizontal, 16).padding(.top, 10)
            }
            richActionRow("How to add a machine", systemImage: "plus.circle",
                          subtitle: "Connect another computer to your home box") {
                showFederationSetup = true
            }
        }
    }

    /// Local-only: no agent carries a machineID, so there are no remote peers yet.
    /// Explainer copy in the section body rather than a bare empty card.
    private var federationEmpty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No machines connected yet.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Text("Machines running an agent appear here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// One peer: an identity chip keyed on the alias (the same gradient+glyph the
    /// agent cards use), the alias, an "N agent(s)" line, and a reachability badge.
    private func peerRow(_ peer: PeerSummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: peer.alias))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: peer.alias))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.alias)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text("\(peer.agentCount) agent\(peer.agentCount == 1 ? "" : "s")")
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 8)
            peerBadge(peer.reachability)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// The peer's aggregate reachability as a badge. Offline reuses the agent list's
    /// quiet `wifi.slash` square (faint ink — offline is quiet, not the stopped-red
    /// alarm); degraded is an amber dot, reachable a quiet green dot.
    @ViewBuilder
    private func peerBadge(_ reachability: PeerReachability) -> some View {
        switch reachability {
        case .offline:
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.textDim)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.textDim.opacity(0.55), lineWidth: 1.5))
                .accessibilityLabel(Text("offline"))
        case .degraded:
            Circle().fill(Palette.waiting).frame(width: 8, height: 8)
                .accessibilityLabel(Text("degraded"))
        case .reachable:
            Circle().fill(Palette.done).frame(width: 8, height: 8)
                .accessibilityLabel(Text("reachable"))
        }
    }

    // MARK: Accounts (credential subscriptions)

    /// The credential accounts (subscriptions) configured on the home box — one row
    /// per account with its kind identity, status, and usage. Mirrors
    /// `federationSection`: a section label, a rounded/stroked card of `accountRow`s
    /// (or an empty explainer), and a trailing "How accounts work" info row. Accounts
    /// are set up on the box, so there is no in-app add flow — the info row explains.
    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ACCOUNTS")
            if accounts.isEmpty {
                accountsEmpty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        accountRow(account)
                            .contextMenu {
                                // Bulk swap: move every same-kind agent onto this
                                // account at once (e.g. an exhausted Claude → the
                                // spare). Shown only when there are agents to move.
                                if agents.contains(where: { $0.agent == account.kind }) {
                                    Button {
                                        bulkSwapTarget = account
                                    } label: {
                                        Label("Use for all \(account.kind.capitalized) agents",
                                              systemImage: "arrow.left.arrow.right")
                                    }
                                }
                                // Sign in / out of the account from the app — runs
                                // claude's own auth flow pinned to this account's
                                // config-home (claude only for now; needs config_dir).
                                if account.kind == "claude", account.configDir != nil {
                                    Button {
                                        loginAccount = account
                                    } label: { Label("Log in", systemImage: "person.crop.circle.badge.plus") }
                                    Button(role: .destructive) {
                                        logoutAccount = account
                                    } label: { Label("Log out", systemImage: "rectangle.portrait.and.arrow.right") }
                                }
                                // Remove the account from the list entirely (any kind) —
                                // drops it from config.toml; the config-home + creds stay,
                                // so it can be re-added. For clearing out junk/duplicate
                                // entries.
                                Button(role: .destructive) {
                                    removeAccount = account
                                } label: { Label("Remove account", systemImage: "trash") }
                            }
                        if index < accounts.count - 1 { rowDivider }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
                .padding(.horizontal, 16).padding(.top, 10)
            }
            richActionRow("Add account", systemImage: "plus.circle",
                          subtitle: "Register a new subscription, then sign in") {
                showAddAccount = true
            }
            richActionRow("How to set up accounts", systemImage: "questionmark.circle",
                          subtitle: "Manual setup on your box") {
                showAccountsSetup = true
            }
        }
    }

    /// No accounts reported (an older daemon, or none configured). Explainer copy in
    /// the section body rather than a bare empty card — mirrors `federationEmpty`.
    private var accountsEmpty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No accounts configured.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Text("Subscriptions set up on your home box appear here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// One account: an identity chip keyed on the KIND (the same gradient+glyph the
    /// agent cards use, so an account reads as the same family as the agents that run
    /// on it), the label as title, a "kind · plan" subtitle, and a trailing usage +
    /// status view. Mirrors `peerRow`.
    private func accountRow(_ account: CredentialAccount) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: account.kind))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: account.kind))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(accountSubtitle(account))
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                if let email = account.email, !email.isEmpty {
                    Text(email)
                        .font(Typography.machine(11)).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accountTrailing(account)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// "kind" or "kind · plan" — the plan/tier name folds into the subtitle so the
    /// trailing view can stay the meter+status. Nothing extra when usage is absent.
    private func accountSubtitle(_ account: CredentialAccount) -> String {
        var parts: [String] = [account.kind]
        if let plan = account.usage?.plan ?? account.usage?.tier, !plan.isEmpty {
            parts.append(plan)
        }
        return parts.joined(separator: " · ")
    }

    /// The trailing status/usage cluster: the usage meter(s) when a percent is
    /// reported, then the status indicator — a green dot when active, a red
    /// "exhausted" pill when not (colour = meaning, like the agent status badges).
    @ViewBuilder
    private func accountTrailing(_ account: CredentialAccount) -> some View {
        // One meter per reported rate-limit window (the #144 live-usage render): loop
        // `effectiveWindows` — the real `windows` list, or a pair synthesized from the
        // older flat fields — skipping any window without a percent. Handles 0
        // (tier-only / no usage), 1, or many windows gracefully.
        let windows = (account.usage?.effectiveWindows ?? []).filter { $0.usedPercent != nil }
        HStack(spacing: 10) {
            if !windows.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(windows) { window in
                        usageMeter(window, live: account.usage?.source == "live")
                    }
                }
            }
            if account.active {
                Circle().fill(Palette.done).frame(width: 8, height: 8)
                    .accessibilityLabel(Text("active"))
            } else {
                Text("exhausted")
                    .font(Typography.app(11, .semibold)).foregroundStyle(Palette.died)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.died.opacity(0.12)))
                    .overlay(Capsule().stroke(Palette.died.opacity(0.5), lineWidth: 1))
                    .accessibilityLabel(Text("exhausted"))
            }
        }
    }

    /// A tiny usage bar + "NN% · <label>" readout for ONE window, coloured by the
    /// green→amber→red headroom ramp (colour = meaning). Appends a compact reset hint
    /// (today → time, else weekday) when the window carries `resetsAt`, and prefixes a
    /// subtle freshness dot when the snapshot is `source == "live"`.
    private func usageMeter(_ window: UsageWindow, live: Bool) -> some View {
        let clamped = max(0.0, min(100.0, window.usedPercent ?? 0))
        let fill = CGFloat(max(2.0, 34.0 * clamped / 100.0))
        return HStack(spacing: 6) {
            if live {
                Circle().fill(Palette.done).frame(width: 4, height: 4)
                    .accessibilityLabel(Text("live"))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(width: 34, height: 4)
                Capsule().fill(usageColor(clamped)).frame(width: fill, height: 4)
            }
            Text(usageMeterLabel(window, percent: clamped))
                .font(Typography.machine(11)).foregroundStyle(Palette.textDim).fixedSize()
        }
    }

    /// "NN% · <label>" plus a compact reset token when present, e.g. "42% · 5h · 2h left"
    /// or "68% · weekly · Aug 31".
    private func usageMeterLabel(_ window: UsageWindow, percent: Double) -> String {
        var text = "\(Int(percent.rounded()))% · \(window.label)"
        if let hint = resetHint(window.resetsAt) { text += " · \(hint)" }
        return text
    }

    /// The reset token for a usage window: "2h left" when the reset is near, "Aug 31"
    /// when it is further out. Nil when absent or unparseable, so the meter shows no
    /// token rather than a wrong one.
    ///
    /// Both the parsing and the wording live in `HerdrKit.usageResetLabel` so they can be
    /// tested without a view. This previously parsed ISO-8601 inline and produced nothing
    /// at all against a live server, which sends epoch seconds.
    private func resetHint(_ raw: String?) -> String? {
        usageResetLabel(resetsAt: raw)
    }

    /// Usage colour by headroom: comfortable green, amber as it tightens, red at the
    /// cap. The same meaning-carrying palette as the agent status badges.
    private func usageColor(_ percent: Double) -> Color {
        switch percent {
        case ..<75:  return Palette.done
        case ..<95:  return Palette.waiting
        default:     return Palette.died
        }
    }

    private var notifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("NOTIFY ME WHEN")
            // One bordered card holds the four toggles AND the honest status row, so
            // the group reads as a single feature rather than four stray rows plus a
            // shrinking-violet footnote.
            VStack(spacing: 0) {
                groupedToggleRow("An agent needs input", $notifyNeedsInput)
                rowDivider
                groupedToggleRow("An agent dies", $notifyDies)
                rowDivider
                groupedToggleRow("An agent finishes", $notifyFinishes)
                rowDivider
                groupedToggleRow("A gram message arrives", $notifyGram)
                rowDivider
                notifyInfoRow
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
    }

    /// A word-state toggle row (ON/OFF, differentiated by the word not colour, per the
    /// kit) WITHOUT its own border — the card around the group supplies one border for
    /// all of them.
    private func groupedToggleRow(_ label: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack {
                Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                Text(value.wrappedValue ? "ON" : "OFF")
                    .font(Typography.machine(13, .bold)).foregroundStyle(Palette.text)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(value.wrappedValue ? "on" : "off"))
    }

    /// The honest requirement for the toggles above: push IS wired (the app registers
    /// the device + these prefs with the daemon, which sends the APNs), but it only
    /// fires when the machine runs the herdr fork and notifications are allowed. So the
    /// row states the requirement, not a "coming soon" — the feature exists.
    /// The honest status row under the toggles. It reflects the SYSTEM notification
    /// permission: if it's off (never asked, or denied), the toggles alone deliver
    /// nothing, so this offers the way to fix it — a prompt (notDetermined) or a jump to
    /// iOS Settings (denied) — rather than letting the toggles fail silently.
    private var notifyInfoRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notifyAuthIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notifyAuthTint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 4) {
                Text(notifyAuthTitle)
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                Text(notifyAuthBody)
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                switch notifyRowState {
                case .needAllow:
                    Button("Allow notifications") { requestNotifications() }
                        .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                        .padding(.top, 2)
                case .denied:
                    Button("Open Settings") { openIOSSettings() }
                        .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                        .padding(.top, 2)
                case .ok:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// At least one alert category is on. A permission FIX is only surfaced when this is
    /// true — if every toggle is off the system permission is moot, so we neither prompt
    /// nor point to Settings (matching AppDelegate.requestAuthorizationIfWanted's gating).
    private var anyNotifyOn: Bool { notifyNeedsInput || notifyDies || notifyFinishes || notifyGram }

    private enum NotifyRowState { case ok, needAllow, denied }
    private var notifyRowState: NotifyRowState {
        guard anyNotifyOn else { return .ok }
        switch notifyAuth {
        case .notDetermined: return .needAllow
        case .denied: return .denied
        default: return .ok
        }
    }

    private var notifyAuthIcon: String {
        switch notifyRowState {
        case .denied: return "bell.slash"
        case .needAllow: return "bell"
        case .ok: return "bell.badge"
        }
    }
    private var notifyAuthTint: Color {
        switch notifyRowState {
        case .denied: return Palette.waiting
        default: return Palette.textDim
        }
    }
    private var notifyAuthTitle: String {
        switch notifyRowState {
        case .denied: return "Notifications are off"
        case .needAllow: return "Turn on notifications"
        case .ok: return "Push needs the herdr fork"
        }
    }
    private var notifyAuthBody: String {
        switch notifyRowState {
        case .denied:
            return "herdrup can't send these alerts until you allow notifications in iOS Settings."
        case .needAllow:
            return "Allow notifications so these alerts can reach you when an agent needs you or a gram arrives."
        case .ok:
            return "Alerts arrive when your machine runs the herdr fork and you allow notifications."
        }
    }

    private func refreshNotifyAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                notifyAuth = s.authorizationStatus
                guard [.authorized, .provisional, .ephemeral].contains(s.authorizationStatus) else { return }
                // Never register during a buildbox screenshot / XCUITest run — mirrors
                // AppDelegate's guard so an authorized test device can't register while the
                // Settings screen merely renders. ScreenshotMock is DEBUG-only, so is the guard.
                #if DEBUG
                guard ScreenshotMock.mode == nil else { return }
                #endif
                // (Re)register for APNs so a token actually issues — e.g. the user just
                // enabled notifications in iOS Settings. registerForRemoteNotifications is
                // idempotent, so refreshing repeatedly is harmless.
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func requestNotifications() {
        // Same test-mode guard as AppDelegate.requestAuthorizationIfWanted: never prompt
        // or register during a screenshot / XCUITest run.
        #if DEBUG
        guard ScreenshotMock.mode == nil else { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                refreshNotifyAuth()
            }
        }
    }

    private func openIOSSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    /// The UI text-size multiplier (same UserDefaults key RootView applies to
    /// `Typography.scale`). Writing it here re-renders the whole app at the new
    /// size — the terminal is unaffected (it has its own font control below).
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    /// The terminal font size (points), the same app-wide pref the per-agent ⋯ menu
    /// and ⌘± drive. Writing it here live-updates any open terminal (LiveTerminalView
    /// applies the new size in place via its own `@AppStorage` observer).
    @AppStorage("terminal.fontSize") private var terminalFontSize: Double = 12.5

    /// "Text size" section for the iPhone index: a heading over the shared controls.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TEXT SIZE")
            appearanceControls
        }
    }

    /// The two text-size controls — app chrome scale + terminal font — shared by the
    /// iPhone inline `appearanceSection` and the iPad/Mac `appearanceDetail`. Both live
    /// here so the setting reads the same on every layout.
    @ViewBuilder
    private var appearanceControls: some View {
        // App chrome (Typography.scale), 90–140%.
        textSizeControl(
            caption: "App text — lists, menus & settings",
            value: "\(Int((uiFontScale * 100).rounded()))%",
            preview: { Text("The quick brown fox").font(Typography.app(15)) },
            canDecrease: uiFontScale > 0.9, onDecrease: { stepFontScale(-0.1) },
            canReset: uiFontScale != 1.0, onReset: { uiFontScale = 1.0 },
            canIncrease: uiFontScale < 1.4, onIncrease: { stepFontScale(0.1) }
        )
        // Terminal font (terminal.fontSize), 9–24 pt.
        textSizeControl(
            caption: "Terminal text — agent output",
            value: "\(String(format: "%g", terminalFontSize)) pt",
            preview: { Text("~ $ herdr").font(Typography.machine(15)) },
            canDecrease: terminalFontSize > 9, onDecrease: { stepTerminalFont(-1) },
            canReset: terminalFontSize != 12.5, onReset: { terminalFontSize = 12.5 },
            canIncrease: terminalFontSize < 24, onIncrease: { stepTerminalFont(1) }
        )
    }

    /// One labelled text-size control: a caption, a preview + current value, and the
    /// A−/Reset/A+ button row — the card style the appearance section has always used.
    private func textSizeControl<P: View>(
        caption: String,
        value: String,
        @ViewBuilder preview: () -> P,
        canDecrease: Bool, onDecrease: @escaping () -> Void,
        canReset: Bool, onReset: @escaping () -> Void,
        canIncrease: Bool, onIncrease: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(Typography.app(12, .semibold)).foregroundStyle(Palette.textFaint)
            VStack(spacing: 0) {
                HStack {
                    preview().foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value)
                        .font(Typography.machine(13, .bold)).foregroundStyle(Palette.textDim)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                rowDivider
                HStack(spacing: 10) {
                    textSizeButton("A\u{2212}", enabled: canDecrease, onDecrease)
                    textSizeButton("Reset", enabled: canReset, onReset)
                    textSizeButton("A+", enabled: canIncrease, onIncrease)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// Step the UI scale by `delta`, rounded to 0.1 and clamped to [0.9, 1.4].
    private func stepFontScale(_ delta: Double) {
        let next = ((uiFontScale + delta) * 10).rounded() / 10
        uiFontScale = min(1.4, max(0.9, next))
    }

    /// Step the terminal font by `delta` points, clamped to [9, 24] — matches the
    /// per-agent ⋯ menu and ⌘± controls.
    private func stepTerminalFont(_ delta: Double) {
        terminalFontSize = min(24, max(9, terminalFontSize + delta))
    }

    private func textSizeButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(15, .semibold))
                .foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var troubleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TROUBLE")
            actionRow("Reconnect now", enabled: canReconnect,
                      note: "verify the host key first") { onReconnect() }
            actionRow(copied ? "Copied ✓" : "Copy diagnostics") { copyDiagnostics() }
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("HELP")
            richActionRow("Gestures", systemImage: "hand.draw",
                          subtitle: "How to move around the app") { showGestures = true }
            linkRow("Report a bug or request a feature", systemImage: "exclamationmark.bubble",
                    url: URL(string: "https://github.com/jerryfane/herdrup/issues")!)
        }
    }

    /// Outbound links to the public web pages. Distinguished from in-app rows by the
    /// `arrow.up.right` trailing glyph (leaving the app), set inside `linkRow`.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ABOUT")
            linkRow("Privacy Policy", systemImage: "lock.shield",
                    url: URL(string: "https://herdrup.themartian.app/legal/privacy")!)
            linkRow("Terms of Service", systemImage: "doc.text",
                    url: URL(string: "https://herdrup.themartian.app/legal/terms")!)
        }
    }

    /// The tip jar (StoreKit 2). Renders ONLY when products are loaded — `.idle`,
    /// `.loading`, and `.unavailable` all render nothing, so the section is simply
    /// absent before the App Store Connect products exist or when offline.
    @ViewBuilder
    private var supportSection: some View {
        if case .loaded(let products) = tipStore.loadState, !products.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("SUPPORT THE PROJECT")
                VStack(spacing: 0) {
                    ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                        tipRow(product)
                        if index < products.count - 1 { rowDivider }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
                .padding(.horizontal, 16).padding(.top, 10)
                supportFeedback
            }
        }
    }

    @ViewBuilder
    private var supportFeedback: some View {
        switch tipStore.purchaseState {
        case .thankYou:
            Text("Thank you, it means a lot.")
                .font(Typography.app(12, .medium)).foregroundStyle(Palette.done)
                .padding(.horizontal, 20).padding(.top, 8)
        case .failed(let message):
            Text(message)
                .font(Typography.app(12)).foregroundStyle(Palette.died)
                .padding(.horizontal, 20).padding(.top, 8)
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private func tipRow(_ product: Product) -> some View {
        Button { Task { await tipStore.purchase(product) } } label: {
            HStack(spacing: 12) {
                Image(systemName: tipGlyph(for: product.id))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                Text(product.displayName.isEmpty ? tipFallbackName(product.id) : product.displayName)
                    .font(Typography.app(15)).foregroundStyle(Palette.text)
                Spacer()
                if isPurchasing(product) {
                    ProgressView().tint(Palette.textDim)
                } else {
                    Text(product.displayPrice)
                        .font(Typography.machine(13, .semibold)).foregroundStyle(Palette.text)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing(product))
    }

    private func isPurchasing(_ product: Product) -> Bool {
        if case .purchasing(let id) = tipStore.purchaseState { return id == product.id }
        return false
    }

    private func tipGlyph(for id: String) -> String {
        if id == TipStore.coffeeID { return "cup.and.saucer.fill" }
        if id == TipStore.lunchID { return "fork.knife" }
        return "wineglass.fill"
    }

    private func tipFallbackName(_ id: String) -> String {
        if id == TipStore.coffeeID { return "Coffee" }
        if id == TipStore.lunchID { return "Lunch" }
        return "Dinner"
    }

    /// The app names itself here — "herdrup mobile <version> (<build>)" — with the
    /// design's one-line stance. Version + build come from the bundle (MARKETING_VERSION
    /// / CFBundleVersion), so they track the shipped build, not a hardcoded string.
    private var versionFooter: some View {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return VStack(spacing: 4) {
            Text("herdrup mobile \(short) (\(build))")
                .font(Typography.machine(12)).foregroundStyle(Palette.textFaint)
            Text("dark only, on purpose")
                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    /// The open-source affordance, at the very bottom — a quiet capsule, deliberately
    /// not a card row: it says "the app IS open source", not "here's a setting". No
    /// official GitHub SF Symbol exists; the code-brackets glyph reads as "source" and
    /// sidesteps the Octocat trademark.
    private var githubFooter: some View {
        Button {
            openURL(URL(string: "https://github.com/jerryfane/herdrup")!)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Text("Open source on GitHub").font(Typography.app(12, .medium))
            }
            .foregroundStyle(Palette.textDim)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(Typography.microLabel).tracking(1.2).foregroundStyle(Palette.textFaint)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
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

    /// An icon-led row with an ALWAYS-visible subtitle (unlike `actionRow`, whose
    /// `note` shows only when disabled). Used for Gestures and, via `linkRow`, the
    /// outbound Privacy/Terms links.
    private func richActionRow(
        _ label: String, systemImage: String, subtitle: String? = nil,
        trailingGlyph: String = "chevron.right", _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(15)).foregroundStyle(Palette.text)
                    if let subtitle {
                        Text(subtitle).font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                    }
                }
                Spacer()
                Image(systemName: trailingGlyph)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .rowShell()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 10)
    }

    /// A `richActionRow` that opens an external URL in the system browser, marked with
    /// the leaving-the-app glyph.
    private func linkRow(_ label: String, systemImage: String, url: URL) -> some View {
        richActionRow(label, systemImage: systemImage, trailingGlyph: "arrow.up.right") {
            openURL(url)
        }
    }

    private func copyDiagnostics() {
        // Host + app version only — never anything sensitive (no key, ever).
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        UIPasteboard.general.string = "herdr-ios \(version), host \(host)"
        copied = true
        // Revert the confirmation so a second copy gives feedback.
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}

/// A single-field rename form (agent name or terminal label), styled like `SavePromptSheet`.
/// `normalize` coerces the input to the target's grammar — identity for a free-form terminal label,
/// `AgentName.normalize` for an agent. It applies to the TRIMMED input, so what's shown as "saved as"
/// is exactly what's sent. The preview line appears only when normalization changes the input (the
/// agent case), so the user isn't surprised by "Build Logs" → "build-logs". Owns its own field state.
struct RenameSheet: View {
    let title: String
    let fieldLabel: String
    let placeholder: String
    let current: String
    let footnote: String
    let normalize: (String) -> String
    var onSave: (String) -> Void

    @State private var value: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, fieldLabel: String, placeholder: String, current: String, footnote: String,
         normalize: @escaping (String) -> String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.placeholder = placeholder
        self.current = current
        self.footnote = footnote
        self.normalize = normalize
        self.onSave = onSave
        _value = State(initialValue: current)
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effective: String { normalize(trimmed) }
    private var canSave: Bool { !trimmed.isEmpty && !effective.isEmpty }
    private var showPreview: Bool { canSave && effective != trimmed }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(fieldLabel).font(Typography.microLabel).foregroundStyle(Palette.textFaint)
                            .padding(.leading, 4)
                        TextField(placeholder, text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(Typography.app(15)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        if showPreview {
                            Text("Will be saved as \(effective)")
                                .font(Typography.machine(12)).foregroundStyle(Palette.textDim)
                                .padding(.leading, 4)
                        }
                        Text(footnote).font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 4).padding(.top, 2)
                        Button {
                            onSave(effective); dismiss()
                        } label: {
                            Text("Save").font(Typography.app(16, .semibold)).foregroundStyle(Palette.ground)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
                        }
                        .disabled(!canSave).opacity(canSave ? 1 : 0.5).padding(.top, 6)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }
}

/// Caps a column at a readable width and centers it. On a wide canvas (iPad /
/// macOS) an edge-to-edge single column of cards drifts far past a comfortable
/// measure; capping then re-expanding centers the capped column in the available
/// space. On iPhone (narrower than the cap) it is inert — the inner cap never
/// binds, so the layout is unchanged.
private struct ReadableColumn: ViewModifier {
    let cap: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: cap)
            .frame(maxWidth: .infinity)
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

    /// Center + cap a column at a comfortable reading width on wide canvases;
    /// inert on iPhone (narrower than `cap`). See `ReadableColumn`.
    func readableColumn(_ cap: CGFloat = 560) -> some View {
        modifier(ReadableColumn(cap: cap))
    }
}

#if DEBUG
/// DEBUG-only screenshot mode: renders the list/pane views from MockTransport —
/// no connection, no key, so the buildbox can screenshot them SAFELY (the app
/// otherwise launches to the empty ConnectView). Enable by launching with env
/// `HERDR_SCREENSHOT_MOCK=list` (default) or `=pane`, or the `-herdrScreenshotMock`
/// launch argument.
#if DEBUG
/// Swipe-between-agents receipt harness (`HERDR_SCREENSHOT_MOCK=paging`). Holds three agents
/// in the REAL `PaneKeepAliveContainer`, mirroring `TerminalHomeView`'s open/navigate, so an
/// XCUITest swipe pages the front pane and the header heading changes. No LRU eviction here —
/// three panes stay mounted so swipe-back is a proven warm hit.
struct PagingTestHarness: View {
    let client: HerdrClient
    @State private var slots: [PaneSlot]
    @State private var frontID: String?

    init(client: HerdrClient) {
        self.client = client
        let sibs = [
            MockTransport.pagingAgent(kind: "ALFA", pane: "pg:a"),
            MockTransport.pagingAgent(kind: "BRAVO", pane: "pg:b"),
            MockTransport.pagingAgent(kind: "CHARLIE", pane: "pg:c"),
        ]
        _slots = State(initialValue: [PaneSlot(paneID: "pg:a", title: "ALFA", agent: sibs[0],
                                               initialReply: "", siblings: sibs)])
        _frontID = State(initialValue: "pg:a")
    }

    var body: some View {
        PaneKeepAliveContainer(
            client: client, slots: slots, frontID: frontID,
            isPresented: true,
            onClose: { frontID = nil },
            onNavigate: { slot, delta in navigate(from: slot, delta: delta) })
    }

    private func open(_ slot: PaneSlot) {
        if let i = slots.firstIndex(where: { $0.paneID == slot.paneID }) {
            let existing = slots.remove(at: i); slots.append(existing)
        } else {
            slots.append(slot)
        }
        frontID = slot.paneID
    }

    private func navigate(from slot: PaneSlot, delta: Int) {
        guard let i = slot.siblings.firstIndex(where: { $0.paneID == frontID }),
              slot.siblings.indices.contains(i + delta) else { return }
        let next = slot.siblings[i + delta]
        open(PaneSlot(paneID: next.paneID, title: next.displayName, agent: next,
                      initialReply: "", siblings: slot.siblings))
    }
}
#endif

enum ScreenshotMock {
    case onboarding, pairingGuidance, list, rosterStress, pane, settings, newAgent, scroll, ccscroll, paging, backfill, gram

    static var mode: ScreenshotMock? {
        let env = ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"]?.lowercased()
        let arg = ProcessInfo.processInfo.arguments.contains("-herdrScreenshotMock")
        guard env != nil || arg else { return nil }
        switch env {
        case "onboarding": return .onboarding
        case "pairing-guidance": return .pairingGuidance
        case "rosterstress": return .rosterStress
        case "pane": return .pane
        case "settings": return .settings
        case "newagent": return .newAgent
        // `scroll` drives the omp scroll receipt: a real SwiftTerm pane seeded with 200
        // distinct lines of scrollback so a swipe visibly moves the content.
        case "scroll": return .scroll
        // `ccscroll` drives the Claude-Code scroll receipt: a real SwiftTerm pane put
        // into alt-screen + mouse-mode (like Claude Code fullscreen) whose stand-in
        // agent redraws shifted content when it RECEIVES an SGR wheel event — so a swipe
        // proves drag → app emits wheel → content moves.
        case "ccscroll": return .ccscroll
        // `paging` drives the swipe-between-agents receipt: three distinctively-named agents
        // in the keep-mounted container; a swipe fronts the neighbour and the header changes.
        case "paging": return .paging
        // `backfill` drives the scrollback-backfill receipt: the LIVE stream carries only a
        // short one-screen seed, while agent.read (recent, ansi) returns ~1000 lines of history
        // — so scrollback the swipe reveals can ONLY have come from the connect-time backfill.
        case "backfill": return .backfill
        // `gram` renders the Gram page from a canned owner-view gram.list — the
        // messages, unread badge, claim states, and composer, for a layout FYI.
        case "gram": return .gram
        default: return .list
        }
    }
}

/// Canned-response transport for the screenshot mock. The JSON is machine-checked
/// in Tests/HerdrKitTests/MockWireFixtureTests.swift (the app target can't be
/// compiled on Linux) — keep the two fixtures in sync.
struct MockTransport: HerdrTransport {
    /// When true, `pane.stream` seeds MANY lines of scrollback (for the omp UI scroll
    /// receipt) instead of the short screenshot seed. Default false keeps the
    /// buildbox screenshot fixtures unchanged.
    var scrollback = false
    /// When set, this pane is a Claude-Code stand-in (alt-screen + mouse-mode) that
    /// scrolls in RESPONSE to SGR wheel events the app sends — for the ccscroll receipt.
    var ccDriver: CCScrollDriver?
    /// When true, `agent.read` (source=recent, ansi) returns MANY numbered lines of history
    /// while `pane.stream` seeds only the SHORT one-screen reset — so the scrollback a swipe
    /// reveals can ONLY come from the connect-time backfill path. For the backfill receipt.
    var backfill = false
    /// Stateful agent-list source for the refresh-during-scroll regression receipt.
    var rosterDriver: RosterStressDriver?

    func roundTrip(_ requestLine: String) async throws -> String {
        // ccscroll receipt: any request may carry an SGR wheel event the app sent
        // (via sendText); the driver scrolls the stand-in Claude Code if so.
        ccDriver?.received(requestLine)
        if requestLine.contains("accounts.list") { return Self.accountsList }
        if requestLine.contains("agent.list") {
            if let rosterDriver {
                return try await rosterDriver.nextAgentList()
            }
            return Self.agentList
        }
        if requestLine.contains("agent.read") { return backfill ? Self.backfillRead() : Self.agentRead }
        if requestLine.contains("gram.list") { return Self.gramList }
        if requestLine.contains("gram.post") { return Self.gramPosted }
        if requestLine.contains("gram.get_file") { return Self.gramFileContent }
        if requestLine.contains("gram.upload_chunk") { return Self.gramOk }
        if requestLine.contains("gram.delete") { return Self.gramOk }
        if requestLine.contains("pane.set_pty_size") { return Self.panePtySize }
        return #"{"id":"mock","result":{}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        // `pane.stream` (the live terminal): reply with the stream_started ack, then
        // a reset seed, then finish — so the DEBUG pane shows a rendered SwiftTerm
        // terminal, not an empty one. The scrollback seed (UI test) feeds 200 lines so
        // there is real history to scroll; the default seed is the short screenshot one.
        if requestLine.contains("pane.stream") {
            if let driver = ccDriver {
                // Claude-Code stand-in: keep the stream OPEN so the driver can push
                // redraws in response to wheel events the app sends.
                return AsyncThrowingStream { continuation in
                    continuation.yield(Self.paneStreamAck)
                    driver.attach(continuation)
                }
            }
            let reset = scrollback ? Self.scrollbackResetFrame() : Self.paneStreamReset
            return AsyncThrowingStream { continuation in
                continuation.yield(Self.paneStreamAck)
                continuation.yield(reset)
                continuation.finish()
            }
        }
        return AsyncThrowingStream { $0.finish() }
    }

    /// A reset frame carrying 200 DISTINCT numbered lines so the terminal has real
    /// scrollback and a swipe visibly changes the rendered content. Hides the cursor
    /// (ESC[?25l) so an un-swiped terminal renders byte-identically frame to frame —
    /// which makes the UI test's "did the content move?" an exact before/after image
    /// compare with no blinking-cursor false positive. Same reset shape as
    /// `paneStreamReset`; base64 built at runtime (DEBUG/UI-test-only, not a fixture).
    static func scrollbackResetFrame() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        for i in 1...200 {
            body += String(format: "SCROLLTEST line %03d  the quick brown fox jumps over the lazy dog\r\n", i)
        }
        body += "SCROLLTEST end, swipe down to reveal earlier lines"
        let b64 = Data(body.utf8).base64EncodedString()
        return "{\"stream\":\"pane.bytes\",\"frame\":\"reset\",\"seq\":0,\"epoch\":7,\"cols\":80,\"rows\":24,\"data_b64\":\"\(b64)\"}"
    }

    /// An `agent.read` response (source=recent, format=ansi) carrying ~1000 DISTINCT numbered
    /// lines as ANSI — the history the app's connect-time backfill prepends into SwiftTerm's
    /// scrollback. `\r\n` endings (no staircase), cursor hidden (ESC[?25l) so static frames stay
    /// byte-identical for the before/after image compare. Built at runtime (DEBUG/UI-test only);
    /// JSONSerialization escapes the ESC + control bytes in the `text` field.
    static func backfillRead() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        for i in 1...1000 {
            body += String(format: "BACKFILL line %04d  the quick brown fox jumps over the lazy dog\r\n", i)
        }
        body += "BACKFILL end, swipe down to reveal earlier lines"
        let payload: [String: Any] = ["id": "mock", "result": ["read": [
            "pane_id": "w1:p1", "text": body, "truncated": false,
            "source": "recent", "format": "ansi"]]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? Self.agentRead
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
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs","account":"claudecrazy","account_config_dir":"/root/.claude-9"},
      {"pane_id":"w3:p1","name":"clientloop","agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold","account":"retired-account","account_unresolved":true},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","name":"discovery","agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"},
      {"pane_id":"w5:p1","name":"huurjacht","agent":"claude","agent_status":"idle","cwd":"/root/huurjacht","terminal_title_stripped":"pararius scrape","archived":{"at":"2026-08-26T18:00:00Z","by":"jerry","reason":"parked for the weekend"}}
    ]}}
    """#

    /// The panes herdr still lists, for the mock render. Excludes w2:p1 so that
    /// row lands in STOPPED via liveness (not a status string). MUST stay in sync
    /// with the census the fixture test uses.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2",
    ]

    /// `accounts.list` for the Settings mock render: two claude accounts (one active
    /// with usage, one exhausted), a codex account with tier-only usage, and a kimi
    /// account with none. Byte-identical to MockWireFixtures.accountsList in the
    /// tests, where it is machine-checked to decode. If you change one, change both.
    static let accountsList = #"""
    {"id":"mock","result":{"type":"accounts_list","accounts":[
      {"id":"acc-claude-1","kind":"claude","label":"Claude Max (work)","active":true,"email":"work@example.com","usage":{"source":"live","windows":[{"label":"5h","used_percent":42,"resets_at":"2000000000","status":"ok"},{"label":"weekly","used_percent":68,"resets_at":"2030-01-15T18:00:00Z","status":"ok"}],"primary_used_percent":42,"secondary_used_percent":68,"resets_at":"2026-08-20T18:00:00Z","plan":"Max"}},
      {"id":"acc-claude-2","kind":"claude","label":"Claude Pro (personal)","active":false,"email":"personal@example.com","usage":{"primary_used_percent":100,"secondary_used_percent":100,"plan":"Pro"}},
      {"id":"acc-codex-1","kind":"codex","label":"Codex (team)","active":true,"email":"team@example.com","usage":{"tier":"Plus"}},
      {"id":"acc-kimi-1","kind":"kimi","label":"Kimi","active":true}
    ]}}
    """#

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach jarvis\n\n> Ran 146 tests, 0 failures\n> Edited SessionRecoveryTests.swift  +18 -4\n\nRun `swift test` with -Xswiftc -warnings-as-errors?\n  1. yes\n  2. no, skip it\n>\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#

    /// `gram.list` owner view for the Gram-page mock render. Byte-identical to
    /// MockWireFixtures.gramList in the tests, where it is machine-checked to decode.
    static let gramList = #"""
    {"id":"mock","result":{"type":"gram_list","messages":[
      {"id":"g1","direction":"agent_to_owner","from":"trend-scout","text":"Digest ready: 7 trends, 2 need your call.","created_unix_ms":1723000005000,"read_by_owner":false},
      {"id":"g2","direction":"owner_to_agent","from":"owner","text":"Anyone free to triage the failing CI?","created_unix_ms":1723000004000,"read_by_owner":true},
      {"id":"g3","direction":"owner_to_agent","from":"owner","text":"Rebase the vetrina branch onto main.","grabbed_by":"herdr-app","grabbed_unix_ms":1723000004500,"created_unix_ms":1723000003000,"read_by_owner":true},
      {"id":"g4","direction":"owner_to_agent","from":"owner","to":"clientloop","text":"Ship the Amigo POC scaffold today.","created_unix_ms":1723000002000,"read_by_owner":true},
      {"id":"g5","direction":"agent_to_owner","from":"vetrina","text":"Deployed vetrina.dev, it is live.","created_unix_ms":1723000001000,"read_by_owner":true,"file":{"name":"vetrina-live.png","size":48213,"mime":"image/png","sha256":"9f2c0a1b7d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"}}
    ]}}
    """#

    /// A canned `gram.post` echo, so the mock composer's send path resolves.
    static let gramPosted =
        #"{"id":"mock","result":{"type":"gram_sent","message":{"id":"gp1","direction":"owner_to_agent","from":"owner","text":"(sent)","created_unix_ms":1723000006000,"read_by_owner":true}}}"#

    /// A canned `gram.get_file` reply; the bytes decode to "hello world".
    /// Byte-identical to MockWireFixtures.gramFileContent.
    static let gramFileContent =
        #"{"id":"mock","result":{"type":"gram_file_content","name":"vetrina-live.png","mime":"image/png","size":11,"data_base64":"aGVsbG8gd29ybGQ="}}"#

    /// A canned `type: ok` reply for `gram.upload_chunk` and `gram.delete`.
    static let gramOk = #"{"id":"mock","result":{"type":"ok"}}"#

    // pane.stream / pane.set_pty_size fixtures for the live terminal. Byte-identical
    // to MockWireFixtures in Tests/HerdrKitTests/MockWireFixtureTests.swift, which is
    // where they are machine-checked to decode through the real HerdrClient path.
    static let paneStreamAck =
        #"{"id":"mock","result":{"type":"stream_started","pane_id":"w1:p1","epoch":7,"cols":80,"rows":24,"base_seq":0,"resync":true}}"#
    static let paneStreamReset =
        #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":7,"cols":80,"rows":24,"data_b64":"G1syShtbSBtbMTszODs1OzM5bWhlcmRyG1swbSBsaXZlIHRlcm1pbmFsIOKAlCBtb2NrIHJlbmRlcg0KDQokIGhlcmRyIGFnZW50IGF0dGFjaCBqYXJ2aXMNCj4gUmFuIDE0NiB0ZXN0cywgMCBmYWlsdXJlcw0KDQpbZGVtbyBkYXRhIOKAlCBubyBsaXZlIGNvbm5lY3Rpb25dDQo="}"#
    static let panePtySize =
        #"{"id":"mock","result":{"type":"pane_pty_size","pane_id":"w1:p1","cols":80,"rows":24,"locked":false}}"#

    /// A decoded blocked agent for the pane screenshot: status "blocked" groups
    /// as NEEDS YOU, so the pane renders its status badge. No composer field, so
    /// input falls to rawKeys — fine for a static shot.
    static let demoPaneAgent: AgentInfo? = try? JSONDecoder().decode(
        AgentInfo.self,
        from: Data(#"{"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"}"#.utf8))

    /// A distinctively-named agent for the `paging` receipt. Name == kind == cwd folder (all the same
    /// distinctive word), so the deduped header heading collapses to just that word (e.g. "ALFA") —
    /// which an XCUITest asserts CHANGES after a swipe fronts the neighbour. The `frontIs` CONTAINS
    /// match still keys off that word. Force-decoded: the literal is fixed + valid.
    static func pagingAgent(kind: String, pane: String) -> AgentInfo {
        try! JSONDecoder().decode(AgentInfo.self, from: Data(
            #"{"pane_id":"\#(pane)","name":"\#(kind)","agent":"\#(kind)","agent_status":"idle","cwd":"/root/\#(kind)"}"#.utf8))
    }
}

/// Keeps the precondition roster stable, then starts changing row count, row status and
/// sections only after a real scroll begins. Active-scroll snapshots contain a deferred
/// marker and an actual phase-dependent roster row, then polling blocks once the gesture
/// is idle. Those changes can reach the screen only through pending-snapshot promotion.
/// If the app changes its displayed snapshot while scrolling, a distinct violation row
/// makes that mutant fail the receipt.
final class RosterStressDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var scrollRefreshCount = 0
    private var armed = false
    private var scrollingActive = false
    private var deferredServed = false
    private var publishedWhileScrolling = false
    private var violationServed = false
    private var eagerStackVisible = false

    func recordScrolling(_ scrolling: Bool) {
        lock.withLock { scrollingActive = armed && scrolling }
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func recordEagerStackVisible() {
        lock.withLock { eagerStackVisible = true }
    }

    func recordRosterPublication(whileScrolling: Bool) {
        guard whileScrolling else { return }
        lock.withLock { publishedWhileScrolling = true }
    }

    func nextAgentList() async throws -> String {
        let responseState: (
            phase: Int,
            includesDeferred: Bool,
            includesViolation: Bool,
            includesEagerReceipt: Bool
        )? = lock.withLock {
            if deferredServed, !scrollingActive {
                guard publishedWhileScrolling, !violationServed else { return nil }
                violationServed = true
                return (
                    (scrollRefreshCount % 2) + 1,
                    false,
                    true,
                    eagerStackVisible
                )
            }
            guard scrollingActive else {
                // No 50 ms churn before the first gesture. Repeated responses are
                // byte-equivalent and receiveRoster equality-gates them, so cold
                // layout is a precondition rather than a second stress scenario.
                return (0, false, false, eagerStackVisible)
            }
            scrollRefreshCount += 1
            deferredServed = true
            return (
                (scrollRefreshCount % 2) + 1,
                true,
                publishedWhileScrolling,
                eagerStackVisible
            )
        }
        guard let responseState else {
            try await Task.sleep(nanoseconds: 300_000_000_000)
            return MockTransport.agentList
        }

        let phase = responseState.phase
        let count: Int
        switch phase {
        case 0: count = 80
        case 1: count = 82
        default: count = 81
        }
        var agents: [[String: Any]] = (0..<count).map { index in
            let statusIndex = (index + phase) % 3
            let status = ["blocked", "working", "idle"][statusIndex]
            return [
                "pane_id": String(format: "stress:p%03d", index),
                "name": String(format: "stress-agent-%03d", index),
                "agent": "claude",
                "agent_status": status,
                "cwd": "/root/stress",
                "terminal_title_stripped": "refreshing roster while scrolling",
                "account": "acc-claude-1",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_000 - index - phase],
            ]
        }
        agents.append([
            "pane_id": "stress:top",
            "name": "scroll-top-marker",
            "agent": "claude",
            "agent_status": "blocked",
            "cwd": "/root/stress",
            "terminal_title_stripped": "must move off screen",
            "last_completed_turn": ["completed_unix_ms": 2_000_000_000_002],
        ])
        agents.append([
            "pane_id": "stress:bottom",
            "name": "scroll-bottom-marker",
            "agent": "claude",
            // The Idle section starts collapsed. Keep this marker at the bottom of
            // the expanded Working section so the UI test can prove displacement.
            "agent_status": "working",
            "cwd": "/root/stress",
            "terminal_title_stripped": "must become visible",
            "last_completed_turn": ["completed_unix_ms": 1],
        ])
        agents.append([
            "pane_id": "stress:phase",
            "name": phase == 0
                ? "stable-pre-scroll-phase-marker"
                : "scroll-refresh-phase-\(phase)-marker",
            "agent": "claude",
            "agent_status": phase == 0 ? "blocked" : "working",
            "cwd": "/root/stress",
            "terminal_title_stripped": "actual generated roster phase",
            "last_completed_turn": ["completed_unix_ms": 2_000_000_000_001],
        ])
        if responseState.includesDeferred {
            agents.append([
                "pane_id": "stress:deferred",
                "name": "deferred-refresh-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "must be promoted after scrolling",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_003],
            ])
        }
        if responseState.includesViolation {
            agents.append([
                "pane_id": "stress:coalescing-violation",
                "name": "coalescing-violation-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "roster published while scrolling",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_004],
            ])
        }
        if responseState.includesEagerReceipt {
            agents.append([
                "pane_id": "stress:eager-stack",
                "name": "eager-stack-marker",
                "agent": "claude",
                "agent_status": "blocked",
                "cwd": "/root/stress",
                "terminal_title_stripped": "eager roster stack is active",
                "last_completed_turn": ["completed_unix_ms": 2_000_000_000_005],
            ])
        }
        let payload: [String: Any] = [
            "id": "mock",
            "result": ["type": "agent_list", "agents": agents],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return MockTransport.agentList
        }
        return text
    }
}

/// Stateful stand-in for a Claude-Code pane in the `ccscroll` UI test. It puts the REAL
/// SwiftTerm view into ALT-SCREEN + MOUSE-MODE (like Claude Code "fullscreen"), then —
/// each time the app SENDS it an SGR wheel event (`ESC[<64`/`<65`, proof the finger-drag
/// was translated to wheel for a mouse-mode agent) — redraws the screen shifted by a few
/// lines, standing in for Claude Code scrolling its own viewport. So the XCUITest proves
/// the whole path: drag → app emits SGR wheel → rendered content moves. If the app fails
/// to emit wheel (the bug), no redraw happens and the screenshots stay identical → FAIL.
final class CCScrollDriver: @unchecked Sendable {
    static let shared = CCScrollDriver()

    private let lock = NSLock()
    private var cont: AsyncThrowingStream<String, Error>.Continuation?
    private var seq: UInt64 = 1
    private var offset = 0            // 0 = newest window (bottom); grows toward older

    /// Called when `pane.stream` opens: keep the continuation, turn on mouse tracking on
    /// the NORMAL (main) buffer, and render the initial window.
    ///
    /// Deliberately NOT the alternate screen: on the alt buffer the OLD gate
    /// (`guard isCurrentBufferAlternate`) already passed, so an alt seed couldn't prove
    /// the new `|| mouseMode != .off` branch is what makes a mouse-mode agent scrollable
    /// (reviewer HIGH). Seeding mouse-mode on the NORMAL buffer exercises exactly the new
    /// branch AND the isScrollEnabled toggle — and would be RED on the old alt-only gate
    /// (a normal-buffer drag returned early → no wheel → static).
    func attach(_ c: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock(); cont = c; offset = 0; lock.unlock()
        // ?1000h+?1006h mouse tracking (SGR), like Claude Code · ?25l hide cursor. NO
        // ?1049h — stays on the normal buffer so `isCurrentBufferAlternate == false`.
        let body = "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?25l" + renderWindow()
        c.yield(resetFrame(body))
    }

    /// Inspect an outgoing request; if it carries an SGR wheel event, scroll + redraw.
    func received(_ requestLine: String) {
        let up = requestLine.contains("[<64")      // wheel-up → older content
        let down = requestLine.contains("[<65")    // wheel-down → newer content
        guard up || down else { return }
        lock.lock()
        offset = max(0, min(offset + (up ? 4 : -4), 170))
        let frame = dataFrame(renderWindow())
        let c = cont
        lock.unlock()
        c?.yield(frame)
    }

    /// A 24-row window into a 200-line virtual transcript at the current `offset`,
    /// cleared + home-positioned so each redraw fully repaints the visible alt screen.
    /// Each row is a FULL-WIDTH band of a character keyed to its line number, so a
    /// scroll (window shift) changes most pixels on screen — a subtle number-only tweak
    /// would fall under the test's pixel-diff threshold even when the scroll DID happen.
    private func renderWindow() -> String {
        var s = "\u{1b}[H\u{1b}[2J"
        let top = max(1, 200 - 24 - offset)
        for i in 0..<24 {
            let n = top + i
            let fill = Character(UnicodeScalar(UInt8(65 + (n % 26))))   // A..Z by line number
            s += String(format: "CC%03d ", n) + String(repeating: fill, count: 60) + "\r\n"
        }
        return s
    }

    private func resetFrame(_ body: String) -> String {
        let b64 = Data(body.utf8).base64EncodedString()
        return "{\"stream\":\"pane.bytes\",\"frame\":\"reset\",\"seq\":0,\"epoch\":7,\"cols\":80,\"rows\":24,\"data_b64\":\"\(b64)\"}"
    }
    private func dataFrame(_ body: String) -> String {
        let b64 = Data(body.utf8).base64EncodedString()
        let s = seq; seq += 1
        return "{\"stream\":\"pane.bytes\",\"frame\":\"data\",\"seq\":\(s),\"epoch\":7,\"data_b64\":\"\(b64)\"}"
    }
}
#endif
