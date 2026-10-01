import Foundation

/// The system around a guest's push: iOS permission and token, the push relay, and a
/// connection to a share. The app supplies the live one; tests and UI-test mocks script it.
public struct GuestPushSystem: Sendable {
    public var authorization: @Sendable () async -> PushAuthorization
    public var requestAuthorization: @Sendable () async -> Bool
    /// Asks iOS for an APNs token; it arrives later, through `deviceTokenChanged`.
    public var registerForRemoteNotifications: @Sendable () async -> Void
    public var deviceToken: @Sendable () async -> String?
    /// Why iOS last failed to issue a token, while it has none.
    public var tokenError: @Sendable () async -> String?
    public var relayCapability: @Sendable (String) async -> String?
    /// A client for a share, for calls made away from its screens (a token change, the
    /// Settings control before the home connected, leaving the share).
    public var connect: @Sendable (GuestAccess) async throws -> HerdrClient

    public init(authorization: @escaping @Sendable () async -> PushAuthorization,
                requestAuthorization: @escaping @Sendable () async -> Bool,
                registerForRemoteNotifications: @escaping @Sendable () async -> Void,
                deviceToken: @escaping @Sendable () async -> String?,
                tokenError: @escaping @Sendable () async -> String?,
                relayCapability: @escaping @Sendable (String) async -> String?,
                connect: @escaping @Sendable (GuestAccess) async throws -> HerdrClient) {
        self.authorization = authorization
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.deviceToken = deviceToken
        self.tokenError = tokenError
        self.relayCapability = relayCapability
        self.connect = connect
    }
}

/// What the guest's screens show about push, per share by `GuestAccess.id`.
public struct GuestPushState: Sendable, Equatable {
    /// iOS's notification permission, as last read.
    public var authorization: PushAuthorization = .undetermined
    /// The guest's choice per share.
    public var choices: [String: GuestPushChoice] = [:]
    /// What each share's host last advertised.
    public var hostFeatures: [String: GuestFeatures] = [:]
    /// Why the last attempt for a share failed.
    public var failures: [String: String] = [:]
    /// The share whose "turn on notifications" explanation is showing.
    public var asking: String?

    public init() {}

    public func status(for access: GuestAccess) -> GuestPushPolicy.Status {
        GuestPushPolicy.status(hostTakesPush: hostFeatures[access.id]?.push, choice: choices[access.id],
                               authorization: authorization, failure: failures[access.id])
    }
}

