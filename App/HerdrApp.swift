import SwiftUI
import Foundation
import Security
import UIKit    // UIPasteboard (Copy diagnostics)
import UniformTypeIdentifiers
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
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // A guest invite (herdrup://guest-invite#…, or the relay's https /i/… page)
                    // opens the Accept screen; everything else is the agent deep link.
                    if GuestInviteRouter.isInviteLink(url) {
                        GuestInviteRouter.shared.open(url.absoluteString)
                        return
                    }
                    guard let paneID = AgentActivityDeepLink.agentID(from: url) else { return }
                    PushCenter.shared.tapped(paneID: paneID)
                }
        }
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
    /// Guest access (#312): machines shared with this phone, the invite waiting on the
    /// Accept screen, and the shared machine whose home is open (it takes precedence
    /// over the owner session, which stays connected underneath).
    @ObservedObject private var sharedMachines = SharedMachinesStore.shared
    @ObservedObject private var invites = GuestInviteRouter.shared
    @State private var openGuest: GuestAccess?
    /// Whether launch already decided to open the only shared machine.
    @State private var didAutoOpenGuest = false

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
        .fullScreenCover(item: $invites.pending) { pending in
            inviteAccept(pending.invite)
        }
        .alert("Can't open this invite", isPresented: Binding(
            get: { invites.failure != nil },
            set: { if !$0 { invites.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(invites.failure ?? "")
        }
        .onAppear { autoOpenSharedMachine() }
        // A tapped push for an agent shared with this phone opens that share (its home picks
        // the Gram tab or the terminal), in place of whatever screen is showing. A share the
        // phone no longer holds opens nothing.
        .onReceive(push.$pendingGuest) { route in
            guard let route else { return }
            guard let share = route.access(in: sharedMachines.machines) else {
                push.pendingGuest = nil
                return
            }
            if openGuest?.id != share.id { openGuest = share }
        }
        // Shares with push on hold this phone's token too: a new one is registered with each.
        .onChange(of: push.deviceToken) { _, _ in
            GuestPushCenter.shared.deviceTokenChanged(shares: sharedMachines.machines)
        }
        // Reclaim gram attachment staging left by a PREVIOUS session (a crash or a
        // jetsam kill runs no cleanup) here rather than on the Gram page: bytes from a
        // killed session — up to ten 100 MB attachments — would otherwise survive every
        // launch in which the user never opens the Gram tab.
        .task { await GramView.Staging.sweepAbandonedOffMainActor() }
    }

    @ViewBuilder
    private var liveContent: some View {
        if let openGuest {
            GuestHomeView(
                access: openGuest,
                connect: { try GuestConnection.open(openGuest) },
                onBack: guestCanGoBack ? { self.openGuest = nil } : nil,
                onLeave: { self.openGuest = nil })
            .id(openGuest.id)
        } else if let client, let credentials {
            TerminalHomeView(
                client: client,
                onDisconnect: { disconnect() },
                host: credentials.host,
                hostKey: SessionChoice.storeKey(credentials),
                session: credentials.session,
                onSwitchSession: { switchSession(to: $0) },
                onReconnect: { reconnect() },
                onTrustHostKey: { fingerprint in trustAndReconnect(credentials, fingerprint: fingerprint) }
            )
            .id(session)
            .environment(\.guestMachineLabel, Self.hostLabel(for: credentials))
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
            ConnectView(onConnect: { connect($0) }, onOpenShared: { openGuest = $0 })
        }
    }

    /// A guest-only phone (no machines of its own, one share) launches straight into
    /// that share's home, which then has nowhere to go back to.
    private var guestCanGoBack: Bool {
        client != nil || !SavedHostsStore.shared.hosts.isEmpty || sharedMachines.machines.count > 1
    }

    private func autoOpenSharedMachine() {
        #if DEBUG
        guard ScreenshotMock.mode == nil else { return }
        #endif
        guard !didAutoOpenGuest else { return }
        didAutoOpenGuest = true
        if SavedHostsStore.shared.hosts.isEmpty, sharedMachines.machines.count == 1 {
            openGuest = sharedMachines.machines[0]
        }
    }

    /// The Accept screen for an invite that arrived as a link, a paste or a scan.
    private func inviteAccept(_ invite: GuestInvite) -> some View {
        GuestAcceptView(
            invite: invite,
            fingerprint: try? GuestDevice.identity().fingerprint,
            accept: {
                let identity = try GuestDevice.identity()
                return try await GuestSession.accept(invite, identity: identity, device: UIDevice.current.model)
            },
            onAccepted: { access in
                sharedMachines.add(access)
                invites.pending = nil
                openGuest = access
            },
            onCancel: { invites.pending = nil })
    }

    /// Send the APNs token (with the current category prefs) to the server, if we have both a live
    /// client and a token. Idempotent + fire-and-forget — a server without the method just throws.
    /// The relay capability rides along when enrollment succeeded (usually from cache); without it
    /// the token is still registered, so a machine with its own APNs key keeps pushing.
    private func registerPush(with explicitClient: HerdrClient? = nil) {
        // Prefer the client the caller JUST built (connect/reconnect pass it in) over the @State
        // `client`, which the SwiftUI setter may not have published through yet on the same tick.
        guard let client = explicitClient ?? self.client, let token = push.deviceToken else { return }
        Task { @MainActor in
            let capability = await PushCenter.relay.capability(kind: .device, token: token)
            // Read the prefs AFTER enrolling (which can take up to its timeout), so a toggle
            // flipped meanwhile is not overwritten by this call's older snapshot.
            let p = PushCenter.Prefs.current
            let muted = Array(MuteStore.shared.mutedPanes)
            try? await client.registerDevice(token: token, needsInput: p.needsInput, dies: p.dies, finishes: p.finishes, gram: p.gram, mutedPanes: muted, relayCapability: capability)
        }
    }

    /// Register the current Live Activity push token with the server, if we have both a live client
    /// and a token. Idempotent + best-effort — mirrors registerPush; a server without the method
    /// just throws, and the widget still updates in the foreground.
    private func registerActivityPush(with explicitClient: HerdrClient? = nil) {
        guard let client = explicitClient ?? self.client, let token = liveActivity.pushToken else { return }
        Task {
            let capability = await PushCenter.relay.capability(kind: .activity, token: token)
            try? await client.registerActivity(token: token, relayCapability: capability)
        }
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
        case .resize, .control:
            TerminalInteractionRoot(control: mode == .control)
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
        case .sessions:
            TerminalHomeView(client: HerdrClient(transport: SessionsMockTransport()), onDisconnect: {},
                             session: "work", onTrustHostKey: { _ in false },
                             livePaneIDs: MockTransport.demoLivePaneIDs)
        case .liveEvents, .liveEventsLegacy:
            // The live status stream receipt: `liveevents` is an events_v2 daemon whose
            // rows change only through streamed events, `liveevents-legacy` an older
            // daemon that must keep the 5 s agent.list poll.
            LiveEventsHarness(driver: LiveEventsDriver.shared)
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
        case .share:
            GuestShareMock.paneView()
        case .sharedAccess:
            GuestShareMock.settingsView()
        case .htmlPreview:
            HtmlPreviewHarness()
        case .widgets:
            WidgetGallery()
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
        case .busyScroll:
            // A REAL SwiftTerm pane that keeps RECEIVING OUTPUT, so auto-follow writes
            // contentOffset continuously. The receipt is the INVERSE of the scroll-tap guard:
            // on a pane merely following output, a tap MUST still take focus. Review found
            // that recording every contentOffset write suppressed exactly this case — the
            // common one while an agent is working.
            NavigationStack {
                TerminalPaneContent(client: HerdrClient(transport: MockTransport(scrollback: true, busyOutput: true)),
                                 paneID: "w1:p1", title: "busytest",
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
            // The Gram page over a mock that answers gram.list with a canned owner view. The
            // harness owns the Inbox/Saved binding (see GramScreenshotHarness); the messages +
            // claim states are the FYI.
            GramScreenshotHarness(client: mockClient)
        case .guestAccept:
            // Accept is injected: it returns the mock share without touching the network,
            // then lands on guest home exactly like a live accept.
            if let openGuest {
                mockGuestHome(openGuest, initialTab: .agents)
            } else {
                GuestAcceptView(
                    invite: GuestMockTransport.invite,
                    fingerprint: try? GuestDevice.identity().fingerprint,
                    accept: { GuestMockTransport.access },
                    onAccepted: { access in
                        sharedMachines.add(access)
                        openGuest = access
                    },
                    onCancel: {})
            }
        case .guest, .guestSettings:
            // After Leave the in-memory store is empty and the phone is back on onboarding.
            if let access = sharedMachines.machines.first {
                mockGuestHome(access, initialTab: mode == .guestSettings ? .settings : .agents)
            } else {
                ConnectView { _ in }
            }
        case .guestPane, .guestPaused, .guestBlocked, .guestOldHost:
            GuestPaneMockHost(
                scenario: mode == .guestPaused ? .paused : mode == .guestBlocked ? .blocked
                    : mode == .guestOldHost ? .oldHost : .running)
        }
    }

    /// Guest home over the mock relay: the running scenario, whose agent.list also
    /// carries an agent that was not shared, which the home must not show.
    private func mockGuestHome(_ access: GuestAccess, initialTab: GuestHomeView.Tab) -> some View {
        GuestHomeView(
            access: access,
            connect: {
                let features = GuestFeaturesModel()
                return GuestConnection(
                    client: HerdrClient(transport: GuestMockTransport(scenario: .running, onFeatures: features.sink())),
                    fingerprint: try GuestDevice.identity().fingerprint, features: features)
            },
            initialTab: initialTab,
            onBack: nil,
            onLeave: { openGuest = nil })
    }
    #endif

    /// The saved host's NICKNAME when there is one (falling back to the raw host/IP), so the
    /// lock screen and guest invites read "My Mac" rather than an address. Match the saved
    /// record the SAME way connect-from-saved does (HostEndpoint.parse): `saved.host` may be
    /// "host:port" while `creds.host`/`creds.port` are already parsed apart, so a raw string
    /// compare would miss any host saved with an explicit port.
    private static func hostLabel(for creds: SSHCredentials) -> String {
        let saved = SavedHostsStore.shared.hosts.first { saved in
            guard let ep = HostEndpoint.parse(saved.host) else { return false }
            return ep.host == creds.host && ep.port == creds.port && saved.username == creds.username
        }
        return saved?.label ?? creds.host
    }

    private func connect(_ picked: SSHCredentials) {
        // Reopen the herdr session last picked on this machine (#347). If it has stopped
        // since, the home view's session check switches back to the default one.
        var creds = picked
        if creds.session == nil { creds.session = SessionChoice.remembered(for: creds) }
        let newTransport = CitadelTransport(credentials: creds, hostKeyPolicy: pins)
        let newClient = HerdrClient(transport: newTransport)
        credentials = creds
        transport = newTransport
        client = newClient
        // Bring up the session Live Activity (#90) in a "connecting" state; the home
        // view's onChange pushes real agent status the moment the first list arrives.
        LiveActivityController.shared.start(hostLabel: Self.hostLabel(for: creds), state: LiveActivityController.connecting)
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
        // Downloaded gram files are readable without a connection, so they must not
        // survive the session that fetched them.
        GramView.Downloads.invalidate()
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

    /// Moves the app to another herdr session on the same machine (#347): each session is
    /// its own herdr server, so this is a reconnect with the new session, which rebuilds
    /// the client and remounts the home (agents, terminals, Gram) for that server.
    /// nil is the default session. Remembered per machine for the next connect.
    private func switchSession(to name: String?) {
        guard var creds = credentials else { return }
        let next = (name == "default") ? nil : name
        guard creds.session != next else { return }
        creds.session = next
        credentials = creds
        SessionChoice.remember(next, for: creds)
        reconnect()
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
    /// Opens the home of a machine someone shared with this phone.
    var onOpenShared: (GuestAccess) -> Void = { _ in }

    @ObservedObject private var savedHosts = SavedHostsStore.shared
    @ObservedObject private var sharedMachines = SharedMachinesStore.shared
    /// The invite-code scanner (guest access, #312), and what it read: handed to the
    /// router once the sheet is gone, so the Accept cover never races its dismissal.
    @State private var showingInviteScan = false
    @State private var scannedInvite: GuestInvite?
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
                VStack(spacing: 18) {
                    header
                    // Saved machines — the list you manage + tap to connect. Empty on
                    // first launch, where the Add button below is the way in.
                    if savedHosts.hosts.isEmpty {
                        emptyState
                    } else {
                        savedHostsSection
                    }
                    if !sharedMachines.machines.isEmpty {
                        sharedSection
                    }
                    // Scanning is the PRIMARY action and manual entry the fallback, not
                    // the other way round. The manual path asks for a host address, a
                    // username and an ed25519 private key — three things a new user does
                    // not have and cannot be expected to produce from this screen.
                    scanButton
                    addHostButton
                    captions
                    inviteEntry
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
        .sheet(isPresented: $showingInviteScan, onDismiss: {
            guard let invite = scannedInvite else { return }
            scannedInvite = nil
            GuestInviteRouter.shared.pending = PendingGuestInvite(invite: invite)
        }) {
            GuestInviteScanSheet { scannedInvite = $0 }
        }
    }

    /// Machines other people shared: each opens its guest home over the relay.
    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectSectionLabel("SHARED WITH YOU")
            VStack(spacing: 0) {
                ForEach(Array(sharedMachines.machines.enumerated()), id: \.element.id) { index, access in
                    if index > 0 { connectRowDivider }
                    Button { onOpenShared(access) } label: {
                        connectRow(icon: "person.2", title: access.machineLabel,
                                   subtitle: "\(access.agentName) · shared by \(access.ownerName)")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shared-machine-row")
                    .contextMenu {
                        Button(role: .destructive) { sharedMachines.remove(access) } label: {
                            Label("Leave share", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .settingsGroup()
        }
    }

    // MARK: #374 inset groups (the Settings look of #357)

    /// A section label above a group: today's uppercase label, inset 18 pt to line up with the
    /// rows' leading glyph (as Settings' labels do), no rule.
    private func connectSectionLabel(_ text: String) -> some View {
        Text(text).font(Typography.microLabel).tracking(1.4).foregroundStyle(Palette.textFaint)
            .padding(.horizontal, 18)
    }

    /// One machine row inside a group: plain glyph, name over the second line, chevron.
    private func connectRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular)).foregroundStyle(Palette.textDim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.app(17)).foregroundStyle(Palette.text).lineLimit(1)
                Text(subtitle).font(Typography.machine(13)).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textFaint)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Between rows of a group; starts where the row text starts (18 + 22 + 14).
    private var connectRowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 54)
    }

    /// Someone shared an agent: open their invite link. The system PasteButton reads
    /// the clipboard only when tapped, so there is no "Allow Paste" prompt (see
    /// HostEditor); scanning covers an invite shown as a QR code.
    private var inviteEntry: some View {
        VStack(spacing: 10) {
            Text("Got an invite link from someone?")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { items in
                    Task { @MainActor in
                        if let text = items.first { GuestInviteRouter.shared.open(text) }
                    }
                }
                .labelStyle(.titleAndIcon)
                .tint(Palette.surfaceRaised)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityLabel("Paste invite link")
                Button { showingInviteScan = true } label: {
                    Label("Scan invite", systemImage: "qrcode.viewfinder")
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(Palette.surface, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var scanButton: some View {
        Button { showingPairing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 16, weight: .semibold))
                Text("Scan pairing code").font(Typography.app(16, .semibold))
            }
            .foregroundStyle(Palette.ground)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.text, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // Identity header (#374): the app logo (the Lamb) above a large left-aligned name and one
    // line of intent. The icon carries its own dark ground, so it reads as the app mark.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("herdrup")
                    .font(Typography.app(34, .bold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("connect to your machine")
                    .font(Typography.machine(13))
                    .foregroundStyle(Palette.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 6)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("herdrup controls coding agents running on your computer.")
                .font(Typography.app(17, .semibold)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)

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
            .padding(.horizontal, 18).padding(.vertical, 14)
            .settingsGroup()

            Text("Then, on your computer, run:")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)

            VStack(spacing: 8) {
                monoCard(HerdrSetup.installCommand)
                Text("then").font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                monoCard(HerdrSetup.pairCommand)
            }

            Text("Scan the code it prints and you're connected. No keys to copy.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
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
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairlineQuiet, lineWidth: 1))
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
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.surface, in: Capsule())
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
            connectSectionLabel("SAVED")
            VStack(spacing: 0) {
                ForEach(Array(savedHosts.hosts.enumerated()), id: \.element.id) { index, saved in
                    if index > 0 { connectRowDivider }
                    savedHostRow(saved)
                }
            }
            .settingsGroup()
        }
    }

    private func savedHostRow(_ saved: SavedHost) -> some View {
        Button { tapSavedHost(saved) } label: {
            connectRow(icon: "desktopcomputer", title: saved.label, subtitle: secondaryLine(saved))
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

/// Non-observable bookkeeping for the home list's live status stream. Events arrive
/// several times a second across a fleet; none of this may invalidate SwiftUI by
/// itself. Only a patched roster, published through `receiveRoster`, redraws.
private final class AgentRosterLiveEventsBuffer {
    /// Updates received while loads were in flight, replayed onto their snapshots.
    var ledger = AgentLiveUpdateLedger()
    /// An acknowledged stream is open; the 5 s poll relaxes to the backstop.
    var streaming = false
    /// The daemon refused the all-panes request despite advertising `events_v2`.
    /// Sticky for this connection so a later `agent.list` cannot re-enable it.
    var refused = false
    /// When the poll re-fetches while `streaming`: only loads that published count.
    var backstop = AgentListBackstop()
    /// Reloads asked for by events naming an agent pane the list does not show.
    var unlistedReloads = UnlistedPaneReloads()
    /// One coalesced event-driven reload at a time; `reloadAgain` queues exactly one more.
    var reloadTask: Task<Void, Never>?
    var reloadAgain = false

    deinit { reloadTask?.cancel() }
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
/// The sidebar section bar's material: Apple's Liquid Glass where the system has it (iPadOS 26,
/// and macOS 26 for the iPad app on Mac), the frosted bar of #369 before that.
private struct SidebarTabBarMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(Palette.surfaceRaised.opacity(0.72), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 15, y: 6)
        }
    }
}

struct TerminalHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    let client: HerdrClient
    var onDisconnect: () -> Void
    var host: String = ""   // shown in the Settings sheet's connection row
    /// Canonical `host:port` key that scopes saved terminals to THIS connection (a terminal is a pane
    /// on one daemon). Empty only in the DEBUG mock, which has no real terminals.
    var hostKey: String = ""
    /// The herdr session this home shows (#347); nil is the default session.
    var session: String? = nil
    /// Switch the app to another herdr session on this machine (nil = default).
    var onSwitchSession: (String?) -> Void = { _ in }
    var onReconnect: () -> Void = {}
    var onTrustHostKey: (String) -> Bool
    /// The set of panes herdr still lists; anything absent is `stopped`. `nil`
    /// means no census is available yet (the live default) — every agent is
    /// treated as live, the only safe reading. The DEBUG mock passes one so the
    /// stopped section has something to show.
    var livePaneIDs: Set<String>? = nil

    /// How often the connected agent list is re-fetched to stay live. Five seconds is
    /// the production default, and the cadence whenever no live status stream is open
    /// (an older daemon, or between reconnects). The DEBUG scroll-stress harness
    /// injects a shorter value so one UI test crosses many refresh boundaries without
    /// becoming a minute-long wall-clock test.
    var agentListPollIntervalNanoseconds: UInt64 = 5_000_000_000
    /// While an acknowledged `events_v2` status stream is open, rows update from its
    /// events and the list is re-fetched only this often, as a backstop for anything
    /// the stream cannot express.
    var agentListBackstopIntervalNanoseconds: UInt64 = 30_000_000_000
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
    @State private var liveEvents = AgentRosterLiveEventsBuffer()
    /// The daemon advertises `events_v2` (from `agent.list` `origin_capabilities`, or
    /// `ping` on a daemon without that field). Observable because it keys the stream
    /// task; it changes at most once or twice per connection.
    @State private var liveEventsSupported = false
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
    /// An installed, compatible binary whose API daemon/socket is not responding
    /// needs start/check guidance, not another install.
    @State private var unavailableDaemonHost: String?
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
    /// BORN IN THE FINAL CONFIGURATION, not flipped after the first layout pass.
    ///
    /// This was `.all` unconditionally, with `.onChange(of: sidebarMinimized, initial: true)`
    /// flipping it to `.detailOnly` for an owner whose stored preference is "minimised".
    ///
    /// WHEN that flip landed relative to the split view's first layout pass is NOT
    /// established. Apple documents `initial:` only as "whether the action should be run
    /// when this view initially appears", with no ordering guarantee against the layout
    /// phase and no definition of "initially appears" in those terms. So on one reading
    /// this removes a real layout pass in a configuration about to be left, and on the
    /// other it is a no-op. I cannot tell which from the documentation, and nothing here
    /// measures it.
    ///
    /// NOT A DIAGNOSIS OF ANY REPORTED BUG. An earlier version of this comment claimed
    /// that pre-flip pass WAS the owner's "sometimes, for no reason" symptom. There is no
    /// reproduction of that anywhere, no instrument in the repo that could produce one,
    /// and no mechanism I can point to in the code: flipping `columnVisibility` re-lays
    /// the split view out with fresh proposals, and nothing caches a page width across
    /// it. The claim also contradicted this same file, which records the symptom as
    /// undiagnosed. It was a fifth guess written as a fact, and it is withdrawn.
    ///
    /// What is left as justification is therefore only this, and it does not depend on
    /// the ordering: the state is born in the configuration the preference already names,
    /// so there is one fewer launch-time transition to reason about and no window in
    /// which `columnVisibility` and `sidebarMinimized` disagree. If the flip in fact
    /// landed before first layout, this change costs nothing and buys that; it is not
    /// offered as a fix for anything.
    ///
    /// Read straight from `UserDefaults` because `@AppStorage` is not available during
    /// property initialisation ("cannot use instance member within property
    /// initializer"). Both readers name `Self.sidebarMinimizedKey` so a rename cannot
    /// desync them — and the desync would be SILENT, since the layout would simply be
    /// born expanded while the preference said otherwise.
    private static let sidebarMinimizedKey = "ui.sidebarMinimized"
    @State private var columnVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: Self.sidebarMinimizedKey) ? .detailOnly : .all
    /// Whether the sidebar is MINIMISED to the icon rail, remembered across launches.
    ///
    /// There is deliberately no fully-hidden state. Hiding the column outright loses
    /// the section badges and the activity counts and leaves nothing to click, so the
    /// only way back was ⌘K on a hardware keyboard; the rail keeps a compact signal
    /// and a one-click way back, which makes a third state pure surface area.
    ///
    /// Persisted because `columnVisibility` is `@State`: on its own the choice lasts
    /// only until relaunch, which is wrong for a preference set deliberately to give
    /// the terminal full width.
    @AppStorage(Self.sidebarMinimizedKey) private var sidebarMinimized = false
    /// The sidebar's width, remembered across launches.
    ///
    /// `navigationSplitViewColumnWidth` takes an `ideal` but reports nothing back, and
    /// there is no SwiftUI hook for "the user dragged the divider" — so the column
    /// measures itself (see `iPadLayout`) and the settled value is stored here.
    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = 320
    /// The column's last MEASURED width, pre-persistence. Debounced into `sidebarWidth`
    /// so a transient layout value cannot become the stored preference (it would also
    /// become the new `ideal`, which is what makes a bad sample stick).
    @State private var measuredSidebarWidth: CGFloat = 0
    /// When `measuredSidebarWidth` last changed. The pre-collapse commit in
    /// `toggleSidebar` bypasses the debounce, so it needs its own way to tell a width
    /// the owner settled on from one the split view is sweeping through.
    @State private var measuredSidebarWidthAt = Date.distantPast
    /// How still a measurement must be for the PRE-COLLAPSE commit to trust it.
    ///
    /// During the split view's own column animation a new sample arrives roughly every
    /// frame (~16ms); after a divider drag the owner still has to reach the toggle,
    /// which takes far longer. 50ms separates those two cases cleanly, and unlike
    /// `sidebarWidthSettle` this is not a wait — it is a freshness test on a value
    /// that already exists.
    private static let sidebarWidthStillFor: TimeInterval = 0.05
    /// How long a measured width must hold still before it is persisted. Comfortably
    /// longer than the split view's own column animation, so a minimise/expand sweep
    /// commits once, at the width it ended on.
    private static let sidebarWidthSettle: UInt64 = 500_000_000
    /// The bounds the modifier enforces. Kept as one constant so the stored width, the
    /// clamp and the modifier cannot drift apart.
    private static let sidebarWidthRange: ClosedRange<CGFloat> = 250...460
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
    /// Gram's Inbox/Saved selection, owned HERE rather than inside `GramView` because on regular
    /// width the selector is rendered in the split view's sidebar — a sibling column of the page
    /// it drives. Shared by both layouts, so the phone's header toggle and the sidebar rows read
    /// and write the same value.
    @State private var gramShowingSaved = false
    /// One-shot signal for the sidebar's refresh button. A sidebar button cannot call `GramView`'s
    /// async `load`, so it bumps this and the page's `onChange` performs the reload.
    @State private var gramRefreshToken = 0
    /// One-shot signal for the sidebar's Read-all button, same reason as `gramRefreshToken`:
    /// a sidebar button cannot call `GramView`'s async mark-read pass directly.
    @State private var gramReadAllToken = 0
    /// Observed, not read statically: the Gram sidebar shows the Saved count as a badge, and
    /// `SavedGramStore.shared.saved.count` read directly would only refresh when some unrelated
    /// state re-rendered this view — so saving or removing a gram would leave a stale number.
    @ObservedObject private var savedGrams = SavedGramStore.shared
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
    ///
    /// ONE definition of the sections (#360): the iPhone `TabView`, the iPad/Mac sidebar
    /// bar and the minimised rail all read label and icon from here, so they cannot drift.
    private enum HomeTab: Hashable, CaseIterable {
        case agents, gram, settings

        var label: String {
            switch self {
            case .agents: return "Agents"
            case .gram: return "Gram"
            case .settings: return "Settings"
            }
        }

        /// The SF Symbol. A system tab bar draws the `.fill` variant; the sidebar bar does
        /// the same explicitly with `.environment(\.symbolVariants, .fill)`.
        var icon: String {
            switch self {
            case .agents: return "square.grid.2x2"
            case .gram: return "bubble.left.and.bubble.right"
            case .settings: return "gearshape"
            }
        }
    }

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
    /// The roster's large "Agents" title has scrolled out of view, so the header shows its
    /// small centred title instead (#353).
    @State private var agentsTitleCollapsed = false
    /// The sidebar section bar's selected pill, shared so it slides between tabs.
    @Namespace private var sidebarTabSelection
    /// The machine's running herdr sessions (#347); the pills show with two or more.
    @State private var runningSessions: [HerdrSession] = []
    /// Needs-you counts in the sessions this home is NOT on, by session name.
    @State private var otherSessionsNeedYou: [String: Int] = [:]

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
                // The raw name still carries the peer's alias; keep searching it so
                // typing a profile id (or the alias shown before labels landed)
                // still finds that machine's agents.
                || ($0.name ?? "").localizedCaseInsensitiveContains(search)
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
                    sidebarTopRow
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
                    case .gram:
                        // Gram's Inbox/Saved selector belongs in THIS column, beside the section
                        // picker, the same way the agents list does. It used to render an empty
                        // Spacer() here while GramView drew its own 260pt rail in the detail
                        // pane, which put two sidebars on screen — one of them blank.
                        gramSidebar
                    }
                }
                // #360: the sections live in the iPhone tab bar's shape at the bottom of the
                // column. A safe-area inset (not an overlay) so the lists end above it and
                // can still scroll their last row into view.
                .safeAreaInset(edge: .bottom, spacing: 0) { sidebarTabBar }
            }
            // Remembered width. SwiftUI exposes no way to READ a divider drag, so the
            // column measures itself and feeds the settled value back as `ideal` on the
            // next launch. Clamped to the same min/max the modifier enforces, so a
            // stored value can never put the sidebar outside its own bounds.
            //
            // DEBOUNCED, because the stored value also drives `ideal` below and that
            // makes an intermediate measurement SELF-FULFILLING: persist 250 mid-sweep
            // and `ideal` retargets to 250, so the column settles at a width the owner
            // never chose and every later launch opens there. The measurement lands in
            // `@State` immediately (cheap, no persistence) and only reaches `AppStorage`
            // once it has stopped moving for `sidebarWidthSettle`.
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                        measuredSidebarWidth = width
                        measuredSidebarWidthAt = Date()
                    }
                }
            }
            // `task(id:)` IS the debounce: a new measurement cancels the pending commit
            // and restarts the wait, so only a width that survives the interval is kept.
            .task(id: measuredSidebarWidth) {
                try? await Task.sleep(nanoseconds: Self.sidebarWidthSettle)
                guard !Task.isCancelled else { return }
                recordSidebarWidth(measuredSidebarWidth)
            }
            .navigationSplitViewColumnWidth(
                min: Self.sidebarWidthRange.lowerBound,
                ideal: sidebarWidth,
                max: Self.sidebarWidthRange.upperBound)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            // THE RAIL STAYS AN HSTACK SIBLING, and the inset I tried is withdrawn too.
            //
            // I replaced this with `detailColumn.safeAreaInset(edge: .leading)` on the
            // theory that an inset CHANGE re-proposes the inset region while a sibling
            // insertion does not. Review held the two against the documented contract:
            // in steady state both inset the column by the rail's 64pt, so the content
            // width is identical before and after, and the entire bet rested on an
            // undocumented re-proposal property. If a stale proposal exists it comes
            // from the split view's own animated column width, which NEITHER form
            // influences. It also carried a real regression risk on this exact surface:
            // `safeAreaInset` takes a vertical alignment, which only means anything if
            // the content is not stretched to the container's height — so `sidebarRail`'s
            // `Spacer()` greed could collapse into a short, vertically centred block,
            // and `groundMachine.ignoresSafeArea()` would then bleed under the leading
            // 64pt as a dark strip above and below it.
            //
            // So this PR changes NO layout. Four guesses at the owner's geometry have been
            // refuted: a GramView anchor, a ZStack anchor, a detail frame, and this inset.
            //
            // AND IT SHIPS NO TEST EITHER. An iPad guard was carried by five reviewed heads,
            // with a sixth round reviewing its removal, because after each fix its defect only
            // moved rather than disappearing: the waiter
            // asserted on the same axis as the assertion; the wall-clock floor that
            // replaced it could return a pre-collapse rect and fail a CORRECT layout with
            // a message byte-identical to the true finding, so a red run could not be told
            // from a flake; and nothing re-checked the row existed before measuring it.
            // That last one I could only half establish, and the half I could not is the
            // point: the predicates were verified to BOTH pass on a zero rect, so IF an
            // unresolved query returns `CGRect.zero` a blank detail column greened the
            // case — but XCUITest's documented behaviour there is unspecified, it may
            // instead raise, and no run ever settled it. Untrustworthy either way, which
            // is enough. The owner has since confirmed the symptom does not occur on
            // iPad and can no longer reproduce it on the Mac, so the guard could not have
            // seen its target either way. If it returns, the instrument is a TestFlight
            // build and the owner's account of what preceded it, not another commit here.
            HStack(spacing: 0) {
                // Keyed on `columnVisibility`, the LAYOUT TRUTH, not on the persisted
                // preference: iPadOS collapses this column on its own (rotation, Stage
                // Manager, any transition it cannot honour at `.balanced`), and when it
                // does, the rail must still appear or there is no way back at all.
                //
                // No transition: a sliding rail animates the detail column's width, and
                // every intermediate width reflows the live terminal (see `toggleSidebar`).
                if columnVisibility == .detailOnly { sidebarRail }
                detailColumn
            }
            // NO SIZE CONTRACT IS ADDED HERE, AND THE ONE I TRIED IS WITHDRAWN.
            //
            // It was `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`,
            // on the theory that an undersized page was being centre-placed by the split
            // view. Review refuted the premise with the code: `detailColumn`'s ZStack has
            // `Palette.groundMachine.ignoresSafeArea()` as its first child, and that is a
            // `Color` (DesignSystem.swift:21) — no intrinsic size, accepts any finite
            // proposal — so the ZStack already fills, and a flexible frame cannot enlarge
            // a child that is not small. Inert. The same premise was refuted once before,
            // at #268, when I put the modifier one level lower.
            //
            // I also claimed here that it was WORSE than inert in the overflow case, by
            // clamping the reported size and sending the whole excess off the bottom. That
            // was wrong, and the rule I asserted does not exist. Apple's contract for
            // `frame(minWidth:...maxHeight:alignment:)` adopts the proposal unconditionally
            // only when BOTH constraints are given in a dimension. With a MAXIMUM only, it
            // reports "the proposed size, clamped to that maximum" when the proposal
            // exceeds the child, and "the size of this view" otherwise. The maximum here
            // was `.infinity`, for which that clamp is the identity — so for THIS modifier
            // an overflowing child was reported at its own oversized size and placed as
            // before. Inert there too, not harmful. (State the clamp when quoting the rule
            // generally: at a finite maximum it does bound the result.)
            //
            // So the vertical half of the owner's report is UNDIAGNOSED and unmeasured,
            // deliberately: four diagnoses were refuted and the instrument built to tell
            // them apart false-failed on correct layouts, so it was removed rather than
            // recalibrated a fourth time.
            .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        // The split's own sidebar carries the FULL list; minimising hides that column and
        // hands its job to the rail.
        //
        // ONE-WAY on purpose. The preference -> layout edge restores the owner's choice at
        // launch. The reverse edge (layout -> preference) is deliberately absent: this
        // binding is written by iPadOS itself, and a handler cannot tell an owner gesture
        // from a system layout decision. Persisting the latter meant one system collapse
        // (a rotation, a Stage Manager resize) silently rewrote a durable preference, and
        // since only an explicit expand clears it, the app would then open on the rail
        // forever with no record that the owner ever asked for it. `sidebarMinimized` is
        // now written ONLY by `toggleSidebar` and `railSectionButton` - real gestures.
        // `initial: true` IS LOAD-BEARING and was wrongly removed for one round.
        //
        // The initialiser above runs once per view LIFETIME; this handler re-fires on
        // every REMOUNT. `iPadLayout` unmounts and remounts across compact<->regular
        // transitions (Stage Manager, a window resize), while `columnVisibility` is
        // `@State` on `TerminalHomeView`, whose identity survives them. Because the
        // layout -> preference edge is deliberately absent, an iPadOS-initiated collapse
        // leaves `columnVisibility == .detailOnly` with `sidebarMinimized == false`; this
        // handler is what re-applied the real preference on reappearance and self-healed
        // it. Without it, a system collapse STICKS until an explicit ⌘K or rail tap.
        //
        // It is not redundant with the initialiser and it is not merely "for later
        // preference changes": both in-scene writers (`toggleSidebar`, `railSectionButton`)
        // set `columnVisibility` themselves in the same transaction, so a same-value
        // re-apply is all this can ever do for a gesture. Its real job is the remount.
        .onChange(of: sidebarMinimized, initial: true) { _, minimized in
            columnVisibility = minimized ? .detailOnly : .all
        }
        .tint(Palette.brand)
        // Hardware-keyboard shortcuts (iPad): ⌘K minimises/expands the sidebar, ⌘/ opens the
        // shortcut reference. Hidden zero-size buttons carry the key bindings.
        .background { keyboardShortcuts }
        .sheet(isPresented: $showShortcuts) {
            ShortcutsSheet(onClose: { showShortcuts = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        )
    }

    /// The detail column's content, factored out so the rail can sit beside it.
    private var detailColumn: some View {
        ZStack(alignment: .topLeading) {
                Palette.groundMachine.ignoresSafeArea()
                // Base layer: the switch renders Gram / Settings and the agents placeholder.
                // The terminal container is deliberately NOT in here — it is the
                // always-mounted overlay below.
                switch selectedTab {
                case .agents:
                    if frontID == nil {
                        detailPlaceholder("Select an agent", "square.grid.2x2")
                    }
                case .gram:
                    GramView(client: client, agents: agents, unread: gramUnread,
                             showingSaved: $gramShowingSaved,
                             refreshToken: gramRefreshToken,
                             readAllToken: gramReadAllToken)
                case .settings:
                    SettingsView(
                        client: client,
                        agents: agents,
                        host: host,
                        connected: error == nil && !loading,
                        canReconnect: rejectedFingerprint == nil,
                        onReconnect: onReconnect,
                        detail: settingsAnchor ?? .machines)
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
    }

    /// Zero-opacity buttons that exist only to register ⌘K / ⌘/ with the responder chain.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Toggle sidebar") { toggleSidebar() }
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
            ForEach([SettingsSection.about, .machines, .accounts, .notifications, .sharedAccess, .appearance], id: \.self) { section in
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

    /// Gram's sidebar column: a header matching the agents header's shape (title, one-number
    /// subtitle, a trailing circle action) over the two "conversations" this channel has.
    ///
    /// This is the SAME column the agents list uses. Gram previously drew its own rail inside the
    /// detail pane while this column rendered a blank `Spacer()`, so the reader saw two sidebars
    /// and the left one was empty. Selecting a row writes `gramShowingSaved`, which the page
    /// reads as a binding, so the detail pane's content swaps in place with no navigation.
    private var gramSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // #355: the phone header's shape — a large left-aligned title with the amber unread
            // count, and the actions in one capsule. No subtitle line: the count carries it.
            HStack(alignment: .center, spacing: 8) {
                Text("Gram").font(Typography.app(34, .bold)).foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if gramUnread.count > 0 {
                    Text("\(gramUnread.count)")
                        .font(Typography.machine(11, .semibold))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.waiting))
                        .accessibilityLabel("\(gramUnread.count) unread")
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    // Read all, beside refresh. Gated exactly like the phone header's copy: only
                    // on the Inbox (Saved has no unread concept, so it would be a no-op control
                    // there) and only while something is unread. The count comes from the ambient
                    // poll this view already owns, so the button needs nothing from the page.
                    if !gramShowingSaved, gramUnread.count > 0 {
                        gramHeaderButton("envelope.open") { gramReadAllToken += 1 }
                            .accessibilityLabel("Read all")
                    }
                    gramHeaderButton("arrow.clockwise") { gramRefreshToken += 1 }
                        .accessibilityLabel("Refresh")
                }
                .padding(.horizontal, 2)
                .background(Capsule().fill(Palette.surfaceRaised))
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            Divider().overlay(Palette.hairlineQuiet)
            VStack(spacing: 4) {
                gramSidebarRow(title: "Inbox", icon: "tray", selected: !gramShowingSaved,
                               badge: gramUnread.count) { gramShowingSaved = false }
                gramSidebarRow(title: "Saved", icon: "bookmark", selected: gramShowingSaved,
                               badge: savedGrams.saved.count,
                               badgeMuted: true) { gramShowingSaved = true }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One segment of the Gram sidebar header's capsule: a 40 x 44 glyph target.
    private func gramHeaderButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// One selectable row in the Gram sidebar. `badgeMuted` renders the count as a quiet pill
    /// (Saved) rather than the attention-coloured unread pill (Inbox).
    private func gramSidebarRow(title: String, icon: String, selected: Bool, badge: Int,
                                badgeMuted: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected && icon == "bookmark" ? "bookmark.fill" : icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Palette.brand : Palette.textDim)
                    .frame(width: 20)
                Text(title)
                    .font(Typography.app(15, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.textDim)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(Typography.machine(11, .semibold))
                        .foregroundStyle(badgeMuted ? Palette.textDim : Palette.ground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeMuted ? Palette.surfaceRaised : Palette.waiting))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Palette.surfaceRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// The sidebar's top row (#360): only the minimise toggle, now that the sections moved to
    /// the bar at the bottom. Leading, where the system puts a sidebar toggle.
    private var sidebarTopRow: some View {
        HStack {
            sidebarToggleButton(
                icon: "sidebar.leading", hint: "Minimise sidebar (⌘K)", minimize: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    /// The sections as the iPhone tab bar, at the bottom of the sidebar (#360): the same
    /// items, `.fill` symbols, 10 pt labels, white selected tab (`.tint(Palette.text)` on
    /// iPhone) and the system red Gram count. iPadOS has no system tab bar inside a split
    /// view's sidebar column, so it is drawn to the iPhone bar's metrics: 62 pt tall,
    /// 31 pt corners, 14 pt from the column's sides.
    ///
    /// Liquid Glass (owner 2026-10-05): on iPadOS 26 / macOS 26 the bar is Apple's own glass,
    /// the same material as the iPhone tab bar, and the selected pill slides between tabs.
    /// The list scrolls underneath (the bar is a safe-area inset), which is what the glass
    /// shows. Earlier systems keep the frosted bar. It follows the sidebar's width but never
    /// grows past `sidebarTabBarMaxWidth`, centred, so a wide sidebar doesn't stretch it.
    private var sidebarTabBar: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                sidebarTabItem(tab, badge: tab == .gram ? gramUnread.count : 0)
            }
        }
        .animation(.smooth(duration: 0.3), value: selectedTab)
        .padding(4)
        .frame(height: 62)
        .modifier(SidebarTabBarMaterial())
        .frame(maxWidth: Self.sidebarTabBarMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
    }

    /// About three iPhone tab items wide; the sidebar ranges 250-460 pt.
    private static let sidebarTabBarMaxWidth: CGFloat = 320

    private func sidebarTabItem(_ tab: HomeTab, badge: Int) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            VStack(spacing: 1) {
                Image(systemName: tab.icon)
                    .environment(\.symbolVariants, .fill)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 28)
                    .overlay(alignment: .topTrailing) { tabBadge(badge).offset(x: 12, y: -3) }
                Text(tab.label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(selected ? Palette.text : Palette.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // One pill, moved between tabs, so a selection change slides instead of blinking.
                if selected {
                    Capsule().fill(Color.white.opacity(0.12))
                        .matchedGeometryEffect(id: "sidebar-tab-selection", in: sidebarTabSelection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(tab.label)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The system tab badge: a red capsule with the count, as `.badge` draws on iPhone.
    @ViewBuilder
    private func tabBadge(_ count: Int) -> some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color(uiColor: .systemRed)))
                .accessibilityHidden(true)
        }
    }

    /// The minimise / restore control. ⌘K was the only trigger before, bound to a
    /// zero-opacity button, and the navigation bar is hidden in both columns — so on
    /// an iPad without a hardware keyboard, or on the Mac build where a click is the
    /// expected gesture, there was nothing to hit. A 44 pt round button (#360).
    private func sidebarToggleButton(icon: String, hint: String, minimize: Bool) -> some View {
        Button { toggleSidebar() } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(minimize ? "Minimise sidebar" : "Expand sidebar")
        .accessibilityIdentifier("terminal-sidebar-toggle")
        .help(hint)
    }

    /// Records a measured sidebar width, ignoring anything that is not a real resize.
    ///
    /// Filters three cases that would corrupt the stored value: a column that is not
    /// actually open (it collapses toward zero), a width outside the modifier's own
    /// bounds (transient layout passes report those), and sub-point jitter, which would
    /// otherwise write to `AppStorage` on every layout.
    ///
    /// The first guard reads `columnVisibility`, the LAYOUT, not the persisted
    /// preference: after a layout-initiated collapse the preference still says
    /// "expanded", so guarding on it would admit the collapse sweep's own widths.
    private func recordSidebarWidth(_ width: CGFloat) {
        guard columnVisibility != .detailOnly else { return }
        guard Self.sidebarWidthRange.contains(width) else { return }
        guard abs(width - CGFloat(sidebarWidth)) >= 1 else { return }
        sidebarWidth = Double(width)
    }

    /// Minimises or expands the sidebar, WITHOUT animating it.
    ///
    /// An animated width change is not cosmetic here: the detail column holds a live
    /// terminal, and every intermediate width makes SwiftTerm reflow the grid and fire
    /// `sizeChanged` -> `sendPTYSize`, so one animated collapse costs dozens of
    /// reflows and a `set_pty_size` round-trip for each distinct width. That is the
    /// visible re-scrolling/re-wrapping churn. One step = one reflow.
    ///
    /// Intent is read from the LAYOUT and both variables are written directly. Deriving
    /// it from the preference instead (`sidebarMinimized.toggle()`) desyncs the moment
    /// iPadOS collapses the column itself: the flag still says "expanded", so a tap
    /// meaning "expand" computed "minimise", the `onChange` re-applied the state the
    /// layout was already in, and the control did nothing — while persisting
    /// "minimised", which is the durable corruption removing the layout->preference
    /// edge was meant to prevent. Setting `columnVisibility` here rather than relying
    /// on the `onChange` is required: when the flag already equals the new value, that
    /// handler does not fire at all.
    private func toggleSidebar() {
        let minimize = columnVisibility != .detailOnly
        // Commit any pending measurement before collapsing: the debounce is 500ms, and
        // a drag followed straight away by a minimise would otherwise lose the width
        // the owner just chose. Runs while the column is still open, so the layout
        // guard in `recordSidebarWidth` passes.
        //
        // Only a STILL measurement, though. This path bypasses the debounce, and the
        // split view sweeps intermediate widths through `measuredSidebarWidth` during
        // its own ~0.3s column animation — so minimising again inside that window (⌘K
        // key repeat, an impatient double-tap) would otherwise persist a width the
        // owner never chose, and because the stored value feeds `ideal` the column
        // would then open there on every later launch. That is exactly the
        // self-fulfilling corruption the debounce exists to prevent, and bypassing it
        // must not reopen the hole.
        if minimize,
           Date().timeIntervalSince(measuredSidebarWidthAt) >= Self.sidebarWidthStillFor {
            recordSidebarWidth(measuredSidebarWidth)
        }
        sidebarMinimized = minimize
        columnVisibility = minimize ? .detailOnly : .all
    }

    /// The minimised sidebar: a 64pt icon rail that keeps the section badges and the
    /// activity counts visible and is one click from expanding.
    ///
    /// It lives in the DETAIL column rather than as a narrow sidebar column on
    /// purpose. `NavigationSplitView` enforces its own minimum sidebar width on iPad,
    /// so a 64pt column is not reliably honoured, and a control whose width the
    /// platform may override is not something to ship untested on a device. Rendering
    /// the rail ourselves is exact on both platforms.
    private var sidebarRail: some View {
        let activity = fullList.activityContent
        return VStack(spacing: 6) {
            sidebarToggleButton(
                icon: "sidebar.left", hint: "Expand sidebar (⌘K)", minimize: false)
                .padding(.bottom, 2)
            ForEach(HomeTab.allCases, id: \.self) { tab in
                railSectionButton(tab, badge: tab == .gram ? gramUnread.count : 0)
            }
            // Gated on the same condition as the counts below it: a separator with
            // nothing on its far side is precisely the zero-value noise those counts
            // are suppressed to avoid, and the quiet state is the COMMON rendering.
            if fullList.needsYouCount > 0 || activity.workingCount > 0 {
                Divider().overlay(Palette.hairlineQuiet)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            // The counts are the reason to minimise rather than hide. `needsYou` is the
            // ROSTER's STRICT count (`AgentList.needsYouCount`), deliberately NOT
            // `activityContent.needsYouCount`: that one folds `.unrecognised` rows into
            // the total for the section-less Live Activity, so it would print a BIGGER
            // number than the expanded list's NEEDS YOU section this rail stands in for.
            // One unrecognised agent and the two surfaces would disagree one click apart.
            //
            // The same fold is why the wording spec (`AgentList.needsYouSummary`) hedges
            // unrecognised agents as "N may need you": they are unconfirmed, not facts. A
            // bare number cannot carry that hedge, so the rail shows only what IS confirmed.
            railCount(fullList.needsYouCount, tone: Palette.waiting, label: "need you")
            railCount(activity.workingCount, tone: Palette.working, label: "working")
            Spacer()
        }
        .frame(width: 64)
        .padding(.top, 12)
        .background(Palette.ground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairlineQuiet).frame(width: 0.5).ignoresSafeArea()
        }
    }

    /// A rail section icon. Tapping selects the section AND expands, which is the
    /// predictable reading of a click on a minimised menu; the chevron above expands
    /// without changing section.
    private func railSectionButton(_ tab: HomeTab, badge: Int = 0) -> some View {
        Button {
            selectedTab = tab
            // Both variables, for the same reason `toggleSidebar` writes both: the rail
            // is only on screen when the LAYOUT is collapsed, which the preference may
            // not reflect, and `onChange` does not fire when the flag is already false.
            sidebarMinimized = false
            columnVisibility = .all      // unanimated: see `toggleSidebar`
        } label: {
            Image(systemName: tab.icon)
                .environment(\.symbolVariants, .fill)
                .font(.system(size: 18, weight: .medium))
                .overlay(alignment: .topTrailing) { tabBadge(badge).offset(x: 11, y: -6) }
                .foregroundStyle(selectedTab == tab ? Palette.text : Palette.textDim)
                .frame(width: 44, height: 40)
                .background(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear,
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(tab.label)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
    }

    /// One activity count. Rendered only when non-zero: a rail of zeroes is noise.
    @ViewBuilder
    private func railCount(_ count: Int, tone: Color, label: String) -> some View {
        if count > 0 {
            VStack(spacing: 2) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text("\(count)")
                    .font(Typography.machine(13, .semibold))
                    .foregroundStyle(Palette.text)
            }
            .frame(width: 40)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(label)")
        }
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
                    .tabItem { Label(HomeTab.agents.label, systemImage: HomeTab.agents.icon) }

                // Gram and Settings were modal covers; they are persistent tabs now.
                // Both are nav-agnostic and take no onClose as tabs (no close button).
                GramView(client: client, agents: agents, unread: gramUnread,
                         showingSaved: $gramShowingSaved)
                    .tag(HomeTab.gram)
                    .tabItem { Label(HomeTab.gram.label, systemImage: HomeTab.gram.icon) }
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
                    .tabItem { Label(HomeTab.settings.label, systemImage: HomeTab.settings.icon) }
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
        #if DEBUG
        .onAppear {
            guard ScreenshotMock.mode == .resize, slots.isEmpty else { return }
            let fixtures = TerminalInteractionHarness.agents
            for fixture in fixtures.reversed() {
                open(PaneSlot(paneID: fixture.paneID, title: fixture.displayName,
                              agent: fixture, initialReply: "", siblings: fixtures))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalInteractionHarness.navigateNotification)) { note in
            guard ScreenshotMock.mode == .resize else { return }
            if note.object as? String == "close" {
                if let frontID { slots.removeAll { $0.paneID == frontID } }
                frontID = slots.last?.paneID
            } else if let slot = slots.first(where: { $0.paneID != frontID }) {
                open(slot)
            }
        }
        #endif
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
        //
        // While the live status stream below is open, rows update from its events and
        // this loop only re-fetches once the backstop interval has passed since the
        // last load that published (event-driven reloads count; a failed load does
        // not, so the next tick retries it). The tick itself stays at the poll
        // interval, so a dropped stream falls back to the 5 s cadence on the next tick
        // rather than after a full backstop. Without the stream this is the plain
        // 5 s poll it always was.
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: agentListPollIntervalNanoseconds)
                if liveEvents.backstop.isDue(
                    streaming: liveEvents.streaming,
                    interval: .nanoseconds(Int64(agentListBackstopIntervalNanoseconds)),
                    now: .now) {
                    await load()
                }
                // EVERY POLL, not only on a change. Recovery after the reader swipes
                // the banner away cannot hang off `.onChange(of: fullList)` below: that
                // fires when the roster MOVES, which is exactly what a blocked agent
                // waiting for an answer does not do. `recoverIfEnded` mints only when
                // nothing is live and pushes no content otherwise, so a stable roster
                // costs one predicate per poll rather than an ActivityKit update.
                LiveActivityController.shared.recoverIfEnded(
                    LiveActivityController.state(from: fullList)
                )
            }
        }
        // The live status stream (herdr events v2): one all-panes `events.subscribe`
        // held while the app is not backgrounded and the daemon advertises
        // `events_v2`. Keyed on both, so backgrounding cancels the task, which closes
        // the SSH channel, and returning reopens it; leaving the view cancels it too.
        .task(id: liveEventsSupported && scenePhase != .background) {
            guard liveEventsSupported, scenePhase != .background else { return }
            await runLiveEvents()
        }
        // Ambient unread-gram poll for the tab badge, running ONLY while the Gram
        // tab is not showing — GramView keeps its own 6s poll while visible and
        // writes the count on load / mark-read. Keyed on selectedTab so it
        // restarts on tab change and idles on Gram: exactly one poller is live.
        .task(id: selectedTab) {
            guard selectedTab != .gram else { return }
            while !Task.isCancelled {
                // Unconditional on purpose: `unread_only` is a small answer already,
                // and this poller keeps no list to compare a digest against.
                if let count = try? await client.gramList(unreadOnly: true).messages?.count {
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
        // Legacy terminals predate sessions, so they belong to the default session's bucket.
        .task(id: hostKey) {
            if !hostKey.isEmpty, session == nil { terminalsStore.migrateLegacyIfNeeded(host: hostKey) }
        }
        .task { await watchSessions() }
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

    /// #353: a round Back button and New terminal / New agent in one capsule. The large
    /// "Agents" title lives at the top of the roster's scroll content (`rosterTitleBlock`) and
    /// scrolls away with it; once it has, a small centred title fades into this bar, as a
    /// system large title collapses. Without a roster on screen (first load, error) the bar
    /// keeps the large title itself. The old "N need you" subtitle is gone: the rows' amber
    /// marks and the minimised rail's counts carry it.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            circleButton("chevron.left") { onDisconnect() }
                .accessibilityLabel("Back")
            if !rosterShowsTitle {
                largeAgentsTitle
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                // Open a plain shell terminal — a small icon so agents stay the priority
                // (the re-entry guard in createTerminal absorbs an eager double-tap).
                capsuleButton("terminal") { Task { await createTerminal() } }
                    .accessibilityLabel("New terminal")
                capsuleButton("plus") { activeCover = .newAgent }
                    .accessibilityLabel("New agent")
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Palette.surfaceRaised))
        }
        .overlay {
            if rosterShowsTitle {
                let shown = agentsTitleCollapsed
                Text("Agents")
                    .font(Typography.app(17, .semibold))
                    .foregroundStyle(Palette.text)
                    .opacity(shown ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: shown)
                    .accessibilityHidden(!shown)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    private var largeAgentsTitle: some View {
        Text("Agents")
            .font(Typography.app(34, .bold))
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
    }

    /// Whether the roster (and with it the scrolling large title) is what's on screen.
    private var rosterShowsTitle: Bool {
        error == nil && !(loading && agents.isEmpty)
    }

    /// The top of the roster's scroll content: the large title, then the search field. Both
    /// scroll away with the list (#353); the title reports when it has left the viewport.
    private var rosterTitleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            largeAgentsTitle
                .padding(.horizontal, 16)
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 8 } action: {
                    agentsTitleCollapsed = $0
                }
                // A remounted roster starts at the top with the large title visible; reset
                // here so a stale "collapsed" never shows both titles before the first scroll.
                .onAppear { agentsTitleCollapsed = false }
            VStack(spacing: 0) {
                searchField
                if runningSessions.count >= 2 {
                    SessionPills(
                        sessions: runningSessions,
                        current: session,
                        needsYou: sessionNeedsYou,
                        onSelect: { onSwitchSession($0.default ? nil : $0.name) }
                    )
                    .padding(.top, 4).padding(.bottom, 6)
                }
            }
        }
    }

    /// Agents that need you in each running session, for the pills: this session's count
    /// is the live roster's; the others come from `watchSessions`' periodic peek.
    private var sessionNeedsYou: [String: Int] {
        var counts = otherSessionsNeedYou
        if let here = runningSessions.first(where: { $0.default ? (session ?? "default") == "default" : $0.name == session }) {
            counts[here.name] = fullList.needsYouCount
        }
        return counts
    }

    /// Keeps the session pills current (#347): the machine's running herdr sessions and how
    /// many agents need you in each of the others, every 15 s. A machine whose herdr has no
    /// sessions (or a failed listing) shows no pills. If the session this home is on is no
    /// longer running (stopped since it was remembered), it moves back to the default one.
    @MainActor
    private func watchSessions() async {
        while !Task.isCancelled {
            if let listed = try? await client.listSessions() {
                let running = listed.filter(\.running)
                if let session, session != "default", !running.contains(where: { $0.name == session }) {
                    onSwitchSession(nil)
                    return
                }
                runningSessions = running
                var counts: [String: Int] = [:]
                if running.count >= 2 {
                    for other in running where (other.default ? "default" : other.name) != (session ?? "default") {
                        if let agents = try? await client.agentList(inSession: other.default ? nil : other.name) {
                            counts[other.name] = AgentList(agents: agents).needsYouCount
                        }
                    }
                }
                otherSessionsNeedYou = counts
            } else {
                runningSessions = []
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    /// A 44 pt round header control (Back, and the iPad Gram sidebar's actions).
    private func circleButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// One segment of a header capsule: a 40 x 44 glyph target.
    private func capsuleButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    /// The native-style search field: magnifier, 36 pt, rounded.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textDim)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .font(Typography.app(16)).foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    // MARK: list

    private var agentList: some View {
        agentRosterScroll
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
                rosterTitleBlock
                agentRosterRows
            }
            .onAppear { onEagerAgentRosterStackAppear?() }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                rosterTitleBlock
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
        if unavailableDaemonHost != nil { unavailableDaemonHost = nil }
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
        VStack(alignment: .leading, spacing: 0) {
            // #352: a plain list row ("Archived  1 ›") at the end of the roster, not a header.
            disclosureRow("Archived", count: fullList.archived.count, open: !archivedCollapsed) {
                archivedCollapsed.toggle()
            }

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
        return VStack(alignment: .leading, spacing: 0) {
            // #352: no section headers. Needs you, working and stopped rows follow each
            // other in that order; a collapsible group (Idle) is one plain row at the end
            // ("Idle  4 ›") that opens its rows underneath. An active search shows the rows
            // without the disclosure, as before.
            if group.startsCollapsed && search.isEmpty {
                disclosureRow(group.sectionTitle.capitalized, count: rows.count, open: !isCollapsed) {
                    if isCollapsed { collapsed.remove(group) } else { collapsed.insert(group) }
                }
            }

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

    /// A plain roster row that opens or closes a group (#352): label, count and a chevron,
    /// on the ground with an inset divider like the agent rows.
    private func disclosureRow(_ title: String, count: Int, open: Bool,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(Typography.app(17)).foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text("\(count)").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                    .monospacedDigit()
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.leading, 20).padding(.trailing, 16)
            .frame(minHeight: 48)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 0.5).padding(.leading, 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    /// #352: a Messages-style row. Full width on the ground (no card), a 52 pt round avatar
    /// with the status as a small badge on it, the amber needs-you dot left of the avatar
    /// (like Messages' unread dot), the name over a two-line preview, and an inset divider.
    /// Every marker the card had stays: account, time in state, no account, stale, offline.
    private func card(_ row: AgentRow) -> some View {
        // iPad / Mac sidebar (#352): 44 pt avatar, 72 pt row, 16 / 14 pt text; and the
        // agent open in the detail column gets a rounded highlight, like Messages' sidebar.
        let sidebar = hSizeClass == .regular
        let avatar: CGFloat = sidebar ? 44 : 52
        let isOpen = sidebar && frontID == row.info.paneID
        return HStack(alignment: .top, spacing: 0) {
            Circle().fill(row.group == .needsYou ? Palette.waiting : .clear)
                .frame(width: 10, height: 10)
                .padding(.top, 12 + avatar / 2 - 5)
                .frame(width: 20)
                .accessibilityHidden(true)
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(AgentIdentity.gradient(for: row.info.agent))
                    .frame(width: avatar, height: avatar)
                    .overlay(Text(AgentIdentity.glyph(for: row.info.agent))
                        .font(Typography.app(sidebar ? 19 : 22, .bold)).foregroundStyle(.white))
                Group {
                    if row.info.isUnreachable {
                        avatarBadge(.offline).accessibilityLabel(Text("offline"))
                    } else {
                        statusBadge(row.group)
                    }
                }
                .offset(x: 4, y: 4)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(Typography.app(sidebar ? 16 : 17, .semibold)).foregroundStyle(Palette.text)
                        .lineLimit(1)
                    rowMarkers(row)
                    Spacer(minLength: 6)
                    // How long the agent has been in its current state ("5m/2h/3d"), derived
                    // from the daemon's status_since (#173). Absent on an older server / before
                    // the first transition — then nothing, never a wrong value. `rosterNow`
                    // is one shared clock advanced by successful idle polls, rather than a
                    // separate TimelineView and timer for every off-screen agent row.
                    if let age = compactTimeInState(
                        sinceUnixMs: row.info.statusSinceUnixMs,
                        nowUnixMs: UInt64(rosterNow.timeIntervalSince1970 * 1000)
                    ) {
                        Text(age)
                            .font(Typography.app(sidebar ? 14 : 15))
                            .foregroundStyle(Palette.textDim)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityHidden(true)
                }
                // The preview: what it is doing (folder · activity). A waiting agent's reads in
                // the primary colour, like an unread message.
                Text(subtitle(row.info))
                    .font(Typography.app(sidebar ? 14 : 15))
                    .foregroundStyle(row.group == .needsYou ? Palette.text : Palette.textDim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(.top, 13).padding(.bottom, 12).padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: sidebar ? 72 : 76, alignment: .topLeading)
            // The divider starts where the text starts, not under the avatar. The open
            // row's highlight replaces it.
            .overlay(alignment: .bottom) {
                if !isOpen { Rectangle().fill(Palette.hairlineQuiet).frame(height: 0.5) }
            }
        }
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// The no-account and stale pills, after the name.
    @ViewBuilder
    private func rowMarkers(_ row: AgentRow) -> some View {
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
            // A DEGRADED peer (the daemon's 1 to 2 missed polls) still renders a live
            // status badge, and `resolvedGroup` can surface a LAST-KNOWN blocked row into
            // needs-you, so without a marker a stale guess reads exactly like a colleague
            // genuinely waiting. Mark the row instead of suppressing the badge: hiding the
            // needs-you signal would be the worse error of the two.
            if row.showsUnconfirmedMarker {
                Text("stale")
                    .font(Typography.app(11, .semibold)).foregroundStyle(Palette.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Palette.textDim.opacity(0.12)))
                    // The LABEL is replaced for VoiceOver, so the visible word "stale" is no
                    // longer findable by label. Carry an explicit identifier as well, which is
                    // what the UI receipt asserts on. Without it the receipt failed on its
                    // first CI run looking for a label that the modifier above had overwritten.
                    .accessibilityIdentifier("agent-row-stale-marker")
                    .accessibilityLabel(Text("status not confirmed on the last poll"))
            }
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

    /// The status as a 22 pt badge on the avatar (#352), ringed with the ground colour.
    /// Named for VoiceOver too: the status is colour + shape.
    private func statusBadge(_ group: AgentGroup) -> some View {
        avatarBadge(AvatarBadge(group)).accessibilityLabel(Text(group.label))
    }

    private enum AvatarBadge {
        case waiting, stopped, unrecognised, working, offline, none
        init(_ group: AgentGroup) {
            switch group {
            case .needsYou: self = .waiting
            case .stopped: self = .stopped
            case .unrecognised: self = .unrecognised
            case .working: self = .working
            case .idle: self = .none
            }
        }
    }

    /// Status is SHAPE + colour, never colour alone — desaturate the screen and it still
    /// sorts: ! in a circle waits, × in a rounded SQUARE stopped, a turning ring works. An
    /// unreachable remote agent's status is a stale last-known value, so it shows a muted
    /// offline square (gone, not live), never a live badge. Idle has no badge.
    @ViewBuilder
    private func avatarBadge(_ badge: AvatarBadge) -> some View {
        switch badge {
        case .waiting: badgeGlyph("exclamationmark", Palette.waiting, square: false)
        case .unrecognised: badgeGlyph("questionmark", Palette.waiting, square: false)
        case .stopped: badgeGlyph("xmark", Palette.died, square: true)
        case .offline: badgeGlyph("wifi.slash", Palette.surfaceRaised, square: true, ink: Palette.textDim)
        case .working:
            TurningRing(color: Palette.working, diameter: 12, lineWidth: 2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.ground))
                .overlay(Circle().stroke(Palette.ground, lineWidth: 2.5))
        case .none:
            EmptyView()
        }
    }

    private func badgeGlyph(_ system: String, _ fill: Color, square: Bool, ink: Color = Palette.ground) -> some View {
        let shape = RoundedRectangle(cornerRadius: square ? 6 : 11)
        return Image(systemName: system)
            .font(.system(size: 10, weight: .heavy)).foregroundStyle(ink)
            .frame(width: 22, height: 22)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Palette.ground, lineWidth: 2.5))
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
            } else if let host = unavailableDaemonHost {
                VStack(spacing: 10) {
                    Text("herdr API daemon not responding")
                        .font(Typography.app(18, .semibold)).foregroundStyle(Palette.died)
                    Text("The herdr binary is installed on \(host), but its API daemon could not be reached. Start or check the herdr daemon on that host, then retry.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                    Button("retry") { Task { await load() } }
                        .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                }
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
        // Live updates received from here on may postdate this load's snapshot; they
        // are replayed onto it below so a slower reload cannot undo them.
        let liveMark = liveEvents.ledger.mark
        let startedAt = ContinuousClock.now
        // Spinner ONLY when there is nothing to show yet (genuine first load, or after a
        // reconnect cleared `agents` via `.id(session)`). A re-entry with a populated list
        // refreshes silently — stale-while-revalidate — instead of blanking to a spinner.
        if agents.isEmpty, !loading { loading = true }
        defer {
            if rosterLoadGate.accepts(loadToken), loading { loading = false }
        }
        do {
            let listing = try await client.agentListing()
            guard rosterLoadGate.accepts(loadToken) else { return }
            if let origin = listing.originCapabilities {
                setLiveEventsSupported(origin.eventsV2)
            }
            liveEvents.backstop.loadSucceeded(startedAt: startedAt)
            liveEvents.unlistedReloads.loadPublished(startedAt: startedAt)
            liveEvents.ledger.settle(through: liveMark)
            let fetched = liveEvents.ledger.replay(onto: listing.agents, after: liveMark)

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
                // Replayed again: live updates may have landed during this await.
                receiveRoster(agents: liveEvents.ledger.replay(onto: listing.agents, after: liveMark),
                              accounts: fetchedAccounts)
            } else {
                guard rosterLoadGate.accepts(loadToken) else { return }
            }

            // Ping once per connected HomeView to feature-detect the transactional
            // transfer API, and `events_v2` on a daemon whose agent.list predates
            // `origin_capabilities`. Missing capabilities on an older daemon are a
            // successful negative result; a transport error is retried on the next load.
            if !checkedSessionTransferCapability {
                do {
                    let capabilities = try await client.serverCapabilities()
                    guard rosterLoadGate.accepts(loadToken) else { return }
                    if listing.originCapabilities == nil {
                        setLiveEventsSupported(capabilities?.eventsV2 == true)
                    }
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
            liveEvents.backstop.loadFailed()
            let rejected: String?
            var notInstalled = false
            var incompatibleBuild = false
            var daemonHost: String?
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
                    if case .daemonUnavailable(let host) = transportError {
                        daemonHost = host
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
                unavailableDaemonHost = daemonHost
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

    // MARK: Live status stream

    /// Records the daemon's `events_v2` advertisement. Writes the observable flag
    /// only on a change, and never re-enables a request the daemon already refused.
    @MainActor
    private func setLiveEventsSupported(_ advertised: Bool) {
        let supported = advertised && !liveEvents.refused
        if supported != liveEventsSupported { liveEventsSupported = supported }
    }

    /// Holds the all-panes status subscription until the task is cancelled
    /// (background, capability loss, or the view going away), reconnecting with
    /// backoff whenever the stream ends: the SSH channel dropped, the daemon
    /// restarted, or the silence watchdog gave up on a half-open connection.
    @MainActor
    private func runLiveEvents() async {
        var backoff = ReconnectBackoff()
        defer { liveEvents.streaming = false }
        while !Task.isCancelled {
            var acknowledged = false
            do {
                for try await line in client.subscribeAgentStatus() {
                    if case .started = line {
                        acknowledged = true
                        liveEvents.streaming = true
                        // Anything that changed while no stream was open (first
                        // connect, or the gap before this reconnect) is only in
                        // agent.list.
                        requestRosterReload()
                    } else {
                        // Only a stream that delivers something counts as healthy,
                        // so a daemon that acknowledges and hangs up at once still
                        // backs off instead of reconnecting every second.
                        backoff.reset()
                        receiveLiveEvent(line)
                    }
                }
            } catch is APIError where !acknowledged {
                // The daemon refused the request itself (it advertised events_v2 but
                // rejects entries without pane_id). Retrying cannot help; the 5 s
                // poll carries on for this connection.
                liveEvents.streaming = false
                liveEvents.refused = true
                liveEventsSupported = false
                return
            } catch {
                // A dropped or silent stream: reconnect below.
            }
            liveEvents.streaming = false
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff.next())
        }
    }

    /// Patches the listed row a status or turn event names; lifecycle events,
    /// `lagged`, and status or turn events for an agent pane the list does not show
    /// yet reload agent.list (coalesced by `requestRosterReload`, and once per
    /// unlisted pane until a later load publishes).
    @MainActor
    private func receiveLiveEvent(_ line: AgentStatusStreamLine) {
        let now = Date()
        if let update = line.liveUpdate {
            liveEvents.ledger.record(update, receivedAt: now)
        }
        let latest = rosterRefreshState().latest
        switch latest.agents.effect(of: line, receivedAt: now) {
        case .patch(let patched):
            receiveRoster(agents: patched, accounts: latest.accounts)
        case .reload:
            requestRosterReload()
        case .reloadForUnlistedPane(let pane):
            if liveEvents.unlistedReloads.request(pane, at: .now) { requestRosterReload() }
        case .ignore:
            break
        }
    }

    /// Coalesces event-driven reloads: a burst of pane lifecycle events costs one
    /// load in flight plus at most one queued behind it.
    @MainActor
    private func requestRosterReload() {
        guard liveEvents.reloadTask == nil else {
            liveEvents.reloadAgain = true
            return
        }
        let buffer = liveEvents
        buffer.reloadTask = Task { @MainActor in
            repeat {
                buffer.reloadAgain = false
                await load()
            } while buffer.reloadAgain && !Task.isCancelled
            buffer.reloadTask = nil
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

/// WHICH PASTEBOARD ITEMS THE REPLY COMPOSER TREATS AS A FILE rather than as text.
///
/// Shared by the UIKit text view (which decides whether to offer and intercept Paste) and
/// the pane (which stages the item), so the two can never disagree about what "a pasted
/// file" is.
private enum PastedFile {
    /// Concrete bytes, or a package like an .rtfd bundle — but never text, a web link or
    /// a contact card, which are ordinary pastes the reader expects to land as
    /// characters.
    ///
    /// A FILE URL is the exception, and it is the whole reason Copy in Finder or Files
    /// used to paste a path instead of attaching the file: `public.file-url` conforms to
    /// `public.url`, so the link exclusion swallowed it. A file url names bytes; a web
    /// url names a page.
    static func isAttachment(_ type: UTType) -> Bool {
        if type.conforms(to: .fileURL) { return true }
        guard type.conforms(to: .data) || type.conforms(to: .package) else { return false }
        return !type.conforms(to: .text) && !type.conforms(to: .url)
            && !type.conforms(to: .vCard) && type != .rtf && type != .flatRTFD
    }

    /// The first attachable type on the general pasteboard, read from TYPE METADATA ONLY.
    ///
    /// `UIPasteboard.types` never touches the items, so this is safe to call while UIKit
    /// builds an edit menu. Reading `itemProviders` there instead is a content read, which
    /// raises the system "Allow Paste?" prompt for anything copied in another app.
    ///
    /// A file url wins the LOOKUP when both are advertised — it is the representation
    /// that survives a cross-process copy with its name intact — but staging still
    /// prefers the file's concrete type, because a url is a reference and bytes are not.
    static func pasteboardType() -> UTType? {
        let types = UIPasteboard.general.types.lazy.compactMap { UTType($0) }
        return types.first { $0.conforms(to: .fileURL) } ?? types.first(where: isAttachment)
    }

    /// Whether the pasteboard names a FILE. Metadata only, and the one case where an
    /// accompanying text representation must not win: Finder and Files put the path on
    /// the pasteboard beside the file, and pasting that path is never what was meant.
    static func pasteboardHasFileURL() -> Bool {
        UIPasteboard.general.contains(pasteboardTypes: [UTType.fileURL.identifier])
    }
}

struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    var placeholder = "Type a reply…"
    var accessibilityIdentifier = "terminal-reply-input"
    var capitalization: UITextAutocapitalizationType = .none
    var autocorrection: UITextAutocorrectionType = .no
    var onChange: (String, String) -> Void = { _, _ in }
    var onReturn: ((String) -> Void)?
    var onCommandReturn: (() -> Void)?
    var onPasteFile: ((NSItemProvider) -> Bool)?
    /// The pull-to-expand editor's height; nil lets the field size itself to its text,
    /// up to `ComposerStyle.visibleLines`.
    var fixedHeight: CGFloat?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReplyTextView {
        let view = ReplyTextView()
        view.onPasteFile = onPasteFile
        view.onCommandReturn = onCommandReturn
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.text)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.configureTypography()
        view.autocapitalizationType = capitalization
        view.autocorrectionType = autocorrection
        view.returnKeyType = onReturn == nil ? .default : .send
        // Scrolling is ON at every height (see `refreshScrollMode`); only bouncing tracks
        // whether the content overflows.
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.accessibilityIdentifier = accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: ReplyTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteFile = onPasteFile
        view.onCommandReturn = onCommandReturn
        view.configureTypography()
        view.setPlaceholder(placeholder)
        if view.text != text {
            view.attributedText = NSAttributedString(string: text, attributes: view.composerAttributes)
            view.typingAttributes = view.composerAttributes
            view.updatePlaceholder()
            view.invalidateIntrinsicContentSize()
            view.refreshScrollMode()
        }
        if view.fixedHeight != fixedHeight {
            view.fixedHeight = fixedHeight
            view.invalidateIntrinsicContentSize()
            view.refreshScrollMode()
        }
        view.isEditable = isEnabled
        if isFocused {
            context.coordinator.nativeFocusPendingStateSync = false
            if !view.isFirstResponder {
                view.becomeFirstResponder()
            }
        } else if view.isFirstResponder, !context.coordinator.nativeFocusPendingStateSync {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReplyTextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let natural = uiView.fittingHeight(for: width)
        return CGSize(
            width: width,
            height: min(max(natural, uiView.minimumHeight), uiView.maximumHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextField
        /// A native tap reaches UIKit before SwiftUI commits the FocusState update.
        /// Keep that responder alive through text-binding renders until the true state arrives.
        var nativeFocusPendingStateSync = false

        init(_ parent: ComposerTextField) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            nativeFocusPendingStateSync = true
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            nativeFocusPendingStateSync = false
            // `resignFirstResponder()` and `isEditable = false` both run from INSIDE
            // updateUIView and both end editing synchronously, so writing the focus binding
            // straight through from here mutates SwiftUI state during its own update pass
            // ("Modifying state during view update, this will cause undefined behavior").
            // Hop off the pass, and skip the write when the declared state already agrees —
            // @State has no same-value short circuit, so an equal write still publishes.
            guard parent.isFocused else { return }
            let notify = parent.onFocusChange
            Task { @MainActor in notify(false) }
        }

        func textViewDidChange(_ textView: UITextView) {
            let old = parent.text
            let new = textView.text ?? ""
            parent.text = new
            parent.onChange(old, new)
            (textView as? ReplyTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
            (textView as? ReplyTextView)?.refreshScrollMode()
            (textView as? ReplyTextView)?.requestCaretReveal()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n", let onReturn = parent.onReturn else { return true }
            onReturn(textView.text ?? "")
            return false
        }
    }

    final class ReplyTextView: UITextView {
        var onPasteFile: ((NSItemProvider) -> Bool)?
        var onCommandReturn: (() -> Void)?
        private lazy var sendKeyCommand: UIKeyCommand = {
            let command = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturn))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }()

        override var keyCommands: [UIKeyCommand]? {
            guard onCommandReturn != nil else { return super.keyCommands }
            return (super.keyCommands ?? []) + [sendKeyCommand]
        }

        @objc private func commandReturn() { onCommandReturn?() }
        private let placeholder = UILabel()
        private(set) var lineHeight: CGFloat = 24
        var fixedHeight: CGFloat?
        var minimumHeight: CGFloat { fixedHeight ?? lineHeight }
        var maximumHeight: CGFloat { fixedHeight ?? lineHeight * CGFloat(ComposerStyle.visibleLines) }
        private(set) var composerAttributes: [NSAttributedString.Key: Any] = [:]

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholder.textColor = UIColor(Palette.textDim)
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
                placeholder.topAnchor.constraint(equalTo: topAnchor),
            ])
        }

        func configureTypography() {
            let size = ComposerStyle.fontSize * Typography.scale
            guard font?.pointSize != size || lineHeight != ComposerStyle.lineHeight || composerAttributes.isEmpty
            else { return }
            composerAttributes = ComposerTextMetrics.attributes()
            let face = composerAttributes[.font] as? UIFont ?? .systemFont(ofSize: size)
            let selection = selectedRange
            attributedText = NSAttributedString(string: text ?? "", attributes: composerAttributes)
            typingAttributes = composerAttributes
            selectedRange = selection
            lineHeight = ComposerStyle.lineHeight
            placeholder.font = face
        }

        func setPlaceholder(_ text: String) {
            placeholder.attributedText = NSAttributedString(
                string: text,
                attributes: composerAttributes.merging([.foregroundColor: UIColor(Palette.textDim)]) { _, new in new })
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if onPasteFile != nil, action == #selector(paste(_:)), PastedFile.pasteboardType() != nil {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard onPasteFile != nil else {
                super.paste(sender)
                return
            }
            // Text wins when the pasteboard carries both. Copying an image out of Safari
            // registers a URL alongside the image, and a composer that swallowed the item
            // as a file dropped the text the user was actually after.
            //
            // A FILE URL overrides that: Finder and Files put the path on the pasteboard
            // beside the file, so deferring to text there pasted "/Users/…/main.pdf" and
            // attached nothing — which is exactly how Command-V looked broken on Mac and
            // iPad.
            if PastedFile.pasteboardHasFileURL() {
                if let type = PastedFile.pasteboardType(),
                   let provider = UIPasteboard.general.itemProviders.first(where: {
                       $0.hasItemConformingToTypeIdentifier(type.identifier)
                   }) {
                    _ = onPasteFile?(provider)
                }
                // Consumed either way. A decline here means the cap, a load already in
                // flight, or a pane with no named agent — each of which says so in the
                // note. Falling through would ALSO drop the path into the composer, which
                // is the outcome this whole change exists to remove.
                return
            }
            if !UIPasteboard.general.hasStrings, let type = PastedFile.pasteboardType(),
               let provider = UIPasteboard.general.itemProviders.first(where: {
                   $0.hasItemConformingToTypeIdentifier(type.identifier)
               }),
               onPasteFile?(provider) == true
            {
                return
            }
            super.paste(sender)
        }

        private var shouldRevealCaretAfterLayout = false

        /// The height this text needs at `width`, measured from the STRING — not from
        /// `UITextView.sizeThatFits`.
        ///
        /// `sizeThatFits` on a text view answers differently depending on `isScrollEnabled`
        /// and on how much TextKit has lazily laid out, so while it drove the SwiftUI height
        /// the box could still report a two-line height with three lines of text in it: the
        /// third line — the one being typed — was clipped away, and typing looked like it did
        /// nothing until a fourth line made the view scrollable and dragged the caret back
        /// into view. A layout-independent measurement cannot lag the text.
        func fittingHeight(for width: CGFloat) -> CGFloat {
            let padding = 2 * textContainer.lineFragmentPadding
            let usable = max(1, width - textContainerInset.left - textContainerInset.right - padding)
            return ComposerTextMetrics.height(of: text ?? "", width: usable,
                                              attributes: composerAttributes, lineHeight: lineHeight)
        }

        /// Scrolling stays ON at every height. It used to be toggled with the content, which
        /// meant the caret could not be scrolled into view in exactly the state where it had
        /// gone out of view. Bouncing is what actually tracks the content, and a content that
        /// fits is pinned back to the top so a stale offset can never blank the field.
        func refreshScrollMode() {
            guard bounds.width > 0 else { return }
            let overflows = fittingHeight(for: bounds.width) > maximumHeight + 0.5
            alwaysBounceVertical = overflows
            if !overflows, contentOffset.y != 0 {
                setContentOffset(.zero, animated: false)
            }
        }

        func requestCaretReveal() {
            shouldRevealCaretAfterLayout = true
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshScrollMode()
            guard shouldRevealCaretAfterLayout else { return }
            shouldRevealCaretAfterLayout = false
            guard let selection = selectedTextRange else { return }
            let caret = caretRect(for: selection.end).insetBy(dx: 0, dy: -4)
            scrollRectToVisible(caret, animated: false)
        }


        func updatePlaceholder() {
            placeholder.isHidden = !text.isEmpty
        }
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
    /// One staged file on its way to the agent: a pasted photo, a PDF, a log, anything
    /// the pasteboard can vend as a file. `isImage` only chooses the chip glyph and the
    /// wording of the prompt reference; the delivery path is identical either way.
    private struct PromptAttachment: Identifiable, Sendable {
        let id: UUID
        let name: String
        let mime: String
        let isImage: Bool
        let size: Int
        let staged: StagedAttachment?
        let uploadID: String?
        let gramMessageID: String?
    }

    @State private var reply: String
    @StateObject private var composerKeyboard = ComposerKeyboard()
    /// Every staged attachment, in paste order. Each sends as its own gram message and
    /// they are all named by ONE prompt, so the agent gets a single turn that points at
    /// the whole set. Capped at `GramView.Staging.maxAttachments`.
    @State private var replyAttachments: [PromptAttachment] = []
    /// The ••• "Share with someone" sheet and the guests who hold this agent (the header chip).
    @StateObject private var guestShare = GuestSharePaneModel()
    @State private var loadingReplyAttachment = false
    /// The paperclip's attach sheet (`composerAttachPicker`), the third way in beside
    /// paste and drag-and-drop.
    @State private var showReplyAttachSheet = false
    /// Progress belongs to an attachment identity, including while its gram is posting.
    @State private var replyUploadBytes: (sent: Int, total: Int)?
    @State private var replySendingAttachmentID: UUID?
    @State private var replyFailedAttachmentID: UUID?
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
    /// A drag is hovering the reply bar, so the target says so before the drop lands.
    @State private var replyDropTargeted = false
    @State private var sending = false
    /// Keycap writes share one ordered drain; prompt/attachment sends retain their
    /// own in-flight guard without throttling a rapid run of terminal keys.
    @State private var keySendTask: Task<Void, Never>?
    /// A failed key invalidates only keys queued before the failure; a new tap can retry.
    @State private var keyFailureEpoch = 0
    @State private var keySendSequence = 0
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
    /// The live terminal's stream-liveness box. A `@State` reference type, so it SURVIVES
    /// a `streamGen` remount and keeps reading the same stream's evidence across one.
    @State private var terminalLiveness = StreamLiveness()
    /// One-shot Ctrl shared by direct terminal input and the reply field. Native
    /// encoding owns direct chords; `handleReplyChange` owns reply-field chords.
    @State private var ctrlArmed = false
    /// True while dictating into the reply: disables the field (so typing can't be
    /// overwritten by the next partial) and suppresses the ctrl-chord interception (so a
    /// single-char dictation partial can't be misread as a control chord).
    @State private var replyDictating = false
    /// Focus of the reply field, so the software keyboard can be DISMISSED — via the
    /// keyboard-toolbar chevron or a tap on the (read-only) terminal.
    @State private var replyFocused = false
    /// Terminal-input focus is explicit on touch devices. A terminal tap enables
    /// direct PTY typing; reply submission and keyboard collapse clear it so the
    /// software keyboard can genuinely dismiss instead of immediately moving focus
    /// back to the terminal.
    @State private var terminalInputFocused = false
    /// Incremented by the collapse chevron to request a DELIBERATE collapse. Without it a
    /// deliberate collapse is indistinguishable from any other pass where the terminal simply does
    /// not want key focus, and the resign is refused while a selection is held.
    ///
    /// A TOKEN, not a bool set for "the next pass" — see `LiveTerminalView.consumeCollapse`. The
    /// bool version cleared itself in `DispatchQueue.main.async`, which drains BEFORE SwiftUI's
    /// update flush, so the pane read it as already false and the collapse never happened.
    @State private var terminalCollapseToken = 0
    /// Incremented to ask the pane to jump to its newest output. LiveTerminalView
    /// performs exactly one jump per increment.
    @State private var jumpToTailToken = 0
    /// Bumped whenever the host itself delivers input to the pane (a control-bar
    /// keycap, a raw sequence cap). Those buttons live OUTSIDE the terminal surface, so
    /// the view's own touch and key paths never see them: without this the retained
    /// resize frame stayed up while their bytes reached the agent, and an input that
    /// produced no redraw looked ignored. Reported by review at d750df7.
    @State private var userInputToken = 0
    /// False while the pane is scrolled away from its newest output. Drives the
    /// "Latest" pill. Starts true so the pill stays hidden until the reader scrolls.
    @State private var terminalAtTail = true
    /// The terminal's current height: the room the composer grows over.
    @State private var terminalHeight: CGFloat = 0
    /// The note and quick-key row above the composer. With the composer's resting row,
    /// the only layout height the bottom block reserves.
    @State private var bottomChromeHeight: CGFloat = 0
    private static let replyBarTopPadding: CGFloat = 4
    private static let replyBarBottomPadding: CGFloat = 8
    /// Find-bar state. `findRequest` is nil while the bar is closed, which is also what
    /// clears the highlight — see `LiveTerminalView.performFind`.
    @State private var findOpen = false
    @State private var findTerm = ""
    /// Bumped once per next/previous step. The term alone cannot express "same term,
    /// next match", which is the whole interaction.
    @State private var findGeneration = 0
    @State private var findDirection: FindRequest.Direction = .forward
    /// `(index, total)` from the terminal, rendered as "3/17".
    @State private var findMatches: (Int, Int) = (0, 0)
    @FocusState private var findFocused: Bool

    private var findRequest: FindRequest? {
        guard findOpen else { return nil }
        return FindRequest(term: findTerm, generation: findGeneration, direction: findDirection)
    }
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
    private var hasReplyContent: Bool {
        !replyAttachments.isEmpty || !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canSend: Bool {
        hasReplyContent && !sending && !replyDictating && !loadingReplyAttachment
    }

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
                                 // The find and reply fields own their own responders.
                                 // Terminal focus is never inferred from device idiom.
                                 wantsTerminalKeyFocus: isForeground && !replyFocused && !findFocused
                                     && terminalInputFocused,
                                 // Set by the collapse chevron so the resign in updateUIView can
                                 // tell a deliberate dismissal from an incidental body pass.
                                 collapseToken: terminalCollapseToken,
                                 onTerminalFocusRequest: {
                                     replyFocused = false
                                     terminalInputFocused = true
                                 },
                                 jumpToTailToken: jumpToTailToken,
                                 onTailStateChange: { terminalAtTail = $0 },
                                 // The host's current belief, so a `streamGen` remount seeds a
                                 // fresh Coordinator instead of replaying the last jump.
                                 isAtTail: terminalAtTail,
                                 fontSize: CGFloat(terminalFontSize),
                                 // Read on foreground to tell a suspended stream from a
                                 // still-running one; see the scenePhase handler below.
                                 liveness: terminalLiveness,
                                 controlArmed: $ctrlArmed,
                                 userInputToken: userInputToken,
                                 findRequest: findRequest,
                                 onFindResult: { index, total in findMatches = (index, total) })
                    // Reconnect on refresh: a new id re-creates the view → fresh stream/connection.
                    .id(streamGen)
                    .accessibilityIdentifier("terminal-surface")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { terminalHeight = $0 }
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
                        ZStack {
                            if !terminalAtTail { jumpToLatestPill }
                        }
                        .animation(.easeInOut(duration: 0.15), value: terminalAtTail)
                    }
                // THE COMPOSER FLOATS OVER THE TERMINAL. Only its resting row (plus the
                // note and the quick keys above it) takes layout height. Every extra line,
                // the toolbar, attachments, the drag handle and the editor draw upward
                // over the terminal's bottom rows instead of taking them away. Each of
                // those used to change the terminal's size, which sent set_pty_size, made
                // the agent redraw its whole screen and froze the terminal behind a
                // snapshot for up to a second: the "reload" felt while only typing (#301).
                Color.clear
                    .frame(height: bottomChromeHeight + ComposerStyle.restingHeight
                        + Self.replyBarTopPadding + Self.replyBarBottomPadding)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if let note = actionNote {
                                    Text(note).font(Typography.app(12)).foregroundStyle(Palette.textDim)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
                                        // Identified so a failing receipt can quote the refusal instead of
                                        // reporting only that nothing happened.
                                        .accessibilityIdentifier("terminal-action-note")
                                }
                                controlBar
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomChromeHeight = $0 }
                            // The terminal's height no longer depends on the composer, so it
                            // is a stable measure of the room the composer grows over.
                            replyBar
                                .environment(\.composerEditorRoom, terminalHeight)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        // Opaque, so rows the composer grows over do not show through the
                        // gaps between the keycaps and around the card.
                        .background(Palette.groundMachine)
                    }
            }
        }
        // Left-edge swipe → back to the agents list. Edge-only, so it never fights the
        // terminal scroll. Rendered ONLY for the front pane: EdgeSwipeBack attaches its
        // recognizer to the WINDOW, so N keep-mounted panes would otherwise stack N
        // recognizers that all fire on one edge swipe.
        .overlay { if isForeground { EdgeSwipeBack { onClose() } } }
        // Hardware-keyboard shortcuts for this pane. Foreground only: N keep-mounted panes
        // would otherwise register N identical Command-F bindings, and UIKit would pick one
        // arbitrarily — quite possibly a hidden pane's.
        .background { if isForeground { paneKeyboardShortcuts } }
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
                ctrlArmed = false
                replyFocused = false
                terminalInputFocused = false
            }
        }
        .onDisappear { ctrlArmed = false }
        // When the app returns to the foreground, reseed the FRONT pane the same way the
        // header refresh button does (bump streamGen → remount → startBackfill() reads the
        // durable current screen + scrollback) — BUT ONLY IF THE STREAM ACTUALLY STOPPED.
        //
        // #62's fix keyed the reseed on scene phase alone, which is a PROXY, and the proxy
        // is only true on iOS. There the app is suspended, the stream really did stall, and
        // output produced while away is lost until a manual refresh, so a reseed repairs a
        // genuine gap. On a Mac the process keeps running while another Space or app is
        // front: frames keep arriving, nothing is lost, and the reseed then destroys a
        // perfectly live terminal — remounting throws away the reader's SELECTION and
        // scroll position, which is the whole point of the selection work in #203/#215.
        //
        // So judge the FACT instead. `terminalLiveness` records when a frame last arrived,
        // and the server pings every 20s, so a still-connected stream is at most ~20s stale
        // while `streamStuckTimeout` (50s, 2.5× the ping) is the Coordinator's own
        // definition of a dead stream. Reusing that one constant keeps the host and the
        // watchdog from drifting apart on what "dead" means.
        //
        // Gated on isForeground so only the visible pane pays a reseed; hidden keep-mounted
        // panes reseed when next front.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ctrlArmed = false }
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active:
                // WHY THE PLATFORM CHECK IS HERE AND STALENESS IS NOT ENOUGH ALONE, found by
                // review. On iOS the process is SUSPENDED, so `lastFrameAt` freezes at the
                // instant of suspension and never advances while away. Return within 50s and
                // staleness reads false — yet the gap is real, because a suspended socket
                // received nothing. The reconnect does not cover it either: startBackfill()
                // runs only from `attach`, and the history prepend inside the .reset keyframe
                // is gated on `firstReset`, so a mid-session reconnect repaints the visible
                // screen and leaves the scrolled-off output missing. That would narrow #62's
                // repair to backgrounds longer than 50s.
                //
                // So the two platforms are asked different questions, because their facts
                // differ. On iOS a real background IS a real gap — always reseed, exactly as
                // before this change. Only on a Mac, where the process keeps running and
                // frames keep arriving, is staleness the honest test.
                //
                // Note this is NOT the "two-line platform gate" rejected while designing
                // this: that version used the platform alone to SUPPRESS the reseed, which
                // would also have suppressed a legitimate one under App Nap. Here the
                // platform WIDENS (iOS always reseeds) and staleness still governs the Mac,
                // so an App-Nap-suspended Mac window reads stale and reseeds correctly.
                let streamDied = !ProcessInfo.processInfo.isiOSAppOnMac
                    || terminalLiveness.isStale(
                        timeout: LiveTerminalView.streamStuckTimeout
                    )
                if wasBackgrounded && isForeground && streamDied { streamGen += 1 }
                wasBackgrounded = false
            default:
                break
            }
        }
    }

    // MARK: header

    /// One bar (#358): back, the title block (heading over status · live time), and one
    /// capsule holding Find, Reconnect and the ⋯ actions. The bar's height is constant in
    /// every state (44 pt at 100 % text, scaled with the app text size up to 62 pt), so opening
    /// find, a pane with no agent status, or a status change can never resize the terminal
    /// underneath (a height change resizes the PTY and reflows the buffer).
    private var header: some View {
        HStack(spacing: 10) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Palette.surfaceRaised))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            if findOpen {
                findField
            } else {
                titleBlock
                // The guest-share chip is taller than the status line, so it sits beside the
                // title block (vertically centred) rather than inside the fixed-height bar's
                // second line.
                if let chip = guestShare.chipText { GuestShareChip(text: chip) }
            }
            HStack(spacing: 0) {
                InlineSearchToggle(isOpen: findOpen, identifier: "terminal-find",
                                   target: CGSize(width: 40, height: 44)) { toggleFind() }
                Button {
                    streamGen += 1            // reconnect the pane's stream (re-create LiveTerminalView)
                    Task { await refresh() }   // and re-resolve the agent's status/identity
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal-refresh")
                .accessibilityLabel("Reconnect and refresh")
                // Per-agent actions (⋯), only for an agent pane — as before, where they lived
                // on the status row that exists only when the pane has a status group.
                if group != nil { agentActionsMenu }
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Palette.surfaceRaised))
        }
        // Fixed across find / status / no-status states, but scaled with the app's text
        // size: at 140 % the title (16 pt) over the status line (11 pt) needs ~47 pt and
        // would overflow a plain 44 pt bar. The height then changes only when the user
        // changes Settings → Text size, a deliberate one-off, never while working.
        .frame(height: max(44, (44 * Typography.scale).rounded()))
        // A keep-mounted BACKGROUND pane still renders its header, so without this every
        // loaded pane publishes its own "terminal-refresh"/"terminal-find"/"terminal-actions"
        // to the accessibility tree. VoiceOver could then land on a hidden pane's controls,
        // and an automation query for one button legitimately matches several.
        .accessibilityHidden(!isForeground)
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
        .background(Palette.groundMachine)
        .modifier(GuestSharePresenter(model: guestShare, client: client, agent: agent,
                                      fallbackTitle: title, isForeground: isForeground))
    }

    /// The heading, with the agent's status underneath: pulsing dot + status word and the
    /// live time in that status.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).font(Typography.app(16, .semibold))
                .foregroundStyle(Palette.text).lineLimit(1)
            if let group {
                HStack(spacing: 6) {
                    PulsingDot(color: group.color, active: group == .working)
                    Text(group.sectionTitle).font(Typography.microLabel).tracking(1)
                        .foregroundStyle(group.color)
                    if let sinceMs = statusSinceMs {
                        let start = Date(timeIntervalSince1970: Double(sinceMs) / 1000)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(elapsedLabel(ctx.date.timeIntervalSince(start)))
                                .font(Typography.machine(11)).monospacedDigit()
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityIdentifier("terminal-font-increase")
                Button {
                    terminalFontSize = max(terminalFontSize - 1, 9)
                } label: { Label("Decrease", systemImage: "textformat.size.smaller") }
                .accessibilityIdentifier("terminal-font-decrease")
                Button {
                    terminalFontSize = 12.5
                } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            if agent != nil {
                Button {
                    guestShare.isSharing = true
                } label: { Label("Share with someone", systemImage: "person.badge.plus") }
                .accessibilityIdentifier("terminal-share")
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(mute.isMuted(paneID) ? Palette.waiting : Palette.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("terminal-actions")
    }

    /// Shown only while the pane is scrolled away from its newest output, so it is out
    /// of the way the rest of the time. Uses the app's primary ink-fill treatment, the
    /// same one the send arrow and the banner's Switch button use.
    /// Hardware-keyboard shortcuts for this pane, carried by hidden zero-size buttons —
    /// the same pattern the split view uses for Command-K and Command-slash
    /// (`keyboardShortcuts`, :1931-1947).
    ///
    /// Why not `UIKeyCommand` on the terminal view, where the Ctrl chords live? Because
    /// Ctrl chords have to be TAKEN BACK from macOS's emacs-style text bindings, which is
    /// what `wantsPriorityOverSystemBehavior` is for (LiveTerminalView.swift:436-447).
    /// Command chords have no such competitor: the vendored terminal declares no
    /// `keyCommands`, and its `pressesBegan` has no branch for a Command-modified letter,
    /// so the press walks up the responder chain to these buttons untouched.
    @ViewBuilder private var paneKeyboardShortcuts: some View {
        Button("Find in terminal") {
            if findOpen { findFocused = true } else { toggleFind() }
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

        Button("Reconnect") {
            streamGen += 1
            Task { await refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

        // Escape closes the find bar, matching every other find bar. Only bound while the
        // bar is open, so it cannot swallow an Escape the terminal wants — vi users press
        // it constantly, and stealing it would be a far worse bug than missing shortcut.
        if findOpen {
            Button("Close search") { toggleFind() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    /// The inline find field, shared with Gram's header (`InlineSearchField`).
    ///
    /// Replaces the heading rather than adding a header row: growing the header would
    /// resize the terminal mid-search and reflow the buffer under the reader, moving the
    /// very match they are looking at.
    private var findField: some View {
        InlineSearchField(
            placeholder: "Find",
            text: $findTerm,
            focus: $findFocused,
            matches: (index: findMatches.0, total: findMatches.1),
            onNext: { stepFind(.forward) },
            onPrevious: { stepFind(.backward) },
            identifierPrefix: "terminal-find"
        )
    }

    /// Opens the find bar and takes focus, or closes it and hands focus back.
    ///
    /// Closing clears the term, which is what drops the highlight (`findRequest` goes nil).
    /// It deliberately does NOT jump to the tail: a reader who searched into history is
    /// still reading history.
    private func toggleFind() {
        if findOpen {
            findOpen = false
            findTerm = ""
            findMatches = (0, 0)
            findFocused = false
        } else {
            findOpen = true
            findFocused = true
            // An armed one-shot Ctrl would otherwise encode the next keystroke as a control
            // byte — including one typed into the find field.
            ctrlArmed = false
        }
    }

    /// One next/previous step. The generation bump is what tells the Coordinator this is a
    /// step rather than an edit of the term.
    private func stepFind(_ direction: FindRequest.Direction) {
        guard !findTerm.isEmpty else { return }
        findDirection = direction
        findGeneration += 1
    }

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

    /// [Switch] sends `/tui default` with `waitUntil: anyAgentStatus`. A confirmed
    /// delivery closes the banner; an uncertain result also closes it rather than
    /// inviting a duplicate send. Genuine non-delivery keeps the retry available.
    /// Claude Code persists the slash command in ~/.claude/settings.json, so one
    /// successful switch also changes future agents on that host.
    private func switchToClassicTui() {
        // Coalesce repeated taps: without this each tap would queue another /tui default prompt
        // (the reply box's send is already gated by `sending`; the banner had no equivalent).
        guard !switchingTui else { return }
        switchingTui = true
        let pane = paneID
        // A confirmed send dismisses the banner. An uncertain result also dismisses
        // it: leaving a one-tap retry after the PTY may have received /tui default
        // would queue a duplicate. The note directs the reader to the terminal.
        Task {
            defer { switchingTui = false }
            do {
                _ = try await client.prompt(pane: pane, text: "/tui default",
                                            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
                tuiClassicPrompted = true
                actionNote = "Switched. Claude Code will open in smooth-scroll mode from now on"
            } catch let error as APIError {
                if PromptRejection(error).mayHaveReachedAgent {
                    tuiClassicPrompted = true
                    actionNote = Self.promptRejectionNote(for: error)
                } else {
                    actionNote = "Couldn't switch. Tap Switch to try again"
                }
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
    //
    // #359: related keys share one group shape, a Space key follows esc, and Return is
    // PINNED outside the scroll view so it is always one tap away on iPhone.
    private var controlBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    keyCap(label: "esc", key: "Escape")
                    keyCap(label: "space", key: "Space", minWidth: 84)
                    ComposerKeyGroup {
                        keyCap(image: "ComposerKeyLeft", key: "Left", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyUp", key: "Up", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyDown", key: "Down", grouped: true)
                        ComposerKeyDivider()
                        keyCap(image: "ComposerKeyRight", key: "Right", grouped: true)
                    }
                    // End (end-of-line cursor) + the two scroll jumps for a mouse-mode agent
                    // like Claude Code: Ctrl+Home = jump to TOP, Ctrl+End = jump to BOTTOM
                    // (and re-enable auto-follow). ESC[1;5H / ESC[1;5F are the xterm Ctrl+Home
                    // / Ctrl+End sequences Claude Code's readline keymap honors (End alone is a
                    // cursor key there, not a scroll — hence the two Ctrl jumps for scrolling).
                    ComposerKeyGroup {
                        keyCap(label: "end", key: "End", grouped: true)
                        ComposerKeyDivider()
                        rawCap(label: "Jump to top", image: "ComposerKeyTop", sequence: "\u{1b}[1;5H", grouped: true)
                        ComposerKeyDivider()
                        // Jump to the newest output. Routed through the pane rather than a raw
                        // byte sequence, so a plain shell scrolls its own scrollback while a
                        // mouse-mode agent gets Ctrl+End. Deliberately NOT disabled on
                        // `sending || pendingPrefill` like the keycaps: this is local view
                        // navigation, not input to the agent.
                        Button { jumpToTailToken += 1 } label: {
                            ComposerQuickKeyLabel(text: "Jump to latest output", imageName: "ComposerKeyLatest",
                                                  grouped: true)
                        }
                        .accessibilityLabel(Text("Jump to latest output"))
                    }
                    ComposerKeyGroup {
                        keyCap(label: "tab", key: "Tab", grouped: true)
                        ComposerKeyDivider()
                        // Shift+Tab (CBT / back-tab, ESC[Z) — cycles Claude-Code modes. A
                        // raw escape sequence, not a named key: delivered verbatim to the PTY.
                        rawCap(label: "S-Tab", sequence: "\u{1b}[Z", grouped: true)
                    }
                    ComposerKeyGroup {
                        // Sticky Ctrl: arm, then the next typed char becomes its control byte.
                        ctrlCap
                        ComposerKeyDivider()
                        // ^P (previous prompt/history) — a one-tap control sequence for
                        // navigating OMP's prompt history without first arming Ctrl.
                        rawCap(label: "^P", sequence: "\u{10}", grouped: true)
                        ComposerKeyDivider()
                        // ^C (interrupt) — the common one-tap case; a raw control byte.
                        rawCap(label: "^C", sequence: "\u{03}", grouped: true)
                    }
                }
                .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 8)
            }
            // Keys fade out just before the pinned Return instead of sliding under it.
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            )
            // The submit affordance rawKeys needs — typing never submits, so Return is the
            // deliberate second action. Highlighted, and pinned so it never scrolls away.
            keyCap(image: "ComposerKeyEnter", key: "Enter", primary: true)
                .padding(.trailing, 16)
        }
    }

    private func keyCap(label: String? = nil, image: String? = nil, key: String, primary: Bool = false,
                        grouped: Bool = false, minWidth: CGFloat = 44) -> some View {
        Button { ctrlArmed = false; send(.key(key)) } label: {
            ComposerQuickKeyLabel(text: label ?? key, imageName: image, primary: primary,
                                  grouped: grouped, minWidth: minWidth)
        }
        // Only a real prompt/attachment transaction or pending prefill blocks
        // keycaps; ordinary key writes are ordered without a cooldown.
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(key))
    }

    /// A cap that sends a raw byte SEQUENCE (a control byte or an escape sequence)
    /// straight to the PTY via `pane.send_text` — for keys herdr's named allow-list
    /// does not cover (Shift+Tab = `ESC[Z`, `^C` = `\u{03}`). Routed through the
    /// `.rawSequence` action so it is delivered verbatim, not newline-refused.
    private func rawCap(label: String, image: String? = nil, sequence: String, grouped: Bool = false) -> some View {
        Button { ctrlArmed = false; send(.rawSequence(sequence)) } label: {
            ComposerQuickKeyLabel(text: label, imageName: image, grouped: grouped)
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(label))
    }

    /// One-shot Ctrl for direct terminal input and the reply field. Native terminal
    /// encoding owns direct chords; `handleReplyChange` owns reply-field chords.
    /// Tapping twice cancels without sending input.
    private var ctrlCap: some View {
        Button { ctrlArmed.toggle() } label: {
            ComposerQuickKeyLabel(text: "ctrl", armed: ctrlArmed, grouped: true)
        }
        .disabled(sending || pendingPrefill)
        .accessibilityLabel(Text(ctrlArmed ? "control armed" : "control"))
        .accessibilityIdentifier("terminal-ctrl")
    }
    @ViewBuilder
    private var replyAttachmentStrip: some View {
        if !replyAttachments.isEmpty || loadingReplyAttachment {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(replyAttachments) { attachment in
                        replyAttachmentChip(attachment)
                    }
                    if loadingReplyAttachment {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Adding attachment…").font(Typography.app(12))
                        }
                        .foregroundStyle(Palette.textDim)
                        .padding(12)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
                        .accessibilityIdentifier("terminal-attachment-loading")
                    }
                }
                .padding(.horizontal, 7)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func replyAttachmentChip(_ attachment: PromptAttachment) -> some View {
        ComposerAttachmentChip(
            name: attachment.name, size: attachment.size, isImage: attachment.isImage,
            state: replyAttachmentState(attachment), canRemove: !sending,
            onRemove: { removeReplyAttachment(attachment) }
        )
        .accessibilityIdentifier("terminal-attachment")
    }

    private func replyAttachmentState(_ attachment: PromptAttachment) -> ComposerAttachmentState {
        if attachment.id == replyFailedAttachmentID { return .failed }
        if attachment.gramMessageID != nil { return .sent }
        guard sending else { return .ready }
        guard attachment.id == replySendingAttachmentID else { return .waiting }
        if let upload = replyUploadBytes {
            return .uploading(sent: upload.sent, total: upload.total)
        }
        return .sending
    }


    private var replyBar: some View {
        AdaptiveComposer(
            text: reply,
            isFocused: replyFocused,
            hasAccessory: !replyAttachments.isEmpty || loadingReplyAttachment,
            showsLeading: composerKeyboard.isVisible && !findFocused && (replyFocused || terminalInputFocused),
            isRecording: replyDictating
        ) { editorHeight in
            ComposerTextField(
                text: $reply,
                // Dictation owns the field; an upload must not resign its first responder.
                isEnabled: !replyDictating,
                isFocused: replyFocused,
                onFocusChange: { focused in
                    replyFocused = focused
                    if focused { terminalInputFocused = false }
                },
                onChange: { oldValue, newValue in
                    handleReplyChange(old: oldValue, new: newValue)
                },
                onReturn: { currentText in
                    guard !sending, !replyDictating,
                          !replyAttachments.isEmpty
                            || !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return }
                    ctrlArmed = false
                    sendTapped(currentText)
                },
                onPasteFile: pasteReplyAttachment,
                fixedHeight: editorHeight
            )
            .frame(minWidth: 0, maxWidth: .infinity)
        } accessory: {
            replyAttachmentStrip
        } leading: {
            Button {
                terminalCollapseToken += 1
                ctrlArmed = false
                replyFocused = false
                terminalInputFocused = false
            } label: {
                ComposerActionIcon(image: Image("ComposerKeyboard"))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse keyboard")
        } actions: {
            HStack(spacing: 4) {
                ComposerAttachButton(busy: loadingReplyAttachment) { openReplyAttachSheet() }
                    .disabled(sending || autoDelivering || loadingReplyAttachment)
                    .accessibilityIdentifier("terminal-attach-button")
                MicButton(text: $reply,
                          isActive: isForeground && !autoDelivering, recording: $replyDictating,
                          onStart: { ctrlArmed = false })
                    .fixedSize()
                    .disabled(sending || autoDelivering)
                if !hasReplyContent {
                    SavedPromptsMenu(onSelect: usePrompt)
                        .disabled(sending || autoDelivering || replyDictating)
                } else {
                    Button {
                        sendTapped()
                        terminalInputFocused = false
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            terminalCollapseToken += 1
                            replyFocused = false
                        }
                    } label: {
                        ComposerActionIcon(image: Image("ComposerSend"), primary: true, busy: sending)
                    }
                    .disabled(!canSend)
                    .fixedSize()
                    .accessibilityLabel("Send reply")
                    .accessibilityIdentifier("terminal-send-button")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, Self.replyBarTopPadding).padding(.bottom, Self.replyBarBottomPadding)
        // DRAG AND DROP, the other half of "get a file in from a Mac or an iPad". The
        // whole bar is the target, not just the field: a dragged file is aimed at the
        // composer, and a 40-point text view is a cruel thing to hit with a trackpad.
        // `.item` covers everything a Finder or Files drag vends, and each provider goes
        // through the SAME staging path as a paste, so the cap, the type rule and the
        // named-agent guard are shared rather than re-stated.
        .onDrop(of: [.item], isTargeted: $replyDropTargeted) { providers in
            acceptDroppedFiles(providers)
        }
        // THE PAPERCLIP, the same sheet and pickers as the Gram page and the guest pane.
        // Picks land in the same chip strip and send through the same
        // `sendPromptWithAttachments` as a paste or a drop.
        .composerAttachPicker(
            isPresented: $showReplyAttachSheet, loading: $loadingReplyAttachment,
            room: { GramView.Staging.maxAttachments - replyAttachments.count }
        ) { outcome in
            replyAttachments += outcome.files.map {
                PromptAttachment(id: UUID(), name: $0.name, mime: $0.mime, isImage: $0.isImage,
                                 size: $0.staged.size, staged: $0.staged, uploadID: nil, gramMessageID: nil)
            }
            actionNote = outcome.note
        }
        .overlay {
            if replyDropTargeted {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Palette.brand, lineWidth: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
        }
    }
    /// Stages every DROPPED file, one after another.
    ///
    /// A drop hands over the whole selection at once, and staging is serialised by
    /// `loadingReplyAttachment`: calling the paste handler for all of them in a loop
    /// staged the first and dropped the rest on that guard — silently, because it is the
    /// one bail-out with no note — while SwiftUI played the accept animation for the
    /// whole drag. So each provider waits for the previous one to land.
    ///
    /// Returns true when at least one provider is worth staging, which is what tells
    /// SwiftUI the drop was accepted.
    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            for provider in providers {
                // Up to five seconds per file: a staged copy of a large document off a
                // network volume is slow, and abandoning the rest of the drag is worse
                // than waiting.
                for _ in 0..<100 where loadingReplyAttachment {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard !loadingReplyAttachment else { break }
                // A decline is either the cap or a pane that cannot take attachments;
                // both have set their note, and both apply to every remaining file.
                guard pasteReplyAttachment(provider) else { break }
            }
        }
        return true
    }

    /// Stages a pasted FILE of any kind — a photo, a PDF, a log, a zip — as the reply's
    /// attachment. Returns false when this composer cannot take it (a send in flight, a
    /// pane with no named intent agent, or an item that vends no file type), so the caller
    /// pastes normally instead of swallowing the gesture.
    ///
    /// Only IMAGES used to be accepted, which made "paste a photo" work and "paste the log
    /// you just copied" silently do nothing. The delivery path never cared: staging, the
    /// Gram upload channel and the prompt reference are all byte-agnostic, so the image
    /// restriction was in the type filter alone.
    @discardableResult
    private func pasteReplyAttachment(_ provider: NSItemProvider) -> Bool {
        guard !sending, !loadingReplyAttachment, replyTakesAttachment() else { return false }
        let types = provider.registeredTypeIdentifiers.lazy.compactMap { UTType($0) }
        // A FILE URL WINS when the item carries one. A Finder copy of a document vends
        // the file url AND the document's ICON (com.apple.icns, which conforms to
        // public.image), so preferring the image staged a 288 KB icon called
        // "photo-31ec1fb2.icns" instead of the PDF the reader copied. Any image beside a
        // file url is derived from that file — an icon, a thumbnail, or, when the file IS
        // an image, the same bytes under a worse name.
        //
        // Without a file url the item is in-memory: a screenshot, an image copied out of
        // Safari, a PDF put on the pasteboard as data. Then an image wins over any other
        // concrete type, as before.
        guard let type = types.first(where: { $0.conforms(to: .fileURL) })
                ?? types.first(where: { $0.conforms(to: .image) })
                ?? types.first(where: { PastedFile.isAttachment($0) })
        else {
            return false
        }

        // A file url is a REFERENCE, not bytes: loading it as a file representation
        // yields a temp file containing the path text. Resolve it to the real file and
        // copy from there, inside a security scope, because a document picked outside the
        // app's container is only readable while that scope is open.
        if type.conforms(to: .fileURL) {
            loadingReplyAttachment = true
            ctrlArmed = false
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                var refusal: String?
                let attachment: PromptAttachment? = url.flatMap { source in
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let keys: Set<URLResourceKey> = [
                        .isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                    ]
                    let values = try? source.resourceValues(forKeys: keys)
                    // A DIRECTORY, refused before the copy. `stageCopy` would happily
                    // recurse a whole folder into tmp and only then fail its size check,
                    // which is an unbounded copy for a message that cannot carry it.
                    if values?.isDirectory == true {
                        refusal = "Folders can't be attached — pick the files inside."
                        return nil
                    }
                    // An iCloud placeholder has no bytes yet. Ask for the download and say
                    // so, instead of reporting the generic "couldn't add" for a file the
                    // reader can plainly see in Files.
                    if values?.isUbiquitousItem == true,
                       values?.ubiquitousItemDownloadingStatus != .current {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: source)
                        refusal = "\(source.lastPathComponent) isn't downloaded yet — "
                            + "opening it in Files once will fetch it."
                        return nil
                    }
                    let name = GramStaging.safeFileName(source.lastPathComponent)
                    guard !name.isEmpty,
                          let staged = GramView.Staging.copy(of: source, named: name)
                    else { return nil }
                    let fileType = UTType(filenameExtension: source.pathExtension)
                    return PromptAttachment(
                        id: UUID(), name: name,
                        mime: fileType?.preferredMIMEType ?? "application/octet-stream",
                        isImage: fileType?.conforms(to: .image) ?? false,
                        size: staged.size, staged: staged, uploadID: nil, gramMessageID: nil)
                }
                Task { @MainActor in
                    finishReplyAttachmentPaste(attachment)
                    if let refusal { actionNote = refusal }
                }
            }
            return true
        }

        loadingReplyAttachment = true
        ctrlArmed = false
        let typeIdentifier = type.identifier
        let isImage = type.conforms(to: .image)
        let ext = type.preferredFilenameExtension ?? (isImage ? "jpg" : "dat")
        let name: String = {
            var candidate = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if candidate.isEmpty {
                let stem = isImage ? "photo" : "file"
                candidate = "\(stem)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            }
            if URL(fileURLWithPath: candidate).pathExtension.isEmpty { candidate += ".\(ext)" }
            return GramStaging.safeFileName(candidate)
        }()
        let mime = type.preferredMIMEType ?? (isImage ? "image/jpeg" : "application/octet-stream")

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, _ in
            let fileAttachment: PromptAttachment? = source.flatMap { url in
                guard let staged = GramView.Staging.copy(of: url, named: name) else { return nil }
                return PromptAttachment(
                    id: UUID(), name: name, mime: mime, isImage: isImage, size: staged.size, staged: staged,
                    uploadID: nil, gramMessageID: nil)
            }
            if let fileAttachment {
                Task { @MainActor in finishReplyAttachmentPaste(fileAttachment) }
                return
            }

            // In-memory pasteboards can vend encoded bytes but no file URL.
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                let dataAttachment: PromptAttachment? = data.flatMap {
                    guard let staged = GramStaging.stageData(
                        $0, named: name, in: GramView.Staging.session,
                        maxBytes: GramView.Staging.maxFileBytes)
                    else { return nil }
                    return PromptAttachment(
                        id: UUID(), name: name, mime: mime, isImage: isImage, size: staged.size, staged: staged,
                        uploadID: nil, gramMessageID: nil)
                }
                Task { @MainActor in finishReplyAttachmentPaste(dataAttachment) }
            }
        }
        return true
    }

    /// Whether the reply can take one more attachment, the gate every way in shares:
    /// under the count cap, and a pane whose agent has a name and an intent prompt (the
    /// only destination `sendPromptWithAttachments` can deliver to). Says why when not.
    private func replyTakesAttachment() -> Bool {
        guard replyAttachments.count < GramView.Staging.maxAttachments else {
            actionNote = "Up to \(GramView.Staging.maxAttachments) attachments at a time."
            return false
        }
        guard let currentAgent = agent, router.mode(for: currentAgent) == .intent,
              currentAgent.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            actionNote = "Attachments need a named agent with a ready prompt."
            return false
        }
        return true
    }

    private func openReplyAttachSheet() {
        guard !sending, !loadingReplyAttachment, replyTakesAttachment() else { return }
        ctrlArmed = false
        showReplyAttachSheet = true
    }

    private func finishReplyAttachmentPaste(_ attachment: PromptAttachment?) {
        loadingReplyAttachment = false
        guard let attachment else {
            actionNote = "Couldn't add that attachment."
            return
        }
        // Belt and braces: `loadingReplyAttachment` already serialises pastes, so this
        // cannot currently fire. It stays because it is the only place that knows the
        // staged bytes exist, and a future concurrent paste path would otherwise append
        // past the cap and leak the temp file.
        guard replyAttachments.count < GramView.Staging.maxAttachments else {
            if let staged = attachment.staged {
                try? FileManager.default.removeItem(at: staged.dir)
            }
            actionNote = "Up to \(GramView.Staging.maxAttachments) attachments at a time."
            return
        }
        replyAttachments.append(attachment)
        actionNote = nil
    }

    private func removeReplyAttachment(_ attachment: PromptAttachment) {
        guard replyAttachments.contains(where: { $0.id == attachment.id }) else { return }
        replyAttachments.removeAll { $0.id == attachment.id }
        if let staged = attachment.staged {
            try? FileManager.default.removeItem(at: staged.dir)
        }
        // An attachment dropped AFTER its gram message posted (a batch that failed
        // halfway) must not leave that message behind in the agent's inbox.
        if let messageID = attachment.gramMessageID {
            Task { try? await client.gramDelete(id: messageID) }
        }
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
        // EVERY EXPLICIT HOST-SIDE INPUT cancels a retained resize frame, not just the
        // control-bar caps: this funnel also carries the reply submit, the saved-prompt
        // send and the raw sequences. The automatic pre-fill delivery is excluded on
        // purpose — nobody touched anything, so there is no user act to honour.
        if !autoDelivering { userInputToken += 1 }
        if case .submitText(let text) = action, !replyAttachments.isEmpty {
            sendPromptWithAttachments(text, attachments: replyAttachments)
            return
        }
        let mode = agent.map { router.mode(for: $0) } ?? .rawKeys
        let plan = router.plan(action: action, pane: paneID, mode: mode)
        // CLEARED NOW, NOT WHEN THE ROUND TRIP RETURNS.
        //
        // The composer is content-sized and the terminal takes whatever height is left,
        // so clearing the text RESIZES THE PTY. Doing it on the reply meant a second
        // resize hundreds of milliseconds to seconds after the keyboard had already
        // caused one: two reflows, two agent repaints and two retained frames for a
        // single send, the later one landing while the reader was still watching the
        // first settle. Clearing here folds that height change into the keyboard's own
        // sweep.
        //
        // It is still only ever THIS text: restored below if the send was refused or
        // did not land, and never over something typed since (the composer stays
        // editable for the whole round trip — see the `isEnabled` comment in replyBar).
        let clearedReply: String?
        if case .submitText(let text) = action, reply == text, !text.isEmpty {
            clearedReply = text
            reply = ""
        } else {
            clearedReply = nil
        }
        // An attachment batch keeps its caption until every upload and its prompt
        // have completed; its separate path above owns the late clear.
        func restoreClearedReply() {
            guard let clearedReply, reply.isEmpty else { return }
            reply = clearedReply
        }
        let isKeyAction: Bool
        switch plan {
        case .keys, .rawText: isKeyAction = true
        default: isKeyAction = false
        }
        // Keep rapid taps responsive, but dispatch their writes in order. A failure
        // cancels keys already queued behind it rather than silently changing a chord.
        let precedingKeySend = keySendTask
        let queuedEpoch = keyFailureEpoch
        let sequence: Int?
        if isKeyAction {
            keySendSequence += 1
            sequence = keySendSequence
        } else {
            sequence = nil
            sending = true
        }
        let task = Task {
            if let precedingKeySend { await precedingKeySend.value }
            defer {
                if !isKeyAction { sending = false }
                if let sequence, keySendSequence == sequence { keySendTask = nil }
            }
            if isKeyAction && keyFailureEpoch != queuedEpoch {
                return
            }
            do {
                switch plan {
                case .prompt(let pane, let text):
                    try await submitPrompt(pane: pane, text: text)
                case .text(let pane, let text):
                    try await client.sendText(pane: pane, text: text)
                    actionNote = nil
                case .rawText(let pane, let text):
                    try await client.sendText(pane: pane, text: text)
                    actionNote = nil
                case .keys(let pane, let keys):
                    try await client.sendKeys(pane: pane, keys: keys)
                    actionNote = nil
                case .refused(let reason):
                    actionNote = "not sent: \(reason)"
                    restoreClearedReply()
                    return
                }
                // The live stream provides output; only a prompt send needs to
                // re-resolve agent status and input mode.
                if !isKeyAction { await refresh() }
            } catch let apiError as APIError {
                if isKeyAction { keyFailureEpoch += 1 }
                if case .prompt = plan {
                    actionNote = Self.promptRejectionNote(for: apiError)
                    // A post-write/unknown rejection must not put text back for
                    // another tap; a definite pre-write rejection can be retried.
                    if !PromptRejection(apiError).mayHaveReachedAgent {
                        restoreClearedReply()
                    }
                } else if isKeyAction {
                    let prefix = apiError.code == "timeout"
                        ? "Key delivery uncertain — check the terminal"
                        : "send failed: \(apiError)"
                    let suffix = sequence.map { keySendSequence > $0 } == true
                        ? "; later queued keys were not sent" : ""
                    actionNote = prefix + suffix
                } else {
                    actionNote = "send failed: \(apiError)"
                    restoreClearedReply()
                }
            } catch {
                if isKeyAction {
                    keyFailureEpoch += 1
                    let suffix = sequence.map { keySendSequence > $0 } == true
                        ? "; later queued keys were not sent" : ""
                    actionNote = "Key delivery uncertain — check the terminal before trying again" + suffix
                } else if case .prompt = plan {
                    // A transport failure does not prove whether the server wrote
                    // bytes before losing the response. Don't invite a blind resend.
                    actionNote = "couldn't confirm delivery — check the terminal before sending again"
                } else {
                    actionNote = "send failed: \(error)"
                    restoreClearedReply()
                }
            }
        }
        if isKeyAction { keySendTask = task }
    }
    /// Uploads and posts every staged attachment, then submits ONE prompt naming them
    /// all.
    ///
    /// SERIAL on purpose. `gram.post` consumes each staging file, so one upload in
    /// flight at a time keeps the daemon's 1 GiB aggregate staging budget clear no
    /// matter how many files are staged; ten parallel 100 MiB uploads would fill it and
    /// fail gram uploads for every client on the box.
    ///
    /// A file that already uploaded or already posted is skipped on a retry: each
    /// attachment carries its own `uploadID` / `gramMessageID`, written back into
    /// `replyAttachments` as soon as it is known, so tapping Send again after a mid-batch
    /// failure re-sends only what did not land.
    private func sendPromptWithAttachments(_ text: String, attachments: [PromptAttachment]) {
        // The destination is captured BEFORE the first await: `agent` is re-resolved on
        // every refresh, and a batch can span minutes.
        guard !sending, let currentAgent = agent, router.mode(for: currentAgent) == .intent,
              let target = currentAgent.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            actionNote = "Attachments need a named agent with a ready prompt."
            return
        }

        sending = true
        let precedingKeySend = keySendTask
        Task {
            if let precedingKeySend { await precedingKeySend.value }
            replyFailedAttachmentID = nil
            defer { sending = false; replyUploadBytes = nil; replySendingAttachmentID = nil }
            var delivered: [(attachment: PromptAttachment, messageID: String)] = []
            do {
                for attachment in attachments {
                    replySendingAttachmentID = attachment.id
                    var current = attachment
                    var messageID = current.gramMessageID
                    if messageID == nil {
                        let uploadID: String
                        if let existing = current.uploadID {
                            uploadID = existing
                        } else {
                            guard let staged = current.staged else {
                                replyFailedAttachmentID = current.id
                                actionNote = Self.attachmentFailureNote(
                                    "Couldn't read \(current.name).",
                                    delivered: delivered.count, total: attachments.count)
                                return
                            }
                            replyUploadBytes = (sent: 0, total: staged.size)
                            uploadID = try await client.gramUploadFile(fileURL: staged.url) { sent, total in
                                replyUploadBytes = (sent: sent, total: total)
                            }
                            replyUploadBytes = nil
                            current = PromptAttachment(
                                id: current.id, name: current.name, mime: current.mime,
                                isImage: current.isImage, size: current.size, staged: staged, uploadID: uploadID,
                                gramMessageID: nil)
                            rememberReplyAttachment(current)
                        }

                        let file = HerdrClient.GramFileAttachment(
                            uploadID: uploadID, name: current.name, mime: current.mime)
                        let posted = try await Self.postReplyAttachment(
                            client: client, target: target, attachment: file)
                        messageID = posted.id
                        if let staged = current.staged {
                            try? FileManager.default.removeItem(at: staged.dir)
                        }
                        current = PromptAttachment(
                            id: current.id, name: current.name, mime: current.mime,
                            isImage: current.isImage, size: current.size, staged: nil, uploadID: nil,
                            gramMessageID: posted.id)
                        rememberReplyAttachment(current)
                    }

                    guard let messageID else {
                        replyFailedAttachmentID = current.id
                        actionNote = Self.attachmentFailureNote(
                            "Couldn't deliver \(current.name).",
                            delivered: delivered.count, total: attachments.count)
                        return
                    }
                    delivered.append((attachment: current, messageID: messageID))
                }
                replyUploadBytes = nil
                replySendingAttachmentID = nil

                let prompt = GramAttachmentPrompt.text(text, delivered: delivered.map {
                    GramAttachmentPrompt.Delivered(
                        name: $0.attachment.name, isImage: $0.attachment.isImage, messageID: $0.messageID)
                })
                // A rejection that may still have reached the agent (`PromptRejection`)
                // counts as DELIVERED here, exactly like a confirmed submit: the prompt is
                // in the agent's PTY, so keeping the chips and the caption would make the
                // one-tap retry submit it a second time (the grams themselves are
                // remembered by message id; it is the prompt that would duplicate). Only a
                // genuine non-delivery keeps everything for the retry.
                do {
                    try await submitPrompt(pane: paneID, text: prompt)
                } catch let apiError as APIError {
                    guard PromptRejection(apiError).mayHaveReachedAgent else {
                        actionNote = Self.attachmentFailureNote(
                            Self.promptRejectionNote(for: apiError),
                            delivered: delivered.count, total: attachments.count)
                        return
                    }
                    actionNote = Self.promptRejectionNote(for: apiError)
                } catch {
                    actionNote = "couldn't confirm delivery — check the terminal before sending again"
                }
                // Only a definite pre-write rejection keeps the chips and caption
                // for a one-tap retry. A lost response may follow a PTY write, so
                // unknown delivery also clears them rather than duplicating a prompt.
                let deliveredIDs = Set(delivered.map(\.attachment.id))
                replyAttachments.removeAll { deliveredIDs.contains($0.id) }
                if reply == text { reply = "" }
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refresh()
            } catch {
                replyFailedAttachmentID = replySendingAttachmentID
                actionNote = Self.attachmentFailureNote(
                    "send failed: \(error)",
                    delivered: delivered.count, total: attachments.count)
            }
        }
    }

    /// Write an attachment's new upload/post state back into the staged list, so a retry
    /// after a mid-batch failure skips the work that already succeeded.
    private func rememberReplyAttachment(_ attachment: PromptAttachment) {
        guard let index = replyAttachments.firstIndex(where: { $0.id == attachment.id })
        else { return }
        replyAttachments[index] = attachment
    }

    /// Says how much of a batch landed before the failure, so a retry is an informed act
    /// rather than a guess. Posted grams are NOT rolled back: their chips keep their
    /// message id and the retry skips straight to the prompt.
    static func attachmentFailureNote(_ reason: String, delivered: Int, total: Int) -> String {
        guard total > 1, delivered > 0 else { return reason }
        return "Sent \(delivered) of \(total). \(reason)"
    }

    private static func postReplyAttachment(
        client: HerdrClient,
        target: String,
        attachment: HerdrClient.GramFileAttachment
    ) async throws -> GramMessage {
        for attempt in 0..<3 {
            do {
                return try await client.gramPost(
                    text: "Attachment from the terminal composer.",
                    to: target,
                    attachment: attachment)
            } catch let error as APIError where error.code == "upload_in_progress" {
                if attempt == 2 { throw error }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw GramError.invalidFileData
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

    /// A successful PTY write is not proof that the agent submitted a turn.
    /// Keep its receipt visible rather than inviting a duplicate send.
    private func submitPrompt(pane: String, text: String) async throws {
        let result = try await client.prompt(
            pane: pane, text: text,
            waitUntil: HerdrClient.anyAgentStatus, timeoutMs: 6000)
        switch result {
        case .submitted:
            actionNote = nil
        case .writtenToPty:
            actionNote = "Sent to terminal; agent submission not verified"
        case nil:
            actionNote = "couldn't confirm delivery — check the terminal before sending again"
        }
    }

    /// Maps a prompt rejection to a note the reader can act on — no more silent
    /// non-delivery, and no false "send failed" for text the agent may already have.
    ///
    /// Driven by the same `PromptRejection` the send paths use to decide whether to
    /// hand the text back, so the note can never say "failed" while the composer stays
    /// empty, or "sent" while the text comes back for a resend.
    private static func promptRejectionNote(for error: APIError) -> String {
        switch PromptRejection(error) {
        case .unconfirmed:
            return "Couldn't tell whether the prompt reached the terminal — check before sending again"
        case .writtenUnverified:
            return "Sent to terminal; agent submission not verified"
        case .submittedStatusUnknown:
            return "Prompt submitted; requested agent state not confirmed — check the terminal"
        case .leftInComposer:
            return "left unsubmitted in the agent's prompt — tap Enter to send it"
        case .notDelivered:
            break
        }
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
    private func sendTapped(_ text: String? = nil) {
        // An explicit Send ALWAYS takes over from any pending auto-deliver and goes
        // through the normal prompt path (`send` → agent.prompt, server-gated). It must
        // never be gated on the pre-fill delivery succeeding — that is exactly what could
        // trap the reader on a stuck pre-fill with the reply bar locked.
        pendingPrefill = false
        send(.submitText(text ?? reply))
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
    case machines, accounts, notifications, sharedAccess, about, appearance

    var label: String {
        switch self {
        case .machines:      return "Machines"
        case .accounts:      return "Accounts"
        case .notifications: return "Notifications"
        case .sharedAccess:  return "Shared access"
        case .about:         return "App & About"
        case .appearance:    return "Text size"
        }
    }

    var icon: String {
        switch self {
        case .machines:      return "server.rack"
        case .accounts:      return "key.horizontal"
        case .notifications: return "bell"
        case .sharedAccess:  return "person.2"
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
    /// Saved machines include profiles that have no agents yet; the agent-derived
    /// peer list remains a fallback for an older daemon without `machine.status`.
    @State private var savedMachines: [SavedMachineStatus]?
    @State private var pendingFederate: SavedMachineStatus?
    @State private var federationBusyID: String?
    @State private var federationError: String?
    /// Whether the connected machine can send push (`notifications.status`); nil until the first
    /// answer. Refreshed with the permission on appear and on foreground.
    @State private var pushAvailability: PushAvailability?
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
    /// Settings → Shared access: guests, pending invites and the activity log, across machines.
    @StateObject private var guestAccess = GuestAccessModel()
    @Environment(\.guestMachineLabel) private var guestMachineLabel

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
        .confirmationDialog(
            pendingFederate.map { "Federate \($0.displayLabel)?" } ?? "",
            isPresented: Binding(
                get: { pendingFederate != nil },
                set: { if !$0 { pendingFederate = nil } }
            ),
            presenting: pendingFederate
        ) { machine in
            Button("Allow federation") { Task { await changeFederation(machine, enabled: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The coordinator will keep an SSH connection to this machine and can control its Herdr session.")
        }
        .alert(
            "Federation status",
            isPresented: Binding(
                get: { federationError != nil },
                set: { if !$0 { federationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(federationError ?? "")
        }
        // Load the tip products when Settings opens. No-ops after a successful load;
        // re-tries after a prior failure, so products created in ASC later appear.
        .task { await tipStore.loadProducts() }
        // Fetch the credential accounts for the Accounts section when Settings opens.
        // `try?` so an older daemon without `accounts.list` (or a transient failure)
        // just leaves the section empty rather than surfacing an error here.
        .task { accounts = (try? await client.accountsList()) ?? [] }
        .task {
            savedMachines = try? await client.machineStatuses()
            // A saved machine that runs no agents is only known from `machine.status`, and it
            // can still hold guests: read Shared access again once the profiles arrive.
            await loadGuestAccess()
        }
        // Fetch the daemon version + any staged self-update. `try?` so an older daemon without
        // `server.staged_update` leaves it nil (version line + update callout simply absent).
        .task { stagedUpdate = try? await client.stagedUpdate() }
        // The Shared access row's summary; `try?`-style degrade lives in the model.
        .task { await loadGuestAccess() }
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
        // Keep the notify section honest: the iOS permission and whether this machine can push,
        // on open and again when the app returns to the foreground (the user may have flipped
        // the permission in iOS Settings, or changed Herdr's push config meanwhile).
        .onAppear { refreshNotifyAuth() }
        .task { await refreshPushAvailability() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshNotifyAuth()
            Task { await refreshPushAvailability() }
        }
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
                        // Grouped subviews keep this builder under SwiftUI's 10-child
                        // ViewBuilder ceiling (8 children + the footers Group = 9, so
                        // one slot left: the next section needs its own Group).
                        VStack(alignment: .leading, spacing: 0) {
                            atAGlanceSection
                            manageSection
                            appearanceSection
                            previewsSection
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
        case .sharedAccess:  sharedAccessDetail(showBack: showBack)
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

    private func sharedAccessDetail(showBack: Bool) -> some View {
        detailScaffold(title: "Shared access", subtitle: guestAccess.summary, showBack: showBack) {
            GuestAccessSection(client: client, model: guestAccess) { await loadGuestAccess() }
        }
        .task { await loadGuestAccess() }
        .refreshable { await loadGuestAccess() }
    }

    /// The connected machine plus every federated peer: each keeps its own guest store,
    /// which the coordinator reaches by the peer's alias.
    private func loadGuestAccess() async {
        let machines = GuestMachine.directory(
            localLabel: guestMachineLabel.isEmpty ? host : guestMachineLabel,
            savedMachines: savedMachines ?? [], agentPeers: machinePeers)
        await guestAccess.load(client: client, machines: machines)
    }

    /// iPad "App & About": the light sections that stay inline on the iPhone index.
    private func aboutDetail(showBack: Bool) -> some View {
        detailScaffold(title: "App & About", subtitle: "Previews, trouble, help, support & legal",
                       showBack: showBack) {
            previewsSection
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
                Text(title).font(Typography.app(34, .bold)).foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
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
            .settingsGroup()
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
            .padding(.horizontal, 18).padding(.vertical, 13)
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
        .padding(.horizontal, 18).padding(.vertical, 13)
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
            .padding(.horizontal, 18).padding(.vertical, 13)
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
        .padding(.horizontal, 18).padding(.vertical, 13)
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
                manageRow(.notifications, subtitle: "Push alerts from this machine") { manageNotifyTrailing }
                rowDivider
                manageRow(.sharedAccess, subtitle: "People you share an agent with") { manageSharedTrailing }
            }
            .settingsGroup()
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func manageRow<Trailing: View>(
        _ section: SettingsSection, subtitle: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.label).font(Typography.app(17)).foregroundStyle(Palette.text)
                    Text(subtitle).font(Typography.app(13)).foregroundStyle(Palette.textDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minHeight: 52)
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

    @ViewBuilder private var manageSharedTrailing: some View {
        Text(guestAccess.summary).font(Typography.machine(12)).foregroundStyle(Palette.textDim)
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
                .font(Typography.app(34, .bold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
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
            .settingsRowShell()
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
    /// apply is in flight). Mirrors `notifyCallout`'s shape, in its own hairline card.
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
            .settingsRowShell()
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

    /// Saved machine profiles include ones not yet opted into federation. The
    /// agent-derived list remains the fallback for older Herdr servers.
    @ViewBuilder
    private var federationSection: some View {
        let peers = PeerSummary.peerSummaries(from: agents)
        let machines = savedMachines ?? []
        let extraPeers = peers.filter { peer in
            !machines.contains { $0.profileID == peer.alias }
        }
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("FEDERATION")
            if machines.isEmpty && extraPeers.isEmpty {
                federationEmpty
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                        savedMachineRow(machine, peer: peers.first { $0.alias == machine.profileID })
                        if index < machines.count - 1 || !extraPeers.isEmpty { rowDivider }
                    }
                    ForEach(Array(extraPeers.enumerated()), id: \.element.id) { index, peer in
                        peerRow(peer)
                        if index < extraPeers.count - 1 { rowDivider }
                    }
                }
                .settingsGroup()
                .padding(.horizontal, 16).padding(.top, 10)
            }
            richActionRow("How to add a machine", systemImage: "plus.circle",
                          subtitle: "Connect another computer to your home box") {
                showFederationSetup = true
            }
        }
    }

    private func changeFederation(_ machine: SavedMachineStatus, enabled: Bool) async {
        federationBusyID = machine.profileID
        defer { federationBusyID = nil }
        do {
            try await client.setMachineFederation(profileID: machine.profileID, enabled: enabled)
        } catch {
            federationError = "Change failed: \(error)"
            return
        }
        do {
            savedMachines = try await client.machineStatuses()
        } catch {
            federationError = "Change applied, but status could not refresh: \(error)"
        }
    }

    private func savedMachineRow(_ machine: SavedMachineStatus, peer: PeerSummary?) -> some View {
        let state: String
        if machine.savedState == "disabled" {
            state = "Disabled"
        } else if machine.savedState == "coordinator_disabled" {
            state = "Coordinator off"
        } else if machine.hasFederationPolicy {
            state = machine.federationReachability ?? "Connecting"
        } else {
            state = "Not federated"
        }
        var detail = state
        if let peer {
            detail += " · \(peer.agentCount) agent\(peer.agentCount == 1 ? "" : "s")"
        }
        if machine.stale { detail += " (stale)" }
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AgentIdentity.gradient(for: machine.displayLabel))
                    .frame(width: 40, height: 40)
                Text(AgentIdentity.glyph(for: machine.displayLabel))
                    .font(Typography.app(18, .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.displayLabel)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text(detail)
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 8)
            if let peer { peerBadge(peer.reachability) }
            if federationBusyID == machine.profileID {
                ProgressView()
            } else {
                Button(machine.hasFederationPolicy ? "Unfederate" : "Federate") {
                    if machine.hasFederationPolicy {
                        Task { await changeFederation(machine, enabled: false) }
                    } else {
                        pendingFederate = machine
                    }
                }
                .font(Typography.app(13, .semibold))
                .disabled(federationBusyID != nil || (machine.savedState == "disabled" && !machine.hasFederationPolicy))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Local-only: no agent carries a machineID, so there are no remote peers yet.
    /// Explainer copy in the section body rather than a bare empty card.
    private var federationEmpty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No saved machines yet.")
                .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            Text("Save an SSH machine on your home box, then opt it into federation here.")
                .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .settingsGroup()
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
                Text(peer.displayName)
                    .font(Typography.app(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Text("\(peer.agentCount) agent\(peer.agentCount == 1 ? "" : "s")")
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 8)
            peerBadge(peer.reachability)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
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
                .settingsGroup()
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
        .padding(.horizontal, 18).padding(.vertical, 14)
        .settingsGroup()
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
        .padding(.horizontal, 18).padding(.vertical, 12)
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
        // STACKED, not side by side, and the pill never wraps.
        //
        // The status sat BESIDE the meters in an HStack, and an exhausted account that
        // also reports usage — the common case, since hitting 100% is what exhausts it —
        // demanded meter width plus pill width on one line. Two things broke, both
        // visible in the owner's screenshot: `Text("exhausted")` has no line limit, so
        // under that pressure it wrapped to one letter per line and grew a ~9-line tall
        // red capsule that doubled the row height; and the width it took left the label
        // column so narrow that "Claude Pro (personal)" truncated to "C…".
        //
        // Putting the status under the meters removes the competition, and
        // `fixedSize` + `lineLimit(1)` mean the pill keeps its intrinsic width whatever
        // the row does. An active account's dot is small enough that stacking it costs
        // nothing.
        VStack(alignment: .trailing, spacing: 6) {
            if !windows.isEmpty {
                ForEach(windows) { window in
                    usageMeter(window, live: account.usage?.source == "live")
                }
            }
            if account.active {
                Circle().fill(Palette.done).frame(width: 8, height: 8)
                    .accessibilityLabel(Text("active"))
            } else {
                Text("exhausted")
                    .font(Typography.app(11, .semibold)).foregroundStyle(Palette.died)
                    .lineLimit(1)
                    .fixedSize()
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
            // SPLIT, so the degradation is chosen rather than emergent.
            //
            // Two earlier shapes were both wrong. `fixedSize()` on the whole readout made
            // the meter rigid and squeezed the account label to ~70pt on a 393pt phone.
            // Making the whole readout flexible then let it absorb the entire deficit and
            // truncate the WINDOW LABEL — "42% · 5…" and "68% · w…" — so two stacked
            // meters could not be told apart, which is worse than a short name.
            //
            // The percent and window label are the meter's meaning and stay rigid; they
            // are short and bounded ("100% · weekly" is the widest). The reset hint is
            // the only genuinely optional token, so it is the one that truncates, and it
            // does so before the account label because the label column no longer holds
            // a blanket priority.
            Text(usageEssential(window, percent: clamped))
                .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                .fixedSize()
            if let hint = resetHint(window.resetsAt) {
                Text("· \(hint)")
                    .font(Typography.machine(11)).foregroundStyle(Palette.textDim)
                    .lineLimit(1)
            }
        }
        // ONE element carrying the WHOLE reading. Splitting the readout for layout must
        // not split it for VoiceOver, and the hint may be visually truncated — so the
        // spoken label is the full string, plus liveness, which was previously a separate
        // "live" element on the dot.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            usageMeterLabel(window, percent: clamped) + (live ? " · live" : "")))
        // A read-only readout, declared as such. Without this trait the merged container
        // carries a label but no type, so it is not exposed as a static text — and the
        // receipt asserting the window label survived queries `staticTexts`, which the
        // merge above had silently emptied of the child Texts that used to carry it.
        .accessibilityAddTraits(.isStaticText)
    }

    /// The meter's MEANING: "NN% · <window>". Rigid in the layout, because a meter whose
    /// window label truncated to "w…" cannot be distinguished from the one stacked above
    /// it. Widest real value is "100% · weekly".
    private func usageEssential(_ window: UsageWindow, percent: Double) -> String {
        "\(Int(percent.rounded()))% · \(window.label)"
    }

    /// "NN% · <label>" plus a compact reset token when present, e.g. "42% · 5h · 2h left"
    /// or "68% · weekly · Aug 31". Still used for the accessibility value, which must
    /// carry the whole reading even when the hint is visually truncated.
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
                if let fix = notifyPermissionFix {
                    rowDivider
                    notifyPermissionRow(fix)
                }
                rowDivider
                pushMachineRow
            }
            .settingsGroup()
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    /// Starts at the 18 pt leading inset every Settings row uses (#357), so it lines up
    /// with the first thing in each row: the label, or the status dot / icon chip of the
    /// glance and notify-callout rows.
    private var rowDivider: some View {
        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 18)
    }

    /// A toggle row WITHOUT its own border — the group around it supplies one border for
    /// all of them. #357: a standard switch (on-tint brand) replaces the ON/OFF word; the
    /// whole row stays the tap target, so tapping the label still flips it.
    private func groupedToggleRow(_ label: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack {
                Text(label).font(Typography.app(17)).foregroundStyle(Palette.text)
                Spacer()
                Toggle("", isOn: .constant(value.wrappedValue))
                    .labelsHidden()
                    .tint(Palette.brand)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(value.wrappedValue ? "on" : "off"))
    }

    /// One status callout in the notify card: an icon chip, a title, a short explanation, and
    /// an optional action. Shared by the iOS-permission row and the machine row.
    private func notifyCallout<Action: View>(
        icon: String, tint: Color, title: String, body: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.textDim)
                Text(body)
                    .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    /// The SYSTEM notification permission, shown only when it needs fixing: if it's off (never
    /// asked, or denied), the toggles alone deliver nothing, so this offers the fix — a prompt
    /// (notDetermined) or a jump to iOS Settings (denied) — instead of failing silently.
    @ViewBuilder
    private func notifyPermissionRow(_ fix: NotifyPermissionFix) -> some View {
        switch fix {
        case .needAllow:
            notifyCallout(
                icon: "bell", tint: Palette.textDim, title: "Turn on notifications",
                body: "Allow notifications so these alerts can reach you when an agent needs you or a gram arrives."
            ) {
                Button("Allow notifications") { requestNotifications() }
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                    .padding(.top, 2)
            }
        case .denied:
            notifyCallout(
                icon: "bell.slash", tint: Palette.waiting, title: "Notifications are off",
                body: "herdrup can't send these alerts until you allow notifications in iOS Settings."
            ) {
                Button("Open Settings") { openIOSSettings() }
                    .font(Typography.app(13, .semibold)).foregroundStyle(Palette.text)
                    .padding(.top, 2)
            }
        }
    }

    /// Whether the connected machine can actually send push, from its `notifications.status`.
    /// The iOS permission above and this are independent: both must hold for an alert to arrive.
    private var pushMachineRow: some View {
        let (icon, tint, title, body) = pushMachineCopy
        return notifyCallout(icon: icon, tint: tint, title: title, body: body) { EmptyView() }
            .accessibilityIdentifier("settings-push-machine")
    }

    private var pushMachineCopy: (String, Color, String, String) {
        switch pushAvailability {
        case nil:
            return ("bell", Palette.textFaint, "Checking this machine…", "Asking Herdr whether it can send notifications.")
        case .unreachable:
            return ("bell", Palette.textFaint, "Couldn't check this machine",
                    "Herdr didn't answer. Reopen Settings to check again.")
        case .daemonTooOld:
            return ("arrow.down.circle", Palette.waiting, "Update Herdr on this machine to get notifications",
                    "This version of Herdr can't send notifications to your iPhone.")
        case .status(let status):
            switch status.state {
            case .relayReady:
                return ("bell.badge", Palette.done, "Notifications are on",
                        "This machine sends alerts through the HerdrUp push relay.")
            case .directReady:
                return ("bell.badge", Palette.done, "Notifications are on",
                        "This machine sends alerts with its own Apple push key.")
            case .unconfigured where status.mode == "direct":
                return ("bell.slash", Palette.waiting, "This machine can't send notifications yet",
                        "Herdr is set to push directly but has no Apple push key. Set push.mode to \"auto\" in Herdr's config to use the HerdrUp relay.")
            case .unconfigured:
                return ("bell.slash", Palette.waiting, "This machine can't send notifications yet",
                        "This iPhone hasn't joined the HerdrUp push relay yet. Allow notifications, then reopen HerdrUp while connected.")
            case .off:
                return ("bell.slash", Palette.textDim, "Notifications are turned off in Herdr on this machine",
                        "Set push.mode to \"auto\" in Herdr's config on this machine to turn them on.")
            case .unsupported:
                return ("bell.slash", Palette.waiting, "This machine can't send notifications",
                        "Herdr is running without its server here. Start Herdr normally to get notifications.")
            }
        }
    }

    /// Ask the connected machine whether it can push. On appear and on foreground, so a config
    /// change or a fresh relay enrollment shows up without reconnecting.
    private func refreshPushAvailability() async {
        pushAvailability = await client.pushAvailability()
    }

    /// At least one alert category is on. A permission FIX is only surfaced when this is
    /// true — if every toggle is off the system permission is moot, so we neither prompt
    /// nor point to Settings (matching AppDelegate.requestAuthorizationIfWanted's gating).
    private var anyNotifyOn: Bool { notifyNeedsInput || notifyDies || notifyFinishes || notifyGram }

    private enum NotifyPermissionFix { case needAllow, denied }
    private var notifyPermissionFix: NotifyPermissionFix? {
        guard anyNotifyOn else { return nil }
        switch notifyAuth {
        case .notDetermined: return .needAllow
        case .denied: return .denied
        default: return nil
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
    /// Whether a RECEIVED html/svg preview may run script. OFF by default — see
    /// `previewsSection` and `HtmlWebView`.
    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false

    /// "HTML previews" — the one switch that loosens how a RECEIVED html/svg attachment
    /// is rendered. Off by default and stated plainly, because the document is written
    /// by whoever sent it: script stays off unless the reader turns it on for this
    /// device. The row under the switch has to be accurate about what stays true, and
    /// what does not: remote loads and navigation are still blocked, but a script can
    /// signal that the file was opened by a route no URL rule sees.
    private var previewsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("HTML PREVIEWS")
            VStack(spacing: 0) {
                groupedToggleRow("Run JavaScript", $previewJavaScript)
                rowDivider
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: previewJavaScript ? "exclamationmark.triangle" : "lock.shield")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(previewJavaScript ? Palette.waiting : Palette.textDim)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.surfaceRaised))
                    Text(previewJavaScript
                         ? "Scripts in a previewed file will run. It still can't load anything from the network or open another page, but a file written to do so could signal that you opened it. Applies to the next preview you open."
                         : "Scripts in a previewed file are ignored, and it can't load anything from the network. Turn this on only for a file you trust that needs to be interactive.")
                        .font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .settingsGroup()
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

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
                .padding(.horizontal, 18).padding(.vertical, 14)
                rowDivider
                HStack(spacing: 10) {
                    textSizeButton("A\u{2212}", enabled: canDecrease, onDecrease)
                    textSizeButton("Reset", enabled: canReset, onReset)
                    textSizeButton("A+", enabled: canIncrease, onIncrease)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .settingsGroup()
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

    /// #357: A− / Reset / A+ as three equal round buttons, 38 pt tall, `surfaceRaised`;
    /// a disabled step is dimmed rather than hidden so the row never changes shape.
    private func textSizeButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(15, .semibold))
                .foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Capsule().fill(Palette.surfaceRaised.opacity(enabled ? 1 : 0.5)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
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
            discordRow
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
                .settingsGroup()
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
            .padding(.horizontal, 18).padding(.vertical, 14)
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

    /// #357: today's uppercase labels as small spaced-out caps, without the trailing rule.
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(Typography.microLabel).tracking(1.4).foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34).padding(.top, 22).padding(.bottom, 4)
    }

    private func actionRow(_ label: String, enabled: Bool = true, note: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button { if enabled { action() } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(17)).foregroundStyle(enabled ? Palette.text : Palette.textFaint)
                    if !enabled, let note {
                        Text(note).font(Typography.app(11)).foregroundStyle(Palette.textFaint)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .settingsRowShell()
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
        richActionRow(label, subtitle: subtitle, trailingGlyph: trailingGlyph, action: action) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
        }
    }

    /// The same row with its leading glyph supplied by the caller.
    ///
    /// Every row here uses an SF Symbol except Discord, which has no SF Symbol and draws
    /// Discord's own asset from an imageset instead. That row also opts out of the chip's
    /// tint, because its mark has to stay in Discord's colour — see `discordRow`.
    ///
    /// The chip is `accessibilityHidden`: the row's own label is the accessible name, and
    /// a decorative mark adds nothing to it.
    private func richActionRow<Leading: View>(
        _ label: String, subtitle: String? = nil,
        trailingGlyph: String = "chevron.right",
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // #357: a plain 24 pt glyph in textDim, no tile.
                leading()
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Typography.app(17)).foregroundStyle(Palette.text)
                    if let subtitle {
                        Text(subtitle).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    }
                }
                Spacer()
                Image(systemName: trailingGlyph)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textFaint)
            }
            .settingsRowShell()
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

    /// The community invite, with Discord's official symbol.
    ///
    /// The mark is `Shared/Assets.xcassets/DiscordMark.imageset`, downscaled from
    /// `Discord-Symbol-Blurple.png` in Discord's own brand kit
    /// (`cdn.discordapp.com/assets/content/a736b959…zip`, `Discord_Symbol_Color/`) — their
    /// file, their blurple, not a redraw. The three scales are 33x25, 66x50 and 99x75,
    /// which are exact reductions of the 528x400 source, so no scale distorts the mark.
    /// Provenance, what was done to the file, and the trademark position are recorded in
    /// `NOTICE-Discord-Brand.txt` at the repository root — root deliberately, because
    /// `Shared/` is a sources path and a stray text file there can end up copied into the
    /// bundle as a resource.
    ///
    /// An earlier version drew `fa-discord` from the bundled Nerd Fonts subset instead.
    /// That was withdrawn on the trademark question, not the licence one: Font Awesome
    /// Free ships under CC BY 4.0 with attribution already in the bundle, but CC BY
    /// grants no trademark rights, and the row was tinting a third-party redraw grey.
    private var discordRow: some View {
        richActionRow("Join the Discord", trailingGlyph: "arrow.up.right",
                      action: { openURL(Self.discordInvite) }) {
            // DISCORD'S OWN ASSET, IN DISCORD'S OWN COLOUR, and both halves are the point.
            //
            // This was a Font Awesome redraw taken from the bundled Nerd Fonts subset,
            // tinted `Palette.textDim` grey to match the rows around it. The licence side
            // of that was clean (CC BY 4.0, attribution shipped), but CC BY grants no
            // TRADEMARK rights, and Discord's brand policy asks for the official mark in
            // an approved colour. Owner's decision was the official asset.
            //
            // `.renderingMode(.original)` is load-bearing: without it the chip's
            // `foregroundStyle(Palette.textDim)` from `richActionRow` would tint blurple
            // to grey and put us back in the same place. This is the one icon in Settings
            // that is deliberately NOT monochrome.
            //
            // Sized by WIDTH with `scaledToFit`: the mark is 1.32:1, so a square frame
            // would either letterbox it or distort it, and the 30x30 chip is square.
            Image("DiscordMark")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 18)
        }
        .accessibilityIdentifier("settings-discord")
    }

    /// The invite. A raw code rather than a vanity URL. The previous code, TTFRHFyDXf,
    /// was believed never to expire but did (#302). This one was checked on 2026-09-28
    /// with Discord's invite API: `expires_at` is null. Nothing in the app or in CI can
    /// detect a dead invite, and correcting one needs an App Store release, so re-check
    /// it before each release; if it is ever rotated, prefer a vanity URL.
    private static let discordInvite = URL(string: "https://discord.gg/pq7qj4dDqt")!

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
struct ReadableColumn: ViewModifier {
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

    /// `rowShell` for a Settings row (#357): a single-row group, min 52 pt.
    func settingsRowShell() -> some View {
        self
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .settingsGroup()
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    /// One Settings group (#357 "HerdrUp voice"): a `surface` inset group, radius 18, with
    /// a 1 pt `hairlineQuiet` outline.
    func settingsGroup() -> some View {
        self
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairlineQuiet, lineWidth: 1))
    }
}

extension View {
    /// Center + cap a column at a comfortable reading width on wide canvases;
    /// inert on iPhone (narrower than `cap`). See `ReadableColumn`. Module-wide so the
    /// connect screen, Settings and Gram's feed share one definition.
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
/// Gram screenshot/UI-test harness (`HERDR_SCREENSHOT_MOCK=gram`). `GramView`'s Inbox/Saved
/// selection is a binding owned by the host (on regular width the selector lives in the app's
/// split-view sidebar), and `mockView` is a function that cannot hold `@State` — so this holds
/// it, exactly as `PagingTestHarness` holds the pane slots for its harness.
struct GramScreenshotHarness: View {
    let client: HerdrClient
    @State private var showingSaved = false

    var body: some View {
        // Empty `agents` keeps the recipient picker to the shared queue; `onClose` nil hides the
        // close X (there is nothing to dismiss to in a standalone render).
        GramView(client: client, agents: [], onClose: nil, showingSaved: $showingSaved)
    }
}

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

/// Renders the received-document viewer over a file that tries to REWRITE ITSELF with
/// script, so a UI receipt can read the rendered text and see whether the Settings
/// switch let it run. Reads the same `@AppStorage` key `GramView` reads and passes it
/// to the same view, so the receipt covers the shipping wiring rather than a stand-in.
#if DEBUG
struct HtmlPreviewHarness: View {
    @AppStorage(WebViewPolicy.javaScriptDefaultsKey) private var previewJavaScript = false

    /// The paragraph says the safe thing; the script replaces it. Whichever sentence
    /// the webview ends up showing IS the answer, and it is plain DOM text, which
    /// XCUITest reads out of the web view.
    private static let document = """
    <!doctype html><meta charset="utf-8">
    <body style="font:17px -apple-system;padding:24px">
    <p id="out">script did not run</p>
    <script>document.getElementById("out").textContent = "script ran";</script>
    </body>
    """

    var body: some View {
        HtmlWebView(html: Self.document, allowsJavaScript: previewJavaScript)
            .ignoresSafeArea(edges: .bottom)
    }
}
#endif

enum ScreenshotMock {
    case onboarding, pairingGuidance, list, rosterStress, pane, settings, newAgent, scroll, ccscroll, busyScroll, paging, backfill, gram, resize, control, htmlPreview, widgets
    case guestAccept, guest, guestPane, guestPaused, guestBlocked, guestOldHost, guestSettings
    // Guest access, owner side: the pane with its share sheet, and Settings → Shared access.
    case share, sharedAccess
    // The home list's live status stream: an events_v2 daemon, and an older one.
    case liveEvents, liveEventsLegacy
    // The Agents home on a machine with three running herdr sessions: the session pills (#347).
    case sessions

    static var mode: ScreenshotMock? {
        let env = ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"]?.lowercased()
        let arg = ProcessInfo.processInfo.arguments.contains("-herdrScreenshotMock")
        guard env != nil || arg else { return nil }
        switch env {
        case "resize": return .resize
        case "control": return .control
        case "onboarding": return .onboarding
        case "pairing-guidance": return .pairingGuidance
        case "rosterstress": return .rosterStress
        case "liveevents": return .liveEvents
        case "sessions": return .sessions
        case "liveevents-legacy": return .liveEventsLegacy
        case "pane": return .pane
        case "settings": return .settings
        case "share": return .share
        case "sharedaccess": return .sharedAccess
        // `htmlpreview` renders the received-document viewer over a file whose script
        // REWRITES the page, so a receipt can read off the rendered text whether the
        // Settings switch let it run. Same view and same @AppStorage key the Gram page
        // uses, so the wiring under test is the shipping one.
        case "htmlpreview": return .htmlPreview
        // `widgets` renders the Live Activity views themselves — the same file the
        // widget extension compiles — over a bright and a dark backdrop, so the layout
        // and its contrast can be LOOKED at. XCUITest cannot see a real Live Activity.
        case "widgets": return .widgets
        case "newagent": return .newAgent
        // `scroll` drives the omp scroll receipt: a real SwiftTerm pane seeded with 200
        // distinct lines of scrollback so a swipe visibly moves the content.
        case "scroll": return .scroll
        // `ccscroll` drives the Claude-Code scroll receipt: a real SwiftTerm pane put
        // into alt-screen + mouse-mode (like Claude Code fullscreen) whose stand-in
        // agent redraws shifted content when it RECEIVES an SGR wheel event — so a swipe
        // proves drag → app emits wheel → content moves.
        case "ccscroll": return .ccscroll
        // `busyscroll` drives the BUSY-PANE focus receipt: a real SwiftTerm pane whose stream
        // keeps emitting output, so SwiftTerm's auto-follow writes `contentOffset` continuously.
        // That is the state in which the first two versions of the scroll-tap guard suppressed
        // every tap and left the terminal unfocusable while an agent was working.
        case "busyscroll": return .busyScroll
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
        // Guest access (#312): the invite accept screen, the guest home, the view-only
        // pane in each state, and the guest Settings tab, all over GuestMockTransport.
        case "guestaccept": return .guestAccept
        case "guest": return .guest
        case "guestpane": return .guestPane
        case "guestpaused": return .guestPaused
        case "guestblocked": return .guestBlocked
        // A host older than guest resizing: it refuses the guest's `pane.set_pty_size`.
        case "guestoldhost": return .guestOldHost
        case "guestsettings": return .guestSettings
        default: return .list
        }
    }
}

/// Canned-response transport for the screenshot mock. The JSON is machine-checked
/// in Tests/HerdrKitTests/MockWireFixtureTests.swift (the app target can't be
/// compiled on Linux) — keep the two fixtures in sync.
/// `MockTransport` on a machine with three running herdr sessions (work, personal and
/// default) for the session pills receipt (#347). Every session answers with the demo list.
struct SessionsMockTransport: SessionListingTransport {
    private let base = MockTransport()
    func roundTrip(_ requestLine: String) async throws -> String { try await base.roundTrip(requestLine) }
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
    func listSessions() async throws -> [HerdrSession] {
        [HerdrSession(name: "personal", running: true, default: false),
         HerdrSession(name: "work", running: true, default: false),
         HerdrSession(name: "scratch", running: false, default: false),
         HerdrSession(name: "default", running: true, default: true)]
    }
    func roundTrip(_ requestLine: String, inSession session: String?) async throws -> String {
        try await base.roundTrip(requestLine)
    }
}

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
    /// When true, `pane.stream` keeps APPENDING output after the seed, so SwiftTerm's
    /// auto-follow writes `contentOffset` on every frame. The busy-pane state: the scroll-tap
    /// guard must still let a tap take focus here, and two earlier versions of it did not.
    var busyOutput = false
    var backfill = false
    /// Stateful agent-list source for the refresh-during-scroll regression receipt.
    var rosterDriver: RosterStressDriver?
    var interactionDriver: TerminalInteractionDriver?
    /// Stateful daemon for the live status stream receipt (ping, agent.list and
    /// the all-panes events.subscribe); other requests fall through to the canned
    /// answers below.
    var liveEventsDriver: LiveEventsDriver?

    func roundTrip(_ requestLine: String) async throws -> String {
        if let interactionDriver {
            return try await interactionDriver.roundTrip(requestLine)
        }
        if let liveEventsDriver, let answer = await liveEventsDriver.answer(requestLine) {
            return answer
        }
        // ccscroll receipt: any request may carry an SGR wheel event the app sent
        // (via sendText); the driver scrolls the stand-in Claude Code if so.
        ccDriver?.received(requestLine)
        if requestLine.contains("notifications.status") { return Self.notificationsStatus }
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
        if requestLine.contains("agent.prompt") { return Self.agentPrompted }
        if requestLine.contains("pane.set_pty_size") { return Self.panePtySize }
        return #"{"id":"mock","result":{}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        if let interactionDriver { return interactionDriver.stream(requestLine) }
        if let liveEventsDriver, requestLine.contains("events.subscribe") {
            return liveEventsDriver.stream()
        }
        // `pane.stream` (the live terminal): reply with the stream_started ack, then a reset
        // seed, then STAY OPEN — so the DEBUG pane shows a rendered SwiftTerm terminal, not an
        // empty one. The scrollback seed (UI test) feeds 200 lines so there is real history to
        // scroll; the default seed is the short screenshot one.
        //
        // IT MUST NOT FINISH, and finishing was a real fixture defect with a long tail. A live
        // `pane.stream` never ends, so the app treats an ended stream as a DROP and reconnects
        // with capped backoff — correct product behaviour. Against a mock that finished
        // immediately, every reconnect re-delivered the reset and appended another 200 lines,
        // forever. Measured in CI at head 18e1daca: the probe reported ydisp=3598 in one pass and
        // ydisp=3777 in the next, a buffer of thousands of lines in a fixture that seeds 200, and
        // growing by one seed per reconnect between passes.
        //
        // The consequences all looked like unrelated bugs:
        //   - The scroll view's contentSize tracked roughly 200 lines while `yDisp` ran past 3500,
        //     so a tap resolved to buffer row 186 while the DRAWN window was 3598...3621. The
        //     selection was real and off-screen, which is why the highlight was never painted and
        //     why four rounds of hunting in SwiftTerm's renderer found nothing wrong with it.
        //   - `testBackfillMakesHistoryScrollable`'s "terminal is static when untouched" premise
        //     failed at diff 0.08549 against a 0.02 ceiling, because content genuinely kept
        //     arriving.
        //
        // Not finishing is sufficient: the stream's storage holds the continuation for as long as
        // the consumer iterates, so the pane simply waits for frames that never come — exactly
        // what a quiet live pane looks like. This is what the ccDriver branch below has always
        // done, for the same reason.
        if requestLine.contains("pane.stream") {
            if let driver = ccDriver {
                // Claude-Code stand-in: keep the stream OPEN so the driver can push
                // redraws in response to wheel events the app sends.
                //
                // IT PINGS TOO, for the same reason the plain branch does. A review flagged this
                // branch as the remaining instance of the defect class the plain branch just fixed:
                // held open but SILENT, so a ccDriver pane left idle past the 50s stall
                // watchdog would be re-seeded mid-test. No current test mounts one that long, so
                // this is latent rather than active — which is exactly when it is cheap to close,
                // and leaving one branch of a two-branch function wrong is how the plain branch's
                // bug survived as long as it did.
                return AsyncThrowingStream { continuation in
                    continuation.yield(Self.paneStreamAck)
                    driver.attach(continuation)
                    let pings = Task {
                        var seq: UInt64 = 1
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s, like the server
                            guard !Task.isCancelled else { break }
                            continuation.yield(Self.paneStreamPing(seq: seq, epoch: 7))
                            seq += 1
                        }
                    }
                    continuation.onTermination = { _ in pings.cancel() }
                }
            }
            let reset = scrollback ? Self.scrollbackResetFrame() : Self.paneStreamReset
            return AsyncThrowingStream { continuation in
                continuation.yield(Self.paneStreamAck)
                continuation.yield(reset)
                // AND THEN KEEP PINGING, because silence is not the same as being alive.
                //
                // Removing finish() stopped the reconnect-on-stream-end loop, but left this mock
                // MUTE — and the app's stall watchdog treats a mute stream as a stuck one. It
                // polls every 5s and, at 50s without any event (streamStuckTimeout), writes
                // "no response for 50s; reconnecting…" into the terminal and re-runs start(),
                // which delivers another ack and another 200-line reset. So the re-seed returned
                // by a slower route: a review measured testTerminalScrollsWhenSwiped taking 85.5s
                // against this fixture with the pane mounted from launch, which is well past the
                // 50s threshold.
                //
                // A real daemon pings about every 20s, which is what the 50s timeout is sized
                // against (2.5x, so one dropped ping is tolerated). The fixture now does the same
                // thing, and `.ping` is a first-class frame in the wire protocol
                // (HerdrKit/Wire.swift:649, decoded at :705) carrying nothing but seq and epoch —
                // so it refreshes lastStreamActivity without touching the emulator, the buffer, or
                // the rendered frame. That last property matters: several UI tests assert the
                // terminal is byte-identical when untouched, so a keepalive that DREW anything
                // would trade one false failure for another.
                let pings = Task {
                    var seq: UInt64 = 1
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s, like the server
                        guard !Task.isCancelled else { break }
                        continuation.yield(Self.paneStreamPing(seq: seq, epoch: 7))
                        seq += 1
                    }
                }
                // BUSY-PANE OUTPUT: emit a line about eight times a second so SwiftTerm's
                // auto-follow writes `contentOffset` on every frame, growing scrollback exactly
                // as a working agent's does.
                //
                // FRAME TYPE IS `data`, and getting that wrong is why the first version of this
                // mock produced NOTHING. StreamFrame accepts only reset/data/resize/ping/exited
                // (Wire.swift:708-729) and decoding is deliberately STRICT — an unknown frame
                // throws, which tears the stream down and reconnects, so my invented "append"
                // yielded a reconnect loop and no output at all. The busy-pane test caught it by
                // measuring its own premise (ydisp must advance) rather than assuming it.
                let busy = Task { [busyOutput] in
                    guard busyOutput else { return }
                    var n = 1
                    var seq: UInt64 = 10_000
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { break }
                        let line = String(format: "BUSY line %04d  the agent is still working\r\n", n)
                        let b64 = Data(line.utf8).base64EncodedString()
                        continuation.yield("{\"stream\":\"pane.bytes\",\"frame\":\"data\",\"seq\":\(seq),\"epoch\":7,\"data_b64\":\"\(b64)\"}")
                        n += 1; seq += 1
                    }
                }
                // Stop pinging when the consumer goes away, so a torn-down pane does not leave a
                // timer running for the life of the process.
                continuation.onTermination = { _ in pings.cancel(); busy.cancel() }
                // DELIBERATELY NO finish(): a finished stream is a dropped stream. See above.
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
    ///
    /// EVERY ROW LOOKS DIFFERENT, not just its three-digit number. The rows used to
    /// share one sentence, so a real scroll of a whole screen changed only the digits:
    /// measured at head 45ba03b the pixel difference after three firm drags was 0.0289
    /// against ScrollTests' 0.10 floor, and the receipt failed while the screenshots it
    /// attached showed the top line moving from 170 to 085 — a working scroll reported
    /// as the dead-scroll symptom. A per-row letter and a per-row bar length make a
    /// one-screen shift change most of the pixels, so the floor now separates a real
    /// scroll from a dead one instead of separating nothing.
    static func scrollbackResetFrame() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for i in 1...200 {
            let letter = letters[i % letters.count]
            let bar = String(repeating: letter, count: 8 + (i * 7) % 44)
            body += String(format: "SCROLLTEST line %03d %@ %@\r\n", i, String(letter), bar)
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
    ///
    /// Rows differ by more than their number, for the reason `scrollbackResetFrame`
    /// records: one shared sentence made a real one-screen scroll a ~3% pixel change,
    /// which is not a signal the receipt's 10% floor can read.
    static func backfillRead() -> String {
        var body = "\u{1b}[?25l"   // hide cursor: static frames stay byte-identical
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for i in 1...1000 {
            let letter = letters[i % letters.count]
            let bar = String(repeating: letter, count: 8 + (i * 7) % 44)
            body += String(format: "BACKFILL line %04d %@ %@\r\n", i, String(letter), bar)
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
    // The mcb-air row is a DEGRADED FEDERATED agent, the shape this fixture lacked: the
    // daemon blanked `agent_status` to "unknown" after a missed poll and moved the real
    // state into `last_known_status`, so it escalates into NEEDS YOU on a last-known
    // value and must render the "stale" marker. It is what the UI receipt asserts.
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
      {"pane_id":"mcb-air/w1:p9","name":"mcb-air/mcb-air","agent":"omp","agent_status":"unknown","last_known_status":"blocked","machine_id":"mcb-air","reachability":"degraded","cwd":"/Users/jerry/omp-workspace","terminal_title_stripped":"clone repo and help deimos"},
      {"pane_id":"w5:p1","name":"huurjacht","agent":"claude","agent_status":"idle","cwd":"/root/huurjacht","terminal_title_stripped":"pararius scrape","archived":{"at":"2026-08-26T18:00:00Z","by":"jerry","reason":"parked for the weekend"}}
    ]}}
    """#

    /// The panes herdr still lists, for the mock render. Excludes w2:p1 so that
    /// row lands in STOPPED via liveness (not a status string). Includes the federated
    /// `mcb-air/w1:p9`, because a pane absent from the census is `.stopped` and a stopped
    /// row is never escalated, which would silently defeat the degraded-peer receipt.
    /// MUST stay in sync with the census the fixture test uses.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2", "mcb-air/w1:p9",
    ]

    /// `notifications.status` for the Settings mock. `HERDR_MOCK_PUSH_STATE` picks the daemon's
    /// answer: a status `state` (default `relay_ready`), or `legacy` for a daemon that predates
    /// the method and rejects the request line. Both shapes are decoded in PushRelayTests.
    static var notificationsStatus: String {
        let state = ProcessInfo.processInfo.environment["HERDR_MOCK_PUSH_STATE"] ?? "relay_ready"
        if state == "legacy" {
            return #"{"id":"","error":{"code":"invalid_request","message":"invalid request: unknown variant `notifications.status`"}}"#
        }
        return #"{"id":"mock","result":{"type":"notifications_status","state":"\#(state)","mode":"auto","relay_url":"https://push.herdrup.themartian.app","devices":1,"relay_devices":1}}"#
    }

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
    static let agentPrompted =
        #"{"id":"mock","result":{"type":"agent_prompted","delivery":"submitted"}}"#


    // pane.stream / pane.set_pty_size fixtures for the live terminal. Byte-identical
    // to MockWireFixtures in Tests/HerdrKitTests/MockWireFixtureTests.swift, which is
    // where they are machine-checked to decode through the real HerdrClient path.
    static let paneStreamAck =
        #"{"id":"mock","result":{"type":"stream_started","pane_id":"w1:p1","epoch":7,"cols":80,"rows":24,"base_seq":0,"resync":true}}"#
    static let paneStreamReset =
        #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":7,"cols":80,"rows":24,"data_b64":"G1syShtbSBtbMTszODs1OzM5bWhlcmRyG1swbSBsaXZlIHRlcm1pbmFsIOKAlCBtb2NrIHJlbmRlcg0KDQokIGhlcmRyIGFnZW50IGF0dGFjaCBqYXJ2aXMNCj4gUmFuIDE0NiB0ZXN0cywgMCBmYWlsdXJlcw0KDQpbZGVtbyBkYXRhIOKAlCBubyBsaXZlIGNvbm5lY3Rpb25dDQo="}"#
    static let panePtySize =
        #"{"id":"mock","result":{"type":"pane_pty_size","pane_id":"w1:p1","cols":80,"rows":24,"locked":false}}"#

    /// A keepalive `pane.stream` ping, the frame a real daemon sends about every 20s and the one
    /// the 50s stall watchdog is sized against. Carries only `seq` and `epoch`
    /// (HerdrKit/Wire.swift:705 decodes exactly those), so it proves the stream is alive without
    /// touching the emulator or changing a single rendered pixel — which several UI tests depend
    /// on, since they assert the terminal is byte-identical while untouched.
    static func paneStreamPing(seq: UInt64, epoch: UInt64) -> String {
        #"{"stream":"pane.bytes","frame":"ping","seq":\#(seq),"epoch":\#(epoch)}"#
    }

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
