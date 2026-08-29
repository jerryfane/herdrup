import Foundation
import XCTest
@testable import HerdrKit

final class SessionTransferTests: XCTestCase {
    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var requests: [String] = []
        var transferPhase = "ready"

        func roundTrip(_ requestLine: String) async throws -> String {
            requests.append(requestLine)
            if requestLine.contains(#""method":"ping""#) {
                return #"{"id":"x","result":{"type":"pong","version":"0.8.2","protocol":9,"capabilities":{"live_handoff":true,"agent_session_transfer":true}}}"#
            }
            return SessionTransferTests.transferResponse(phase: transferPhase)
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct FixedTransport: HerdrTransport {
        let response: String
        func roundTrip(_ requestLine: String) async throws -> String { response }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static let omissions = #"{"tool_records":2,"reasoning_records":3,"system_records":1,"attachment_records":4,"metadata_records":5,"unsupported_blocks":6,"sidechain_records":7}"#

    private static func transferResponse(phase: String) -> String {
        #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"idle","account":"claude-main","session_transfer":{"id":"transfer-1","source":"claude","target":"codex","target_account":"codex-pro","phase":"\#(phase)","message_count":3,"omissions":\#(Self.omissions)}}}}"#
    }

    private func requestObject(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func testPingFeatureDetectsTransferAndDefaultsMissingFlagsFalse() async throws {
        let enabled = try await HerdrClient(transport: CapturingTransport()).serverCapabilities()
        XCTAssertEqual(enabled?.agentSessionTransfer, true)
        XCTAssertEqual(enabled?.liveHandoff, true)
        XCTAssertEqual(enabled?.paneInputStream, false)

        let old = FixedTransport(response:
            #"{"id":"x","result":{"type":"pong","version":"0.8.2","protocol":9,"capabilities":{"live_handoff":true}}}"#)
        let oldCapabilities = try await HerdrClient(transport: old).serverCapabilities()
        XCTAssertEqual(oldCapabilities?.agentSessionTransfer, false,
                       "an older daemon must hide the switch instead of advertising a call it cannot serve")
    }

    func testPrepareEncodesOnlyStageFieldsAndDecodesReviewFacts() async throws {
        let transport = CapturingTransport()
        let agent = try await HerdrClient(transport: transport)
            .prepareAgentSessionTransfer(target: "jarvis", to: .codex, account: "codex-pro")

        let transfer = try XCTUnwrap(agent.sessionTransfer)
        XCTAssertEqual(transfer.id, "transfer-1")
        XCTAssertEqual(transfer.source, .claude)
        XCTAssertEqual(transfer.target, .codex)
        XCTAssertEqual(transfer.targetAccount, "codex-pro")
        XCTAssertEqual(transfer.phase, .ready)
        XCTAssertEqual(transfer.messageCount, 3)
        XCTAssertEqual(transfer.omissions.total, 28)

        let request = try requestObject(try XCTUnwrap(transport.requests.last))
        XCTAssertEqual(request["method"] as? String, "agent.transfer_session")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["target"] as? String, "jarvis")
        XCTAssertEqual(params["to"] as? String, "codex")
        XCTAssertEqual(params["account"] as? String, "codex-pro")
        XCTAssertNil(params["transfer_id"])
        XCTAssertNil(params["confirm"], "prepare must never smuggle an implicit confirmation")
    }

    func testConfirmEchoesExactTransactionHarnessAndAccount() async throws {
        let transport = CapturingTransport()
        transport.transferPhase = "verifying_cutover"
        let agent = try await HerdrClient(transport: transport)
            .confirmAgentSessionTransfer(
                target: "jarvis", to: .codex, account: "codex-pro",
                transferID: "transfer-1")

        XCTAssertEqual(agent.sessionTransfer?.phase, .verifyingCutover)
        let request = try requestObject(try XCTUnwrap(transport.requests.last))
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["target"] as? String, "jarvis")
        XCTAssertEqual(params["to"] as? String, "codex")
        XCTAssertEqual(params["account"] as? String, "codex-pro")
        XCTAssertEqual(params["transfer_id"] as? String, "transfer-1")
        XCTAssertEqual(params["confirm"] as? Bool, true)
    }

    func testOlderAgentInfoWithoutTransferStillDecodes() async throws {
        let transport = FixedTransport(response:
            #"{"id":"x","result":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"idle"}]}}"#)
        let agents = try await HerdrClient(transport: transport).agentList()
        XCTAssertEqual(agents.count, 1)
        XCTAssertNil(agents[0].sessionTransfer)
    }

    func testUnknownPhaseAndMissingOmissionCountersStayVisible() async throws {
        let transport = FixedTransport(response:
            #"{"id":"x","result":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","session_transfer":{"id":"transfer-2","source":"claude","target":"codex","phase":"verifying_future_state","message_count":0,"omissions":{}}}]}}"#)
        let agents = try await HerdrClient(transport: transport).agentList()
        let transfer = try XCTUnwrap(agents.first?.sessionTransfer)
        XCTAssertEqual(transfer.phase, .unrecognised("verifying_future_state"))
        XCTAssertTrue(transfer.phase.isTerminal,
                      "a state this app cannot interpret must stop polling and demand attention")
        XCTAssertEqual(transfer.omissions.total, 0)
    }

    func testTransferRejectionRemainsARealAPIError() async throws {
        let transport = FixedTransport(response:
            #"{"id":"x","error":{"code":"session_transfer_changed","message":"source changed; source stayed running"}}"#)
        do {
            _ = try await HerdrClient(transport: transport)
                .confirmAgentSessionTransfer(
                    target: "jarvis", to: .codex, transferID: "transfer-1")
            XCTFail("a refused cutover must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "session_transfer_changed")
            XCTAssertTrue(error.message.contains("source stayed running"))
        }
    }
}
