import Foundation
import XCTest
@testable import HerdrKit

/// The `origin_machine_id` a question push is routed by (`agent.answer` itself is
/// covered by `AgentTranscriptClientTests`).
final class AgentOriginMachineTests: XCTestCase {
    func testAgentListingCarriesOriginMachineID() async throws {
        let transport = RecordingTransport(reply:
            #"{"id":"x","result":{"type":"agent_list","agents":[],"origin_machine_id":"machine_0f"}}"#)
        let listing = try await HerdrClient(transport: transport).agentListing()
        XCTAssertEqual(listing.originMachineID, "machine_0f")

        let older = RecordingTransport(reply: #"{"id":"x","result":{"type":"agent_list","agents":[]}}"#)
        let olderListing = try await HerdrClient(transport: older).agentListing()
        XCTAssertNil(olderListing.originMachineID)
    }
}
