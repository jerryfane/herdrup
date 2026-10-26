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

    func testAShareFollowsTheOwnerRenamingItsAgent() throws {
        let access = GuestAccess(guestID: "g1", guestName: "guest", machineLabel: "Host",
                                 ownerName: "Owner", agentName: "llm-opt", agentTarget: "term_1",
                                 endpoint: FakeHost().endpoint, acceptedAt: Date(timeIntervalSince1970: 1))
        func listing(_ json: String) throws -> [AgentInfo] {
            try JSONDecoder().decode([AgentInfo].self, from: Data(json.utf8))
        }
        let unchanged = try listing(#"[{"terminal_id":"term_1","pane_id":"w1:p1","name":"llm-opt"}]"#)
        XCTAssertNil(access.renamed(listing: unchanged))
        // Another terminal's agent, whatever it is called, is not this share.
        let elsewhere = try listing(#"[{"terminal_id":"term_2","pane_id":"w1:p2","name":"llm-new"}]"#)
        XCTAssertNil(access.renamed(listing: elsewhere))
        XCTAssertNil(access.renamed(listing: []))

        let renamed = try XCTUnwrap(access.renamed(listing: listing(
            #"[{"terminal_id":"term_1","pane_id":"w1:p1","name":"llm-new"}]"#)))
        XCTAssertEqual(renamed.agentName, "llm-new")
        XCTAssertEqual(renamed.id, access.id)
        XCTAssertEqual(renamed.agentTarget, "term_1")
        XCTAssertEqual(renamed.endpoint, access.endpoint)
        XCTAssertEqual(renamed.acceptedAt, access.acceptedAt)
        // The saved share keeps its shape: the renamed one round-trips through the store's JSON.
        let saved = try JSONDecoder().decode(GuestAccess.self, from: JSONEncoder().encode(renamed))
        XCTAssertEqual(saved, renamed)
    }
}