/// Push for the agents shared with this phone (herdrup#338, #343). A guest's device
/// registers its APNs token with each share's host over the guest relay; the host then
/// pushes the shared agent's status changes and, when the owner shares Gram, its Grams.
/// `GuestPushPolicy` decides when; this carries it out and keeps `state` for the screens,
/// reporting every change through `onChange`.
public actor GuestPushCoordinator {
    public private(set) var state: GuestPushState {
        didSet { if state != oldValue { onChange(state) } }
    }

    /// Per share: the registration last sent, so one connection registers once and a new
    /// token or Gram preference registers again.
    private var sent: [String: Registration] = [:]
    private struct Registration: Equatable {
        let client: ObjectIdentifier
        let token: String
        let gram: Bool
    }

    private let system: GuestPushSystem
    private let defaults: UserDefaults
    private let onChange: @Sendable (GuestPushState) -> Void
    /// Per share: true once the guest turned push on, false after "Not now" or Turn off.
    public static let consentKey = "guest.push.consent.v1"
    /// Per share: the features its host last advertised, so a token change can re-register
    /// with the right `notify_gram` while the share isn't open.
    public static let featuresKey = "guest.push.features.v1"

    public init(system: GuestPushSystem, defaults: UserDefaults = .standard,
                onChange: @escaping @Sendable (GuestPushState) -> Void = { _ in }) {
        self.system = system
        self.defaults = defaults
        self.onChange = onChange
        state = Self.storedState(defaults)
    }

    /// The choices and features saved in `defaults`, before anything is read from iOS.
    public static func storedState(_ defaults: UserDefaults) -> GuestPushState {
        var state = GuestPushState()
        state.choices = ((defaults.dictionary(forKey: consentKey) as? [String: Bool]) ?? [:])
            .mapValues { $0 ? .on : .off }
        state.hostFeatures = ((defaults.dictionary(forKey: featuresKey) as? [String: [Bool]]) ?? [:])
            .compactMapValues { $0.count == 2 ? GuestFeatures(gram: $0[0], push: $0[1]) : nil }
        return state
    }

    // MARK: State

    private func setChoice(_ value: GuestPushChoice?, for access: GuestAccess) {
        state.choices[access.id] = value
        defaults.set(state.choices.mapValues { $0 == .on }, forKey: Self.consentKey)
    }

    private func remember(_ features: GuestFeatures?, for access: GuestAccess) {
        guard state.hostFeatures[access.id] != features else { return }
        state.hostFeatures[access.id] = features
        defaults.set(state.hostFeatures.mapValues { [$0.gram, $0.push] }, forKey: Self.featuresKey)
    }

    private func setFailure(_ message: String?, for access: GuestAccess) {
        state.failures[access.id] = message
    }

    private func setAsking(_ id: String?) {
        state.asking = id
    }

    /// Re-reads iOS's permission, which the guest can change in Settings at any time.
    @discardableResult
    public func refreshAuthorization() async -> PushAuthorization {
        let current = await system.authorization()
        state.authorization = current
        return current
    }

    /// The guest's Settings came into view, or the app came back to the foreground (the
    /// guest may have changed iOS's permission meanwhile): re-read it, and register over
    /// the share's open connection if that is now due.
    public func refresh(_ access: GuestAccess, client: HerdrClient?) async {
        guard let client, let features = state.hostFeatures[access.id] else {
            await refreshAuthorization()
            return
        }
        await connected(access, client: client, features: features)
    }

    // MARK: Flow

    /// A connection to the share learned (or re-learned) its host's features: register when
    /// the policy says so, so the host always holds the current token and `notify_gram`, or
    /// explain when iOS hasn't asked yet. Safe to call repeatedly: a connection registers once.
    public func connected(_ access: GuestAccess, client: HerdrClient, features: GuestFeatures) async {
        remember(features, for: access)
        let authorization = await refreshAuthorization()
        switch GuestPushPolicy.onConnect(hostTakesPush: features.push, choice: state.choices[access.id],
                                         authorization: authorization) {
        case .register:
            if state.asking == access.id { setAsking(nil) }
            // Not the caller's task: leaving the screen mid-registration must not cancel it.
            await Task { await self.register(access, client: client, features: features) }.value
        case .explain:
            setAsking(access.id)
        case .none:
            if state.asking == access.id { setAsking(nil) }
        }
    }

    /// The Notifications control's button. `openSettings` is the app's to carry out.
    public func perform(_ action: GuestPushAction, _ access: GuestAccess, client: HerdrClient?) async {
        switch action {
        case .turnOn, .retry: await turnOn(access, client: client)
        case .turnOff: await turnOff(access, client: client)
        case .openSettings: break
        }
    }

    /// Turn on, from the explanation or the Settings control (also its Retry): ask iOS when
    /// it hasn't asked yet, then register. When the token arrives later (the first
    /// registration with APNs), `deviceTokenChanged` registers it.
    public func turnOn(_ access: GuestAccess, client: HerdrClient?) async {
        setAsking(nil)
        setChoice(.on, for: access)
        setFailure(nil, for: access)
        if await refreshAuthorization() == .undetermined {
            _ = await system.requestAuthorization()
            await refreshAuthorization()
        }
        guard state.authorization == .granted, let features = state.hostFeatures[access.id], features.push
        else { return }
        let resolved: HerdrClient?
        if let client { resolved = client } else { resolved = await self.client(for: access) }
        guard let resolved else { return }
        await register(access, client: resolved, features: features, again: true)
    }

    /// "Not now" on the explanation: this share stays off until the guest turns it on.
    public func decline(_ access: GuestAccess) {
        setAsking(nil)
        setChoice(.off, for: access)
    }

    /// Turn off, from the Settings control: the host stops pushing to this phone.
    public func turnOff(_ access: GuestAccess, client: HerdrClient?) async {
        setChoice(.off, for: access)
        setFailure(nil, for: access)
        sent[access.id] = nil
        guard let token = await system.deviceToken() else { return }
        let resolved: HerdrClient?
        if let client { resolved = client } else { resolved = await self.client(for: access) }
        guard let resolved else { return }
        do {
            try await resolved.unregisterDevice(token: token)
        } catch {
            guard state.choices[access.id] == .off else { return }
            setFailure("Couldn't turn them off on \(access.machineLabel): \(Self.describe(error))", for: access)
        }
    }

    /// The APNs token changed: register it with every share the policy says should have it.
    public func deviceTokenChanged(shares: [GuestAccess]) async {
        let authorization = await refreshAuthorization()
        for access in shares {
            guard let features = state.hostFeatures[access.id],
                  GuestPushPolicy.registersOnTokenChange(hostTakesPush: features.push,
                                                         choice: state.choices[access.id],
                                                         authorization: authorization),
                  let client = await client(for: access) else { continue }
            await register(access, client: client, features: features)
        }
    }

    /// The guest removed the share from this phone: the host stops pushing to it.
    public func leaving(_ access: GuestAccess) async {
        let wasRegistered = sent[access.id] != nil || state.choices[access.id] == .on
        setChoice(nil, for: access)
        remember(nil, for: access)
        sent[access.id] = nil
        setFailure(nil, for: access)
        if state.asking == access.id { setAsking(nil) }
        guard wasRegistered || state.authorization == .granted, let token = await system.deviceToken(),
              let client = try? await system.connect(access) else { return }
        try? await client.unregisterDevice(token: token)
    }

    private func client(for access: GuestAccess) async -> HerdrClient? {
        do {
            return try await system.connect(access)
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
        guard let token = await system.deviceToken() else {
            await system.registerForRemoteNotifications()
            if let error = await system.tokenError() {
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
