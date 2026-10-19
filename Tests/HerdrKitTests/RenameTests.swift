import XCTest
@testable import HerdrKit

/// The two rename client calls: renameAgent (agent.rename → ResponseResult::AgentInfo{agent}) and
/// renamePane (pane.rename → ResponseResult::PaneInfo{pane}). Both the request encoding (method name
/// + exact wire keys) and the response decoding are pinned against herdr's actual wire shapes, so a
/// wrong key or transposed field fails here rather than on-device.
final class RenameTests: XCTestCase {

    /// Replies with a canned response per method.
    private static func host() -> RecordingTransport {
        RecordingTransport(replies: [
            "agent.rename": #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","name":"planner","agent":"claude","agent_status":"working"}}}"#,
            "pane.rename": #"{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","label":"build logs"}}}"#,
        ])
    }

    func testRenameAgentSendsTargetAndNameAndDecodesTheAgent() async throws {
        let t = Self.host()
        let agent = try await HerdrClient(transport: t).renameAgent(target: "w1:p1", name: "planner")

        XCTAssertEqual(agent.displayName, "planner", "did not decode name from agent.rename's AgentInfo{agent}")
        XCTAssertEqual(agent.paneID, "w1:p1")
        XCTAssertTrue(t.lastRequest.contains(#""method":"agent.rename""#), "wrong method")
        // Pin the key:value PAIRS so transposing target/name would fail.
        XCTAssertTrue(t.lastRequest.contains(#""target":"w1:p1""#), "target/value not sent correctly")
        XCTAssertTrue(t.lastRequest.contains(#""name":"planner""#), "name/value not sent correctly")
    }

    func testRenamePaneSendsSnakeCasePaneIDAndLabel() async throws {
        let t = Self.host()
        try await HerdrClient(transport: t).renamePane(paneID: "w1:p2", label: "build logs")

        XCTAssertTrue(t.lastRequest.contains(#""method":"pane.rename""#), "wrong method")
        // The pane id must go out under the snake_case wire key the server expects.
        XCTAssertTrue(t.lastRequest.contains(#""pane_id":"w1:p2""#), "pane_id must use the snake_case wire key")
        XCTAssertTrue(t.lastRequest.contains(#""label":"build logs""#), "label/value not sent correctly")
    }

    /// AXIS: a duplicate/invalid name surfaces as a thrown APIError (agent_name_taken /
    /// invalid_agent_name) — what the rename UI leans on to show the reason instead of failing silently.
    func testRenameAgentServerErrorSurfacesAsAPIError() async throws {
        let transport = RecordingTransport.error(code: "agent_name_taken", message: "another agent already uses that name")
        do {
            _ = try await HerdrClient(transport: transport).renameAgent(target: "w1:p1", name: "planner")
            XCTFail("a duplicate-name rejection must throw, not return silently")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "agent_name_taken")
        }
    }
}
