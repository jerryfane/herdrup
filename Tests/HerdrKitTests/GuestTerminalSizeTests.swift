import XCTest
@testable import HerdrKit

final class GuestTerminalSizeTests: XCTestCase {

    /// An older host answers a guest's resize with `guest_forbidden` and always will: the
    /// first refusal stops every later proposal, and the caller hears about it once.
    func testForbiddenResizeClosesTheGateOnce() {
        var gate = PTYResizeGate()
        XCTAssertTrue(gate.noteFailure(APIError(code: "guest_forbidden", message: "guests can't call pane.set_pty_size")))
        XCTAssertTrue(gate.isClosed)
        XCTAssertFalse(gate.noteFailure(APIError(code: "guest_forbidden", message: "")),
                       "a closed gate reports the refusal only once")
        XCTAssertTrue(gate.isClosed)
    }

    /// A refusal that can lift (the agent paused) or a failure that isn't a refusal at all
    /// must not strand the guest in the fit-to-width fallback for the whole session.
    func testTransientFailuresKeepProposing() {
        var gate = PTYResizeGate()
        for error: Error in [
            APIError(code: "guest_paused", message: "llm-opt isn't running"),
            APIError(code: "pane_not_found", message: ""),
            GuestError.hostOffline,
            TransportError.writeFailed(errno: 32),
        ] {
            XCTAssertFalse(gate.noteFailure(error), "\(error)")
        }
        XCTAssertFalse(gate.isClosed)
    }

    /// A± stays within the terminal's font range at both ends.
    func testSteppingIsClampedToTheRange() {
        XCTAssertEqual(GuestTerminalSize.stepped(GuestTerminalSize.defaultPoints, by: 1), 13.5)
        XCTAssertEqual(GuestTerminalSize.stepped(23.5, by: 1), 24)
        XCTAssertEqual(GuestTerminalSize.stepped(24, by: 1), 24)
        XCTAssertEqual(GuestTerminalSize.stepped(9.5, by: -1), 9)
        XCTAssertEqual(GuestTerminalSize.stepped(9, by: -1), 9)
    }

    /// The host clamps a guest's lease to at most 60 s: the renewal must land well inside
    /// the lease actually granted, or the guest's size lapses between renewals.
    func testLeaseIsRenewedWithinTheGuestTTLClamp() {
        let granted = min(GuestTerminalSize.leaseTTLMillis, 60_000)
        XCTAssertLessThanOrEqual(GuestTerminalSize.leaseRenewalNanos / 1_000_000, granted / 2)
    }
}
