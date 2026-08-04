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

    func testMockAgentListDecodesAllStates() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        // The redesigned list groups by status, so the fixture must carry every
        // section: needs-you, stopped, working, done, idle.
        XCTAssertEqual(agents.count, 8, "mock agent.list did not decode to 8 agents")
        XCTAssertEqual(agents.first?.paneID, "w1:p1")
        XCTAssertEqual(agents.first?.displayName, "codex")
        XCTAssertEqual(agents.first?.agentStatus, "input_pending",
                       "first mock agent should be blocked-on-you, driving the NEEDS YOU section")
        XCTAssertFalse(agents.first?.isWorking ?? true, "a blocked agent is not working")

        let statuses = Set(agents.compactMap { $0.agentStatus })
        // One representative from each section the mockup renders: 2 needs-you
        // (input_pending + waiting), 1 stopped (exited), 1 working, 4 idle.
        for expected in ["input_pending", "waiting", "exited", "working", "idle"] {
            XCTAssertTrue(statuses.contains(expected),
                          "fixture missing an agent with agent_status \(expected)")
        }
        XCTAssertEqual(agents.filter { $0.agentStatus == "idle" }.count, 4,
                       "mockup composition is IDLE · 4")
        XCTAssertEqual(agents.filter { $0.isWorking }.count, 1,
                       "only the literal \"working\" agent should read as working")
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
      {"pane_id":"w1:p1","name":"codex","agent":"codex","agent_status":"input_pending","terminal_title_stripped":"herdr-ios · asking to run tests"},
      {"pane_id":"w1:p2","name":"claude","agent":"claude","agent_status":"waiting","terminal_title_stripped":"vetrina · overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"codex","agent":"codex","agent_status":"exited","terminal_title_stripped":"trend-scout · exited, code 1"},
      {"pane_id":"w2:p2","name":"claude","agent":"claude","agent_status":"working","terminal_title_stripped":"herdr · editing src/acp.rs"},
      {"pane_id":"w3:p1","name":"claude","agent":"claude","agent_status":"idle","terminal_title_stripped":"clientloop · amigo-poc scaffold"},
      {"pane_id":"w3:p2","name":"codex","agent":"codex","agent_status":"idle","terminal_title_stripped":"aste-screener · apify-harvest"},
      {"pane_id":"w4:p1","name":"gemini","agent":"gemini","agent_status":"idle","terminal_title_stripped":"discovery · redaction-pass v3"},
      {"pane_id":"w4:p2","name":"claude","agent":"claude","agent_status":"idle","terminal_title_stripped":"bank-qa · deal-assistant rag"}
    ]}}
    """#

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach codex\n\n> may I run `just test` on herdr-ios?\n  177 tests, ~30s, no network\n\n  [y] allow   [n] deny   [a] always\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#
}
