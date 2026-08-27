import XCTest
@testable import HerdrKit

/// The client has TWO key senders on purpose, and which one a caller picks decides
/// whether the call works at all.
///
/// `agent.send_keys` resolves a pane id only when that pane is an AGENT terminal. The
/// sign-in and sign-out flows split a fresh shell and press Enter in it, so routing them
/// through the agent method failed every time with
/// `agent target <pane> not found` — sign-in visibly, sign-out quietly into a banner.
///
/// The two are not interchangeable in the other direction either: `agent.send_keys` also
/// refuses a pane whose running process is not the expected agent, and records a turn
/// abort for interrupting keys. So this pins BOTH methods and BOTH param shapes — a
/// future "these look duplicated, merge them" fails here instead of in the field.
final class SendKeysTargetingTests: XCTestCase {

    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A plain shell pane must go to the PANE method, keyed by `pane_id`.
    func testSendPaneKeysUsesThePaneMethod() async throws {
        let t = CapturingTransport()
        try await HerdrClient(transport: t).sendPaneKeys(pane: "wV:pM", keys: ["Enter"])

        XCTAssertTrue(t.lastRequest.contains(#""method":"pane.send_keys""#),
                      "a shell pane must not be sent to the agent method: \(t.lastRequest)")
        XCTAssertTrue(t.lastRequest.contains(#""pane_id":"wV:pM""#),
                      "pane.send_keys is keyed by pane_id, not target: \(t.lastRequest)")
        XCTAssertTrue(t.lastRequest.contains("Enter"))
    }

    /// An agent pane must still go to the AGENT method, keyed by `target`, so the
    /// agent-hosting check and turn-abort bookkeeping are not lost.
    func testSendKeysStillUsesTheAgentMethod() async throws {
        let t = CapturingTransport()
        try await HerdrClient(transport: t).sendKeys(pane: "w1:p3", keys: ["Escape"])

        XCTAssertTrue(t.lastRequest.contains(#""method":"agent.send_keys""#),
                      "the agent path must keep its agent-specific handling: \(t.lastRequest)")
        XCTAssertTrue(t.lastRequest.contains(#""target":"w1:p3""#),
                      "agent.send_keys is keyed by target, not pane_id: \(t.lastRequest)")
    }

    /// The two must not converge on one wire method — that is precisely the bug.
    func testTheTwoSendersDoNotShareAWireMethod() async throws {
        let a = CapturingTransport(), b = CapturingTransport()
        try await HerdrClient(transport: a).sendPaneKeys(pane: "p", keys: ["Enter"])
        try await HerdrClient(transport: b).sendKeys(pane: "p", keys: ["Enter"])
        XCTAssertNotEqual(a.lastRequest, b.lastRequest,
                          "pane and agent key sends collapsed onto one request shape")
    }
}
