import HerdrKit
import SwiftUI
import UIKit
import UserNotifications

/// What a share's host offers this guest (`features` in each hello), as the relay reports
/// it. Nil until the first call of this connection answers. Published on the main thread.
final class GuestFeaturesModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var current: GuestFeatures?

    init(_ initial: GuestFeatures? = nil) {
        current = initial
    }

    /// Hands the transport a sink that publishes on the main thread.
    func sink() -> @Sendable (GuestFeatures) -> Void {
        { [weak self] features in
            DispatchQueue.main.async { self?.update(features) }
        }
    }

    func update(_ features: GuestFeatures) {
        if current != features { current = features }
    }
}

/// Push for the agents shared with this phone (herdrup#338). A guest's device registers its
/// APNs token with each share's host over the guest relay, stored there under the guest,
/// apart from the owner's devices. The host then pushes the shared agent's status changes
/// and, when the owner shares Gram, its new Grams.
///
/// `GuestPushPolicy` decides (herdrup#343): every connection to a host that takes guest push
/// registers while iOS lets the app notify and the guest hasn't turned the share off, and a
/// new token registers again. Only a phone iOS hasn't asked yet gets the explanation. Each
/// share's state, including why the last attempt failed, shows in the guest's Settings.
@MainActor
final class GuestPushCenter: ObservableObject {
    static let shared = GuestPushCenter()

    /// The system around push, swapped for a scripted one under the screenshot mocks so UI
    /// tests never show the system alert or reach APNs and the push relay.
    struct System {
        var authorization: () async -> PushAuthorization
        var requestAuthorization: () async -> Bool
        var registerForRemoteNotifications: () -> Void
        var deviceToken: () -> String?
        /// Why iOS last failed to issue a token, while it has none.
        var tokenError: () -> String?
        var relayCapability: (String) async -> String?
        /// A client for a share, for calls made away from its screens (a token change,
        /// the Settings control before the home connected, leaving the share).
        var connect: (GuestAccess) throws -> HerdrClient
        /// The app's notification settings in iOS Settings.
        var openSettings: () -> Void
    }

    /// The share whose "turn on notifications" explanation is showing, by `GuestAccess.id`.
    @Published private(set) var asking: String?
    /// iOS's notification permission, as last read.
    @Published private(set) var authorization: PushAuthorization = .undetermined
    /// Per share: the guest's choice (`consentKey`).
    @Published private(set) var choices: [String: GuestPushChoice]
    /// Per share: what its host last advertised (`featuresKey`).
    @Published private(set) var hostFeatures: [String: GuestFeatures]
    /// Per share: why the last registration, token request or unregistration failed.
    @Published private(set) var failures: [String: String] = [:]

    /// Per share: the registration last sent, so one connection registers once and a new
    /// token or Gram preference registers again.
    private var sent: [String: Registration] = [:]
    private struct Registration: Equatable {
        let client: ObjectIdentifier
        let token: String
        let gram: Bool
    }

    private let system: System
    private let defaults: UserDefaults
    /// Per share: true once the guest turned push on, false after "Not now" or Turn off.
    private static let consentKey = "guest.push.consent.v1"
    /// Per share: the features its host last advertised, so a token change can re-register
    /// with the right `notify_gram` while the share isn't open.
    private static let featuresKey = "guest.push.features.v1"

    init(system: System, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
        choices = ((defaults.dictionary(forKey: Self.consentKey) as? [String: Bool]) ?? [:])
            .mapValues { $0 ? .on : .off }
        hostFeatures = ((defaults.dictionary(forKey: Self.featuresKey) as? [String: [Bool]]) ?? [:])
            .compactMapValues { $0.count == 2 ? GuestFeatures(gram: $0[0], push: $0[1]) : nil }
    }

    private convenience init() {
        #if DEBUG
        if ScreenshotMock.mode != nil {
            let defaults = UserDefaults.standard
            // Each UI test launch starts undecided, like a fresh install.
            defaults.removeObject(forKey: Self.consentKey)
            defaults.removeObject(forKey: Self.featuresKey)
            self.init(system: .mock, defaults: defaults)
            return
        }
        #endif
        self.init(system: .live)
    }

    // MARK: State

    func status(for access: GuestAccess) -> GuestPushPolicy.Status {
        GuestPushPolicy.status(hostTakesPush: hostFeatures[access.id]?.push, choice: choices[access.id],
                               authorization: authorization, failure: failures[access.id])
    }

    private func setChoice(_ value: GuestPushChoice?, for access: GuestAccess) {
        choices[access.id] = value
        defaults.set(choices.mapValues { $0 == .on }, forKey: Self.consentKey)
    }

