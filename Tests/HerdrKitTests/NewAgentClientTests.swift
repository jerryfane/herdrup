import XCTest
@testable import HerdrKit

/// The two client calls the new-agent flow adds: splitPane (make a pane in a
/// folder) and startAgent (launch a kind in that pane). Both the request encoding
/// and the response decoding are pinned against herdr's actual wire shapes
/// (pane.split -> ResponseResult::PaneInfo{pane}; agent.start ->
/// ResponseResult::AgentStarted{agent,argv}).
final class NewAgentClientTests: XCTestCase {

    /// Records the request line and replies with a canned response per method.
    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            if requestLine.contains("pane.split") {
                return #"{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w1:p9"}}}"#
            }
            if requestLine.contains("agent.start") {
                return #"{"id":"x","result":{"type":"agent_started","agent":{"pane_id":"w1:p9","name":"fix-tests","agent":"codex","agent_status":"working"},"argv":["codex"]}}"#
            }
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testSplitPaneSendsFolderAndDirectionAndReturnsNewPaneID() async throws {
        let t = CapturingTransport()
        let pane = try await HerdrClient(transport: t).splitPane(cwd: "/root/herdr-ios", direction: .down)

        XCTAssertEqual(pane, "w1:p9", "did not decode pane_id from pane.split's PaneInfo{pane} result")
        XCTAssertTrue(t.lastRequest.contains("pane.split"), "wrong method")
        // Slash-independent: JSONEncoder escapes "/" as "\/", so match the key +
        // the (slashless) folder name rather than the literal path.
        XCTAssertTrue(t.lastRequest.contains("\"cwd\""), "cwd key (the folder) was not sent")
        XCTAssertTrue(t.lastRequest.contains("herdr-ios"), "cwd value (the folder) was not sent")
        XCTAssertTrue(t.lastRequest.contains("down"), "direction was not sent")
    }

    func testSplitPaneOmitsCwdWhenNil() async throws {
        let t = CapturingTransport()
        _ = try await HerdrClient(transport: t).splitPane(cwd: nil)
        // A nil cwd must not be sent as an explicit null/empty — the server then
        // follows the split pane's own cwd.
        XCTAssertFalse(t.lastRequest.contains("\"cwd\""), "nil cwd should be omitted, not sent")
    }

    func testStartAgentSendsSnakeCasePaneIDAndDecodesTheAgent() async throws {
        let t = CapturingTransport()
        let agent = try await HerdrClient(transport: t).startAgent(name: "fix-tests", kind: "codex", paneID: "w1:p9")

        XCTAssertEqual(agent.paneID, "w1:p9")
        XCTAssertEqual(agent.agent, "codex")
        XCTAssertEqual(agent.displayName, "fix-tests")
        XCTAssertTrue(t.lastRequest.contains("agent.start"), "wrong method")
        // The pane id must go out under the wire key the server expects, not paneID.
        XCTAssertTrue(t.lastRequest.contains("\"pane_id\""), "pane_id must use the snake_case wire key")
        XCTAssertTrue(t.lastRequest.contains("\"kind\""), "kind was not sent")
        XCTAssertTrue(t.lastRequest.contains("fix-tests"), "name was not sent")
    }
}
