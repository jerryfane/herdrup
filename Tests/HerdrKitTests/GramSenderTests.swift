import XCTest
@testable import HerdrKit

/// A Gram from an agent on a federated machine arrives as `<alias>/<name>`, the alias being
/// the machine's 32-hex id. herdr#277: the daemon adds the machine's `machine_label`, and the
/// app shows `<label>/<name>`, exactly like a federated agent's row.
final class GramSenderTests: XCTestCase {
    private struct ListTransport: HerdrTransport {
        let reply: String
        func roundTrip(_ requestLine: String) async throws -> String { reply }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let alias = "8195b6326f748f4da1945364a4e205b9"

    private func list(_ messages: String) async throws -> [GramMessage] {
        let reply = #"{"id":"x","result":{"type":"gram_list","messages":["# + messages + "]}}"
        let answer = try await HerdrClient(transport: ListTransport(reply: reply)).gramList()
        return try XCTUnwrap(answer.messages)
    }

    private func message(_ id: String, from: String, extra: String = "") -> String {
        #"{"id":"\#(id)","direction":"agent_to_owner","from":"\#(from)","text":"hi","created_unix_ms":1750000000000,"read_by_owner":false\#(extra)}"#
    }

    func testAFederatedSenderReadsAsItsMachineLabel() async throws {
        let messages = try await list([
            message("g1", from: "\(alias)/llm-opt", extra: #","machine_label":"Mac Studio""#),
            // The rest of the name may itself hold slashes; only the alias is swapped.
            message("g2", from: "\(alias)/w1:p2/scout", extra: #","machine_label":"Mac Studio""#),
        ].joined(separator: ","))

        XCTAssertEqual(messages[0].machineLabel, "Mac Studio")
        XCTAssertEqual(messages[0].senderName, "Mac Studio/llm-opt")
        XCTAssertEqual(messages[0].from, "\(alias)/llm-opt", "the routing name stays as sent")
        XCTAssertEqual(messages[1].senderName, "Mac Studio/w1:p2/scout")
    }

    /// An older daemon, a machine without a saved label, a blank label, or a local sender:
    /// the sender reads exactly as `from`.
    func testWithoutALabelTheSenderIsUnchanged() async throws {
        let messages = try await list([
            message("g1", from: "\(alias)/llm-opt"),
            message("g2", from: "\(alias)/llm-opt", extra: #","machine_label":"""#),
            message("g3", from: "trend-scout"),
            message("g4", from: "trend-scout", extra: #","machine_label":"Mac Studio""#),
        ].joined(separator: ","))

        XCTAssertNil(messages[0].machineLabel)
        XCTAssertEqual(messages.map(\.senderName),
                       ["\(alias)/llm-opt", "\(alias)/llm-opt", "trend-scout", "trend-scout"])
    }

    /// Gram senders and agent rows share one formatting: the same name and label read the same.
    func testGramSenderMatchesTheAgentRowForTheSameMachine() async throws {
        let agents = try JSONDecoder().decode([AgentInfo].self, from: Data("""
        [{"pane_id":"\(alias)/w1:p2","name":"\(alias)/llm-opt","machine_id":"\(alias)",
          "machine_label":"Mac Studio"}]
        """.utf8))
        let messages = try await list(
            message("g1", from: "\(alias)/llm-opt", extra: #","machine_label":"Mac Studio""#))
        XCTAssertEqual(messages[0].senderName, agents[0].displayName)
    }
}
