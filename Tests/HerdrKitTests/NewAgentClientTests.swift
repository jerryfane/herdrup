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

    func testClosePaneSendsPaneID() async throws {
        let t = CapturingTransport()
        try await HerdrClient(transport: t).closePane(paneID: "w1:p9")
        XCTAssertTrue(t.lastRequest.contains("pane.close"), "wrong method")
        XCTAssertTrue(t.lastRequest.contains("\"pane_id\""), "pane_id must use the snake_case wire key")
        XCTAssertTrue(t.lastRequest.contains("w1:p9"))
    }

    /// AXIS: the happy path must not prompt before the agent is ready. waitForReady
    /// polls agent.list until interactive_ready is true; here it flips true on the
    /// 2nd poll, so the call must poll at least twice and then return.
    func testWaitForReadyPollsUntilInteractiveReady() async throws {
        final class ReadyAfterTwo: HerdrTransport, @unchecked Sendable {
            var listCalls = 0
            func roundTrip(_ requestLine: String) async throws -> String {
                if requestLine.contains("agent.list") {
                    listCalls += 1
                    let ready = listCalls >= 2 ? "true" : "false"
                    return #"{"id":"x","result":{"type":"agent_list","agents":[{"pane_id":"w1:p9","interactive_ready":\#(ready)}]}}"#
                }
                return #"{"id":"x","result":{}}"#
            }
            func stream(_ r: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let t = ReadyAfterTwo()
        try await HerdrClient(transport: t).waitForReady(pane: "w1:p9", timeoutMs: 1000, pollMs: 1)
        XCTAssertGreaterThanOrEqual(t.listCalls, 2, "should have polled until ready")
    }

    /// AXIS: a never-ready agent must TIME OUT, not spin forever — the caller then
    /// surfaces an honest error rather than blocking the UI.
    func testWaitForReadyTimesOut() async throws {
        final class NeverReady: HerdrTransport, @unchecked Sendable {
            func roundTrip(_ r: String) async throws -> String {
                #"{"id":"x","result":{"type":"agent_list","agents":[{"pane_id":"w1:p9","interactive_ready":false}]}}"#
            }
            func stream(_ r: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        do {
            try await HerdrClient(transport: NeverReady()).waitForReady(pane: "w1:p9", timeoutMs: 5, pollMs: 1)
            XCTFail("expected a timeout")
        } catch let error as HerdrClient.ReadyError {
            XCTAssertEqual(error, .timedOut(pane: "w1:p9"))
        }
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
