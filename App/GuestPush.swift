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
/// The guest is asked once per share, the first time they open the shared agent on a host
/// that takes guest push, and only when iOS still has to ask for permission: a phone that
/// already allows notifications turns them on without a second question.
@MainActor
final class GuestPushCenter: ObservableObject {
    static let shared = GuestPushCenter()

    enum Authorization { case undetermined, granted, denied }

    /// The system around push, swapped for a scripted one under the screenshot mocks so UI
    /// tests never show the system alert or reach APNs and the push relay.
    struct System {
        var authorization: () async -> Authorization
        var requestAuthorization: () async -> Bool
        var registerForRemoteNotifications: () -> Void
        var deviceToken: () -> String?
        var relayCapability: (String) async -> String?
        /// A client for a share, for calls made away from its screens (a token change,
        /// leaving the share).
        var connect: (GuestAccess) throws -> HerdrClient
    }

    /// The share whose "turn on notifications" explanation is showing, by `GuestAccess.id`.
    @Published private(set) var asking: String?

    private let system: System
    private let defaults: UserDefaults
    /// Per share: true once the guest turned push on, false after "Not now".
    private static let consentKey = "guest.push.consent.v1"
    /// Per share: the features its host last advertised, so a token change can re-register
    /// with the right `notify_gram` while the share isn't open.
    private static let featuresKey = "guest.push.features.v1"

    init(system: System, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
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

    // MARK: Consent

    func consent(for access: GuestAccess) -> Bool? {
        (defaults.dictionary(forKey: Self.consentKey) as? [String: Bool])?[access.id]
    }

    private func setConsent(_ value: Bool?, for access: GuestAccess) {
        var all = (defaults.dictionary(forKey: Self.consentKey) as? [String: Bool]) ?? [:]
        all[access.id] = value
        defaults.set(all, forKey: Self.consentKey)
    }

    private func rememberedFeatures(for access: GuestAccess) -> GuestFeatures? {
        guard let raw = (defaults.dictionary(forKey: Self.featuresKey) as? [String: [Bool]])?[access.id],
              raw.count == 2 else { return nil }
        return GuestFeatures(gram: raw[0], push: raw[1])
    }

    private func remember(_ features: GuestFeatures?, for access: GuestAccess) {
        var all = (defaults.dictionary(forKey: Self.featuresKey) as? [String: [Bool]]) ?? [:]
        all[access.id] = features.map { [$0.gram, $0.push] }
        defaults.set(all, forKey: Self.featuresKey)
    }

    // MARK: Flow

    /// The guest opened the shared agent. On a host that takes guest push, registers when
    /// the guest already said yes, turns push on when iOS already allows it, and otherwise
    /// asks once.
    func paneOpened(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        guard features.push else { return }
        switch consent(for: access) {
        case true?:
            await register(access, client: client, features: features)
        case false?:
            return
        case nil:
            switch await system.authorization() {
            case .granted:
                setConsent(true, for: access)
                await register(access, client: client, features: features)
            case .undetermined:
                asking = access.id
            case .denied:
                return
            }
        }
    }

    /// "Turn on" on the explanation: ask iOS, then register. When the token arrives later
    /// (the first registration with APNs), `deviceTokenChanged` registers it.
    func enable(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        asking = nil
        setConsent(true, for: access)
        guard await system.requestAuthorization() else { return }
        system.registerForRemoteNotifications()
        await register(access, client: client, features: features)
    }

    /// "Not now": don't ask again for this share.
    func decline(_ access: GuestAccess) {
        asking = nil
        setConsent(false, for: access)
    }

    /// A connection to the share learned (or re-learned) its host's features: re-register,
    /// so the host always holds the current token and `notify_gram`.
    func connected(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        remember(features, for: access)
        guard features.push, consent(for: access) == true else { return }
        await register(access, client: client, features: features)
    }

    /// The APNs token changed: register it with every share that has push on.
    func deviceTokenChanged(shares: [GuestAccess]) {
        for access in shares where consent(for: access) == true {
            guard let features = rememberedFeatures(for: access), features.push,
                  let client = try? system.connect(access) else { continue }
            Task { await register(access, client: client, features: features) }
        }
    }

    /// The guest removed the share from this phone: the host stops pushing to it.
    func leaving(_ access: GuestAccess) {
        let wasOn = consent(for: access) == true
        setConsent(nil, for: access)
        remember(nil, for: access)
        if asking == access.id { asking = nil }
        guard wasOn, let token = system.deviceToken(), let client = try? system.connect(access) else { return }
        Task { try? await client.unregisterDevice(token: token) }
    }

    /// Every status kind on; Gram pushes only where the owner shares Gram.
    private func register(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        guard let token = system.deviceToken() else { return }
        let capability = await system.relayCapability(token)
        try? await client.registerDevice(token: token, needsInput: true, dies: true, finishes: true,
                                         gram: features.gram, mutedPanes: [], relayCapability: capability)
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
        relayCapability: { await PushCenter.relay.capability(kind: .device, token: $0) },
        connect: { try GuestConnection.open($0).client })

    #if DEBUG
    /// Permission is undecided until asked, then granted; the token is fixed; the relay is
    /// never contacted; calls go to the mock host.
    static var mock: GuestPushCenter.System {
        let granted = MockFlag()
        return GuestPushCenter.System(
            authorization: { granted.value ? .granted : .undetermined },
            requestAuthorization: { granted.value = true; return true },
            registerForRemoteNotifications: {},
            deviceToken: { granted.value ? GuestMockTransport.deviceToken : nil },
            relayCapability: { _ in nil },
            connect: { _ in HerdrClient(transport: GuestMockTransport(scenario: .running)) })
    }

    private final class MockFlag: @unchecked Sendable {
        var value = false
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
        return "HerdrUp can tell you when \(agentName) \(kinds), even while the app is closed."
    }
}
