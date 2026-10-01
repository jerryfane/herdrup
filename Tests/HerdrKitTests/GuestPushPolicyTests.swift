import XCTest
@testable import HerdrKit

/// When a guest's phone registers its push token with a share's host (herdrup#343). The
/// host only pushes to a registered phone, so every path that ends without registering is
/// a guest who silently never hears from the shared agent.
final class GuestPushPolicyTests: XCTestCase {
    private let choices: [GuestPushChoice?] = [nil, .on]

    /// A phone iOS already lets notify registers on every connect, whether or not the guest
    /// ever saw the explanation: nothing to ask, so nothing to wait for.
    func testGrantedPermissionRegistersOnEveryConnectWithoutAsking() {
        for choice in choices {
            XCTAssertEqual(GuestPushPolicy.onConnect(hostTakesPush: true, choice: choice, authorization: .granted),
                           .register, "choice \(String(describing: choice))")
        }
    }

    /// The token often lands after the connect (the first APNs registration): it registers
    /// then, under the same rule.
    func testGrantedPermissionRegistersANewToken() {
        for choice in choices {
            XCTAssertTrue(GuestPushPolicy.registersOnTokenChange(hostTakesPush: true, choice: choice,
                                                                 authorization: .granted),
                          "choice \(String(describing: choice))")
        }
    }

    /// iOS refused: nothing registers and nothing asks (iOS won't ask again); the control
    /// sends the guest to Settings instead.
    func testDeniedPermissionNeverRegisters() {
        for choice in choices {
            XCTAssertEqual(GuestPushPolicy.onConnect(hostTakesPush: true, choice: choice, authorization: .denied),
                           .none)
            XCTAssertFalse(GuestPushPolicy.registersOnTokenChange(hostTakesPush: true, choice: choice,
                                                                  authorization: .denied))
        }
    }

    /// iOS hasn't asked yet: explain first, and register only once the guest says yes.
    func testUndecidedPermissionExplainsBeforeAsking() {
        XCTAssertEqual(GuestPushPolicy.onConnect(hostTakesPush: true, choice: nil, authorization: .undetermined),
                       .explain)
        XCTAssertFalse(GuestPushPolicy.registersOnTokenChange(hostTakesPush: true, choice: nil,
                                                              authorization: .undetermined))
    }

    /// The guest turned this share off ("Not now", or Off in the control): it stays off
    /// whatever iOS allows, until they turn it on.
    func testAShareTurnedOffStaysOff() {
        for authorization in [PushAuthorization.granted, .undetermined, .denied] {
            XCTAssertEqual(GuestPushPolicy.onConnect(hostTakesPush: true, choice: .off, authorization: authorization),
                           .none)
            XCTAssertFalse(GuestPushPolicy.registersOnTokenChange(hostTakesPush: true, choice: .off,
                                                                  authorization: authorization))
        }
    }

    /// A host that doesn't take guest push is never asked to register, and never explained.
    func testAHostWithoutGuestPushIsLeftAlone() {
        for authorization in [PushAuthorization.granted, .undetermined, .denied] {
            for choice in choices {
                XCTAssertEqual(GuestPushPolicy.onConnect(hostTakesPush: false, choice: choice,
                                                         authorization: authorization), .none)
                XCTAssertFalse(GuestPushPolicy.registersOnTokenChange(hostTakesPush: false, choice: choice,
                                                                      authorization: authorization))
            }
        }
    }

    // MARK: The guest's Notifications control

    private func status(push: Bool? = true, choice: GuestPushChoice? = nil, _ authorization: PushAuthorization,
                        failure: String? = nil) -> GuestPushPolicy.Status {
        GuestPushPolicy.status(hostTakesPush: push, choice: choice, authorization: authorization, failure: failure)
    }

    /// The control says what the phone will do: On exactly when it registers, Off (with Turn
    /// on) when it waits for the guest, Denied (with Settings) when only iOS can change it.
    func testTheControlShowsWhatThePhoneDoes() {
        XCTAssertEqual(status(.granted), .on)
        XCTAssertEqual(status(choice: .on, .granted), .on)
        XCTAssertEqual(status(.undetermined), .off)
        XCTAssertEqual(status(choice: .off, .granted), .off)
        XCTAssertEqual(status(.denied), .denied)
        XCTAssertEqual(status(choice: .on, .denied), .denied)
    }

    /// A failed registration, enrollment or token request shows, whatever the phone would
    /// otherwise be doing, until a retry or a success clears it.
    func testAFailureShowsInTheControl() {
        XCTAssertEqual(status(.granted, failure: "relay unreachable"), .failed("relay unreachable"))
        XCTAssertEqual(status(choice: .off, .granted, failure: "unregister refused"), .failed("unregister refused"))
    }

    /// No control state to offer on a host that doesn't take guest push, or before it said.
    func testNoControlWithoutGuestPush() {
        for push in [false, nil] as [Bool?] {
            XCTAssertEqual(status(push: push, .granted, failure: "x"), .unavailable)
        }
    }
}
