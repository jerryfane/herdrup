import XCTest
import Foundation
@testable import HerdrKit

/// Validates the JSON the app's DEBUG screenshot-mock transport returns actually
/// decodes through the real `HerdrClient` path — so the iOS mock (which cannot be
/// compiled/run on Linux) embeds wire JSON proven correct here, not guessed.
/// Keep these fixtures byte-identical to App/HerdrApp.swift's MockTransport.
final class MockWireFixtureTests: XCTestCase {

    /// A canned-response transport standing in for MockTransport.
    private struct FixtureTransport: HerdrTransport {
        func roundTrip(_ requestLine: String) async throws -> String {
            if requestLine.contains("agent.list") { return MockWireFixtures.agentList }
            if requestLine.contains("agent.read") { return MockWireFixtures.agentRead }
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testMockAgentListDecodesToThreeAgents() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        XCTAssertEqual(agents.count, 3, "mock agent.list did not decode to 3 agents")
        XCTAssertEqual(agents.first?.paneID, "w1:p1")
        XCTAssertEqual(agents.first?.displayName, "jarvis")
        XCTAssertTrue(agents.first?.isWorking ?? false, "first mock agent should read as working")
    }

    func testMockReadDecodesPaneText() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let read = try await client.read(pane: "w1:p1", source: .recentUnwrapped, format: .text, lines: 200)
        XCTAssertEqual(read.paneID, "w1:p1")
        XCTAssertTrue(read.text.contains("demo data"), "mock pane text missing its marker: \(read.text.prefix(80))")
    }
}

/// THE FIXTURES. Duplicated verbatim in App/HerdrApp.swift's MockTransport (the
/// app target can't be compiled on Linux, so this is the only place the JSON is
/// machine-checked). If you change one, change both.
enum MockWireFixtures {
    static let agentList = #"""
    {"id":"mock","result":{"type":"agent_list","agents":[
      {"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"working","terminal_title_stripped":"omp-runtime-adapter"},
      {"pane_id":"w1:p2","name":"herdr-app","agent":"claude","agent_status":"done","terminal_title_stripped":"citadel-transport"},
      {"pane_id":"w2:p1","name":"trend-scout","agent":"codex","agent_status":"idle","terminal_title_stripped":"digest-pipeline"}
    ]}}
    """#

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent list\n3 agents running\n\n* jarvis      working   omp-runtime-adapter\n* herdr-app   done      citadel-transport\n* trend-scout idle      digest-pipeline\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#
}
