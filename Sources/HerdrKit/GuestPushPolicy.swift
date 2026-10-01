/// iOS notification permission as guest push sees it: `granted` covers authorized,
/// provisional and ephemeral, which all deliver pushes.
public enum PushAuthorization: Sendable, Equatable {
    case undetermined
    case granted
    case denied
}

/// The guest's own choice for one share's notifications: `on` after Turn on, `off` after
/// "Not now" or Turn off. A share with no choice yet follows iOS.
public enum GuestPushChoice: Sendable, Equatable {
    case on
    case off
}

/// When a guest's phone registers its APNs token with a share's host (herdrup#343). The
/// host pushes only to a registered phone, so every path that ends without registering is
/// a guest who never hears from the shared agent.
///
/// The phone registers on every connect, and again whenever its token changes, as long as
/// the host takes guest push, iOS lets the app notify, and the guest hasn't turned the
/// share off. iOS permission alone decides: a phone that already allows notifications is
/// never asked again, and one that hasn't been asked gets the explanation first.
public enum GuestPushPolicy {
    public enum Action: Sendable, Equatable {
        case none
        /// Send this phone's token to the host now (or as soon as iOS issues one).
        case register
        /// iOS hasn't asked yet: explain why, and ask only if the guest says yes.
        case explain
    }

    /// A connection to the share learned its host's features.
    public static func onConnect(hostTakesPush: Bool, choice: GuestPushChoice?,
                                 authorization: PushAuthorization) -> Action {
        guard hostTakesPush, choice != .off else { return .none }
        switch authorization {
        case .granted: return .register
        case .undetermined: return .explain
        case .denied: return .none
        }
    }

    /// iOS issued a new token: whether the share's host gets it.
    public static func registersOnTokenChange(hostTakesPush: Bool, choice: GuestPushChoice?,
                                              authorization: PushAuthorization) -> Bool {
        onConnect(hostTakesPush: hostTakesPush, choice: choice, authorization: authorization) == .register
    }

    /// What the guest's Notifications control shows for a share.
    public enum Status: Sendable, Equatable {
        /// The host doesn't take guest push (or hasn't said yet).
        case unavailable
        case on
        /// Turned off, or iOS hasn't asked yet: the control offers Turn on.
        case off
        /// iOS refuses notifications for the app: only Settings can change that.
        case denied
        /// The last registration, token request or unregistration failed, and why.
        case failed(String)
    }

    /// `failure` is the last attempt's error for this share, cleared by the next success
    /// or by the guest acting on the control.
    public static func status(hostTakesPush: Bool?, choice: GuestPushChoice?,
                              authorization: PushAuthorization, failure: String?) -> Status {
        guard hostTakesPush == true else { return .unavailable }
        if let failure { return .failed(failure) }
        if choice == .off { return .off }
        switch authorization {
        case .granted: return .on
        case .undetermined: return .off
        case .denied: return .denied
        }
    }
}
