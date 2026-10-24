import Foundation
import XCTest
@testable import HerdrKit

final class GuestGrantIsolationTests: XCTestCase {
    func testReplacedGrantCannotSendThroughAnotherShare() async throws {
        let host = FakeHost()
        let access = GuestAccess(guestID: "first-grant", guestName: "guest", machineLabel: "Host",
                                 ownerName: "Owner", agentName: "first-agent", agentTarget: "term_1",
                                 endpoint: host.endpoint, acceptedAt: Date(timeIntervalSince1970: 1))
        let transport = access.transport(identity: GuestIdentity(privateKey: .init()), connector: host.connector())
        host.reply = ["ok": true, "guest_id": "first-grant"]
        host.serve = { _ in [Data("{\"ok\":true}\n".utf8)] }
        let allowed = try await transport.roundTrip("allowed")
        XCTAssertEqual(allowed, "{\"ok\":true}")

        // Old hosts can bind the same device key to its newest invitation. The
        // earlier saved access must fail before ANY request crosses that channel.
        host.reply = ["ok": true, "guest_id": "second-grant"]
        do {
            _ = try await transport.roundTrip("must-not-reach-another-grant")
            XCTFail("A replaced share must not act through another grant")
        } catch let error as GuestError {
            XCTAssertEqual(error, .revoked)
        }
        XCTAssertEqual(host.requests, ["allowed"])
    }
}
