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
        // Anchor the method to the whole value so a suffix (pane.splitx) fails.
        XCTAssertTrue(t.lastRequest.contains(#""method":"pane.split""#), "wrong method")
        // Slash-independent: JSONEncoder escapes "/" as "\/", so match the key +
        // the (slashless) folder name rather than the literal path.
        XCTAssertTrue(t.lastRequest.contains("\"cwd\""), "cwd key (the folder) was not sent")
        XCTAssertTrue(t.lastRequest.contains("herdr-ios"), "cwd value (the folder) was not sent")
        XCTAssertTrue(t.lastRequest.contains(#""direction":"down""#), "direction was not sent")
        XCTAssertTrue(t.lastRequest.contains(#""focus":true"#), "focus flag was not sent as expected")
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
        XCTAssertTrue(t.lastRequest.contains(#""method":"agent.start""#), "wrong method")
        // Pin the key:value PAIRS, not just the keys — otherwise transposing name
        // and kind (spawn the wrong kind under the wrong name) survives.
        XCTAssertTrue(t.lastRequest.contains(#""name":"fix-tests""#), "name/value not sent correctly")
        XCTAssertTrue(t.lastRequest.contains(#""kind":"codex""#), "kind/value not sent correctly")
        // The pane id must go out under the snake_case wire key the server expects.
        XCTAssertTrue(t.lastRequest.contains(#""pane_id":"w1:p9""#), "pane_id must use the snake_case wire key")
    }

    /// AXIS: a server error envelope from these methods surfaces as a thrown
    /// APIError — the property the whole spawn flow's error handling leans on.
    func testServerErrorSurfacesAsAPIError() async throws {
        struct ErrorTransport: HerdrTransport {
            func roundTrip(_ r: String) async throws -> String {
                #"{"id":"x","error":{"code":"agent_not_ready","message":"agent w1:p9 is not ready"}}"#
            }
            func stream(_ r: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let client = HerdrClient(transport: ErrorTransport())
        do {
            _ = try await client.splitPane(cwd: "/x")
            XCTFail("expected the error envelope to throw")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "agent_not_ready")
        }
    }

    func testClosePaneSendsPaneID() async throws {
        let t = CapturingTransport()
        try await HerdrClient(transport: t).closePane(paneID: "w1:p9")
        XCTAssertTrue(t.lastRequest.contains("pane.close"), "wrong method")
        XCTAssertTrue(t.lastRequest.contains("\"pane_id\""), "pane_id must use the snake_case wire key")
        XCTAssertTrue(t.lastRequest.contains("w1:p9"))
    }
}

/// Normalizing an arbitrary folder name to herdr's agent-name grammar, so
/// agent.start never fails on the name AFTER a pane was created.
final class AgentNameTests: XCTestCase {
    func testKeepsAlreadyValidName() { XCTAssertEqual(AgentName.normalize("herdr-ios"), "herdr-ios") }
    func testLowercases() { XCTAssertEqual(AgentName.normalize("Herdr-iOS"), "herdr-ios") }
    func testDropsLeadingNonLettersAndMapsSeparators() { XCTAssertEqual(AgentName.normalize("~/My Project"), "my-project") }
    func testLeadingDigitsDropped() { XCTAssertEqual(AgentName.normalize("123abc"), "abc") }

    func testEmptyAndAllInvalidFallBackToAgent() {
        XCTAssertEqual(AgentName.normalize(""), "agent")
        XCTAssertEqual(AgentName.normalize("工作"), "agent")
        XCTAssertEqual(AgentName.normalize("///"), "agent")
    }

    func testTruncatesTo32() {
        XCTAssertEqual(AgentName.normalize(String(repeating: "a", count: 40)).count, 32)
    }

    /// AXIS: whatever the input, the output ALWAYS matches ^[a-z][a-z0-9_-]{0,31}$.
    func testOutputAlwaysMatchesGrammar() {
        for raw in ["herdr-ios", "Herdr-iOS", "~/My Project", "123", "工作", "",
                    "UPPER_CASE.dot", "a b c d e f g h i j k l m n o p q r"] {
            let n = AgentName.normalize(raw)
            XCTAssertFalse(n.isEmpty, "\(raw.debugDescription) produced an empty name")
            XCTAssertLessThanOrEqual(n.count, 32)
            XCTAssertTrue(("a"..."z").contains(n.first!), "\(n) must start with a letter")
            for ch in n {
                XCTAssertTrue(("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "-" || ch == "_",
                              "\(n) has an invalid character \(ch)")
            }
        }
    }
}