    private func remember(_ features: GuestFeatures?, for access: GuestAccess) {
        guard hostFeatures[access.id] != features else { return }
        hostFeatures[access.id] = features
        defaults.set(hostFeatures.mapValues { [$0.gram, $0.push] }, forKey: Self.featuresKey)
    }

    private func setFailure(_ message: String?, for access: GuestAccess) {
        if failures[access.id] != message { failures[access.id] = message }
    }

    /// Re-reads iOS's permission, which the guest can change in Settings at any time.
    @discardableResult
    func refreshAuthorization() async -> PushAuthorization {
        let current = await system.authorization()
        if authorization != current { authorization = current }
        return current
    }

    /// The guest's Settings came into view, or the app came back to the foreground (the
    /// guest may have changed iOS's permission meanwhile): re-read it, and register over
    /// the share's open connection if that is now due.
    func refresh(_ access: GuestAccess, client: HerdrClient?) async {
        guard let client, let features = hostFeatures[access.id] else {
            await refreshAuthorization()
            return
        }
        await connected(access, client: client, features: features)
    }

    // MARK: Flow

    /// A connection to the share learned (or re-learned) its host's features: register when
    /// the policy says so, so the host always holds the current token and `notify_gram`, or
    /// explain when iOS hasn't asked yet. Safe to call repeatedly: a connection registers once.
    func connected(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        remember(features, for: access)
        let authorization = await refreshAuthorization()
        switch GuestPushPolicy.onConnect(hostTakesPush: features.push, choice: choices[access.id],
                                         authorization: authorization) {
        case .register:
            if asking == access.id { asking = nil }
            // Not the calling view's task: leaving the screen mid-registration must not cancel it.
            await Task { await self.register(access, client: client, features: features) }.value
        case .explain:
            if asking != access.id { asking = access.id }
        case .none:
            if asking == access.id { asking = nil }
        }
    }

    /// Turn on, from the explanation or the Settings control (also its Retry): ask iOS when
    /// it hasn't asked yet, then register. When the token arrives later (the first
    /// registration with APNs), `deviceTokenChanged` registers it.
    func turnOn(_ access: GuestAccess, client: HerdrClient?) async {
        asking = nil
        setChoice(.on, for: access)
        setFailure(nil, for: access)
        if await refreshAuthorization() == .undetermined {
            _ = await system.requestAuthorization()
            await refreshAuthorization()
        }
        guard authorization == .granted, let features = hostFeatures[access.id], features.push,
              let client = client ?? self.client(for: access) else { return }
        await register(access, client: client, features: features, again: true)
    }

    /// "Not now" on the explanation: this share stays off until the guest turns it on.
    func decline(_ access: GuestAccess) {
        asking = nil
        setChoice(.off, for: access)
    }

    /// Turn off, from the Settings control: the host stops pushing to this phone.
    func turnOff(_ access: GuestAccess, client: HerdrClient?) async {
        setChoice(.off, for: access)
        setFailure(nil, for: access)
        sent[access.id] = nil
        guard let token = system.deviceToken(), let client = client ?? self.client(for: access) else { return }
        do {
            try await client.unregisterDevice(token: token)
        } catch {
            guard choices[access.id] == .off else { return }
            setFailure("Couldn't turn them off on \(access.machineLabel): \(Self.describe(error))", for: access)
        }
    }

    func openSettings() { system.openSettings() }

    /// The APNs token changed: register it with every share the policy says should have it.
    func deviceTokenChanged(shares: [GuestAccess]) {
        Task {
            let authorization = await refreshAuthorization()
            for access in shares {
                guard let features = hostFeatures[access.id],
                      GuestPushPolicy.registersOnTokenChange(hostTakesPush: features.push,
                                                             choice: choices[access.id],
                                                             authorization: authorization),
                      let client = client(for: access) else { continue }
                await register(access, client: client, features: features)
            }
        }
    }

    /// The guest removed the share from this phone: the host stops pushing to it.
    func leaving(_ access: GuestAccess) {
        let wasRegistered = sent[access.id] != nil || choices[access.id] == .on
        setChoice(nil, for: access)
        remember(nil, for: access)
        sent[access.id] = nil
        failures[access.id] = nil
        if asking == access.id { asking = nil }
        guard wasRegistered || authorization == .granted, let token = system.deviceToken(),
              let client = try? system.connect(access) else { return }
        Task { try? await client.unregisterDevice(token: token) }
    }

