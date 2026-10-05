import XCTest
import Foundation
@testable import HerdrKit

/// #380: Close sends `agent.forget`, which herdr applies to the FIRST archived record
/// matching the target by name or terminal id. Two archived agents can share a name, so
/// the request must name the row the user picked by its unique terminal id.
final class ForgetAgentTargetTests: XCTestCase {

    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            return #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":""}}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func archived(name: String?, terminalID: String?) throws -> AgentInfo {
        var fields = [#""pane_id":"""#, #""archived":{"at":"2026-10-05T18:00:00Z"}"#]
        if let name { fields.append(#""name":"\#(name)""#) }
        if let terminalID { fields.append(#""terminal_id":"\#(terminalID)""#) }
        return try JSONDecoder().decode(AgentInfo.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func forgetRequest(for info: AgentInfo) async throws -> [String: Any] {
        let t = CapturingTransport()
        _ = try await HerdrClient(transport: t).forgetAgent(info)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(t.lastRequest.utf8)) as? [String: Any])
    }

    func testTwoArchivedAgentsWithTheSameNameAreForgottenByTheirOwnTerminalID() async throws {
        let first = try archived(name: "huurjacht", terminalID: "term_a")
        let second = try archived(name: "huurjacht", terminalID: "term_b")

        let request = try await forgetRequest(for: second)
        XCTAssertEqual(request["method"] as? String, "agent.forget")
        XCTAssertEqual((request["params"] as? [String: Any])?["target"] as? String, "term_b",
                       "closing the second row must not target the shared name, which herdr resolves to the first")

        let firstRequest = try await forgetRequest(for: first)
        XCTAssertEqual((firstRequest["params"] as? [String: Any])?["target"] as? String, "term_a")
    }

    func testARecordWithoutATerminalIDFallsBackToItsName() async throws {
        let request = try await forgetRequest(for: try archived(name: "huurjacht", terminalID: nil))
        XCTAssertEqual((request["params"] as? [String: Any])?["target"] as? String, "huurjacht")
    }
}
