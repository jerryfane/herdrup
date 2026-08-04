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

    func testMockAgentListDecodesRealisticStatuses() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        XCTAssertEqual(agents.count, 8, "mock agent.list did not decode to 8 agents")
        XCTAssertEqual(agents.first?.paneID, "w1:p1")
        XCTAssertEqual(agents.first?.displayName, "jarvis",
                       "the card headlines the assigned name; fixtures must carry distinct names")
        XCTAssertEqual(agents.first?.agent, "claude", "the identity icon is keyed on the kind, not the name")
        XCTAssertEqual(agents.first?.cwd, "/root/herdr-ios",
                       "cwd must decode — the card subtitle composes folder from it")
        XCTAssertEqual(agents.first?.agentStatus, "blocked",
                       "first mock agent should be blocked (drives NEEDS YOU)")

        // Every status here must be a real herdr wire value, or it would decode
        // as .unrecognised and the mock would render a section the mockup lacks.
        let known: Set = ["idle", "working", "blocked", "done", "unknown"]
        for agent in agents {
            let status = agent.agentStatus ?? "idle"
            XCTAssertTrue(known.contains(status),
                          "fixture uses a non-herdr status \(status); it would land in UNRECOGNISED")
        }
    }

    /// The whole point of the fixture: rendered through the REAL grouping model
    /// with the mock census, it must produce the mockup's composition —
    /// NEEDS YOU 2, STOPPED 1 (from liveness, not a status string), WORKING 1,
    /// IDLE 4 (done folded in). A regression in fixture OR model trips here.
    func testMockRendersMockupComposition() async throws {
        let client = HerdrClient(transport: FixtureTransport())
        let agents = try await client.agentList()
        let list = AgentList(agents: agents, livePaneIDs: MockWireFixtures.demoLivePaneIDs)

        XCTAssertEqual(list.sections.map(\.group),
                       [.needsYou, .stopped, .working, .idle],
                       "sections did not render in the mockup's order/composition")
        let counts = Dictionary(uniqueKeysWithValues: list.sections.map { ($0.group, $0.rows.count) })
        XCTAssertEqual(counts[.needsYou], 2)
        XCTAssertEqual(counts[.stopped], 1)
        XCTAssertEqual(counts[.working], 1)
        XCTAssertEqual(counts[.idle], 4, "the done agent should fold into idle, making IDLE · 4")
        XCTAssertEqual(list.needsYouCount, 2, "header would show the wrong 'N need you'")

        // STOPPED must come from liveness: w2:p1 is the excluded pane, and its
        // status string is a quiet 'idle' — so if it shows as stopped, that is
        // the census talking, which is the behaviour under test.
        let stopped = try XCTUnwrap(list.sections.first { $0.group == .stopped }).rows
        XCTAssertEqual(stopped.map(\.info.paneID), ["w2:p1"])
        XCTAssertEqual(stopped.first?.status, .idle,
                       "premise: the stopped row's own status is idle; only the census makes it stopped")
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
      {"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"},
      {"pane_id":"w1:p2","name":"vetrina","agent":"codex","agent_status":"blocked","cwd":"/root/vetrina","terminal_title_stripped":"overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"trend-scout","agent":"codex","agent_status":"idle","cwd":"/root/trend-scout","terminal_title_stripped":"exited, code 1"},
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs"},
      {"pane_id":"w3:p1","name":"clientloop","agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold"},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","name":"discovery","agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"}
    ]}}
    """#

    /// The census the App's mock render passes (MockTransport.demoLivePaneIDs).
    /// Excludes w2:p1 so it groups STOPPED via liveness. Keep in sync with the App.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2",
    ]

    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach jarvis\n\n> Ran 146 tests, 0 failures\n> Edited SessionRecoveryTests.swift  +18 -4\n\nRun `swift test` with -Xswiftc -warnings-as-errors?\n  1. yes\n  2. no, skip it\n>\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#
}
