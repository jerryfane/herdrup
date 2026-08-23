import XCTest
@testable import HerdrKit

/// The two rename client calls: renameAgent (agent.rename → ResponseResult::AgentInfo{agent}) and
/// renamePane (pane.rename → ResponseResult::PaneInfo{pane}). Both the request encoding (method name
/// + exact wire keys) and the response decoding are pinned against herdr's actual wire shapes, so a
/// wrong key or transposed field fails here rather than on-device.
final class RenameTests: XCTestCase {

    /// Records the request line and replies with a canned response per method.
    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            if requestLine.contains("agent.rename") {
                return #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","name":"planner","agent":"claude","agent_status":"working"}}}"#
            }
            if requestLine.contains("pane.rename") {
                return #"{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","label":"build logs"}}}"#
            }
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testRenameAgentSendsTargetAndNameAndDecodesTheAgent() async throws {
        let t = CapturingTransport()
        let agent = try await HerdrClient(transport: t).renameAgent(target: "w1:p1", name: "planner")

        XCTAssertEqual(agent.displayName, "planner", "did not decode name from agent.rename's AgentInfo{agent}")
        XCTAssertEqual(agent.paneID, "w1:p1")
        XCTAssertTrue(t.lastRequest.contains(#""method":"agent.rename""#), "wrong method")
        // Pin the key:value PAIRS so transposing target/name would fail.
        XCTAssertTrue(t.lastRequest.contains(#""target":"w1:p1""#), "target/value not sent correctly")
        XCTAssertTrue(t.lastRequest.contains(#""name":"planner""#), "name/value not sent correctly")
    }

    func testRenamePaneSendsSnakeCasePaneIDAndLabel() async throws {
        let t = CapturingTransport()
        try await HerdrClient(transport: t).renamePane(paneID: "w1:p2", label: "build logs")

        XCTAssertTrue(t.lastRequest.contains(#""method":"pane.rename""#), "wrong method")
        // The pane id must go out under the snake_case wire key the server expects.
        XCTAssertTrue(t.lastRequest.contains(#""pane_id":"w1:p2""#), "pane_id must use the snake_case wire key")
        XCTAssertTrue(t.lastRequest.contains(#""label":"build logs""#), "label/value not sent correctly")
    }

    /// AXIS: a duplicate/invalid name surfaces as a thrown APIError (agent_name_taken /
    /// invalid_agent_name) — what the rename UI leans on to show the reason instead of failing silently.
    func testRenameAgentServerErrorSurfacesAsAPIError() async throws {
        struct ErrorTransport: HerdrTransport {
            func roundTrip(_ r: String) async throws -> String {
                #"{"id":"x","error":{"code":"agent_name_taken","message":"another agent already uses that name"}}"#
            }
            func stream(_ r: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        do {
            _ = try await HerdrClient(transport: ErrorTransport()).renameAgent(target: "w1:p1", name: "planner")
            XCTFail("a duplicate-name rejection must throw, not return silently")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "agent_name_taken")
        }
    }
}