    private func client(for access: GuestAccess) -> HerdrClient? {
        do {
            return try system.connect(access)
        } catch {
            setFailure("Couldn't reach \(access.machineLabel): \(Self.describe(error))", for: access)
            return nil
        }
    }

    /// Every status kind on; Gram pushes only where the owner shares Gram. Without a token
    /// yet, asks iOS for one; `deviceTokenChanged` registers it when it lands. `again`
    /// re-sends what this connection already sent (Turn on, Retry).
    private func register(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures,
                          again: Bool = false) async {
        guard let token = system.deviceToken() else {
            system.registerForRemoteNotifications()
            if let error = system.tokenError() {
                setFailure("iOS couldn't set up notifications: \(error)", for: access)
            }
            return
        }
        let registration = Registration(client: ObjectIdentifier(client), token: token, gram: features.gram)
        guard again || sent[access.id] != registration else { return }
        sent[access.id] = registration
        let capability = await system.relayCapability(token)
        do {
            try await client.registerDevice(token: token, needsInput: true, dies: true, finishes: true,
                                            gram: features.gram, mutedPanes: [], relayCapability: capability)
        } catch {
            // The next connection, token or Retry tries again.
            if sent[access.id] == registration { sent[access.id] = nil }
            setFailure("Couldn't register with \(access.machineLabel): \(Self.describe(error))", for: access)
            return
        }
        // Without the push service's capability the host can push only with an APNs key of
        // its own, which most don't have.
        setFailure(capability == nil
                   ? "\(access.machineLabel) has this phone, but the push service couldn't be reached, so notifications may not arrive."
                   : nil, for: access)
    }

    private static func describe(_ error: Error) -> String {
        GuestError.classify(error)?.description ?? error.localizedDescription
    }
}

extension GuestPushCenter.System {
    static let live = GuestPushCenter.System(
        authorization: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .undetermined
            @unknown default: return .undetermined
            }
        },
        requestAuthorization: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        },
        registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() },
        deviceToken: { PushCenter.shared.deviceToken },
        tokenError: { PushCenter.shared.tokenError },
        relayCapability: { await PushCenter.relay.capability(kind: .device, token: $0) },
        connect: { try GuestConnection.open($0).client },
        openSettings: {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })

    #if DEBUG
    /// `HERDR_MOCK_PUSH_AUTH` sets iOS's answer before any question: `granted`, `denied`,
    /// or (by default) undecided, which turns granted once asked. A granted phone has a
    /// fixed token; the relay is never contacted (its capability is canned); calls go to
    /// the mock host.
    static var mock: GuestPushCenter.System {
        let authorization = MockAuthorization(ProcessInfo.processInfo.environment["HERDR_MOCK_PUSH_AUTH"])
        return GuestPushCenter.System(
            authorization: { authorization.value },
            requestAuthorization: {
                if authorization.value == .undetermined { authorization.value = .granted }
                return authorization.value == .granted
            },
            registerForRemoteNotifications: {},
            deviceToken: { authorization.value == .granted ? GuestMockTransport.deviceToken : nil },
            tokenError: { nil },
            relayCapability: { _ in "hpr1.mock" },
            connect: { _ in HerdrClient(transport: GuestMockTransport(scenario: .running)) },
            openSettings: {})
    }

    private final class MockAuthorization: @unchecked Sendable {
        var value: PushAuthorization
        init(_ raw: String?) {
            switch raw {
            case "granted": value = .granted
            case "denied": value = .denied
            default: value = .undetermined
            }
        }
    }
    #endif
}

/// The one-time explanation before iOS asks for notification permission.
struct GuestPushPrompt: View {
    let agentName: String
    let ownerName: String
    let gram: Bool
    let onEnable: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 32, height: 32)
                    .background(Palette.surfaceRaised, in: Circle())
                Text("Get notified about \(agentName)")
                    .font(Typography.app(16, .semibold)).foregroundStyle(Palette.text)
            }
            Text(detail)
                .font(Typography.app(13.5)).foregroundStyle(Palette.textDim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Not now", action: onDecline)
                    .buttonStyle(GuestPillButtonStyle(primary: false))
                    .accessibilityIdentifier("guest-push-not-now")
                Button("Turn on", action: onEnable)
                    .buttonStyle(GuestPillButtonStyle(primary: true))
                    .accessibilityIdentifier("guest-push-enable")
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guest-push-prompt")
    }

    private var detail: String {
        let kinds = gram ? "needs \(ownerName), finishes or stops, and when it sends a Gram"
                         : "needs \(ownerName), finishes or stops"
        return "HerdrUp can tell you when \(agentName) \(kinds), even while the app is closed. "
            + "You can change this any time in Settings."
    }
}
