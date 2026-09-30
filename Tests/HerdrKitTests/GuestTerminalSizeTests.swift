import XCTest
@testable import HerdrKit

final class GuestTerminalSizeTests: XCTestCase {

    /// Answers `pane.set_pty_size` from a script, one reply per call, and counts the calls.
    private final class ResizeHost: HerdrTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private(set) var calls = 0
        init(_ replies: [String]) { self.replies = replies }
        func roundTrip(_ requestLine: String) async throws -> String { next() }
        private func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        static func refusal(_ code: String) -> String {
            #"{"id":"x","error":{"code":"\#(code)","message":"refused"}}"#
        }
        static let applied =
            #"{"id":"x","result":{"type":"pane_pty_size","pane_id":"w1:p1","cols":50,"rows":40,"locked":true}}"#
    }

    private func resize(_ client: HerdrClient, lock: Bool) async throws -> PanePtySize {
        try await client.setPTYSize(pane: "w1-3", cols: 50, rows: 40, lock: lock)
    }

    /// An older host answers a guest's resize with `guest_forbidden` and always will: the
    /// first refusal closes the gate, and the caller hears about it once.
    func testForbiddenResizeClosesTheGateOnce() {
        let gate = PTYResizeGate()
        XCTAssertTrue(gate.noteFailure(APIError(code: "guest_forbidden", message: "guests can't call pane.set_pty_size")))
        XCTAssertTrue(gate.isClosed)
        XCTAssertFalse(gate.noteFailure(APIError(code: "guest_forbidden", message: "")),
                       "a closed gate reports the refusal only once")
        XCTAssertTrue(gate.isClosed)
    }

    /// Review P3: a guest leaving while its first lock:true is in flight queues a lock:false
    /// release behind it. When the lock:true comes back refused, the release must see that at
    /// send time and stay home: an older host is asked, and refuses, exactly once.
    func testAResizeQueuedBehindTheRefusalIsNeverSent() async throws {
        let host = ResizeHost([ResizeHost.refusal("guest_forbidden")])
        let client = HerdrClient(transport: host)
        let gate = PTYResizeGate()
        do {
            _ = try await gate.send { try await resize(client, lock: true) }
            XCTFail("the older host refuses guest resizing")
        } catch {
            XCTAssertEqual(GuestError.classify(error), .forbidden)
        }
        let release = try await gate.send { try await resize(client, lock: false) }
        XCTAssertNil(release, "a closed gate sends nothing")
        XCTAssertEqual(host.calls, 1, "one refusal, then no further set_pty_size")
    }

    /// A resize that raced the guest's stream open (`guest_no_stream`), a paused agent or a
    /// revoked grant is not an older host: the gate stays open and the next try is sent.
    func testARefusalThatCanLiftKeepsSending() async throws {
        for code in ["guest_no_stream", "guest_paused", "guest_revoked"] {
            let host = ResizeHost([ResizeHost.refusal(code), ResizeHost.applied])
            let client = HerdrClient(transport: host)
            let gate = PTYResizeGate()
            do {
                _ = try await gate.send { try await resize(client, lock: true) }
                XCTFail("\(code) is an error")
            } catch {}
            XCTAssertFalse(gate.isClosed, code)
            let retried = try await gate.send { try await resize(client, lock: true) }
            XCTAssertEqual(retried?.cols, 50, code)
            XCTAssertEqual(host.calls, 2, code)
        }
    }

    /// Failures that aren't a host's answer at all must not strand the guest in the
    /// fit-to-width fallback for the whole session either.
    func testTransportFailuresKeepTheGateOpen() {
        let gate = PTYResizeGate()
        for error: Error in [
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
