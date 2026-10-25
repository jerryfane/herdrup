#if DEBUG
import Foundation
import HerdrKit

@MainActor
enum ChatUXSmoke {
    private static var responses = 0
    private static let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

    static func reply(_ line: String) async -> String? {
        guard ProcessInfo.processInfo.environment["HERDR_CHAT_UX_SMOKE"] == "1" else { return nil }
        let request = ChatMockConversation.requestObject(line)
        guard request["method"] as? String == "agent.transcript" else { return nil }
        let id = request["id"] as? String ?? "smoke"
        let params = request["params"] as? [String: Any] ?? [:]
        responses += 1
        if responses > 1 {
            try? await Task.sleep(for: .seconds(3))
            if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_FAIL_REFRESH"] == "1" {
                return ChatMockConversation.error(id: id, code: "transcript_unavailable", message: "Smoke refresh unavailable")
            }
        }
        let original = ChatMockConversation.owner.transcript(id: id, params: params)
        guard params["before"] == nil,
              let response = try? JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any],
              var result = response["result"] as? [String: Any],
              var entries = result["entries"] as? [[String: Any]] else { return original }
        entries.append(["id": "ux-user", "kind": "user", "author": "owner",
                        "text": "Check typography and wrapped tables.", "ts_ms": timestamp])
        entries.append(["id": "ux-thought", "kind": "thinking",
                        "text": "**Check the table**\n\nUse *wrapped* cells and `literal` code.\n\n- Keep the caption\n- Preserve Unicode: café\n- Find literal `.*[x]` safely.", "ts_ms": timestamp + 1])
        entries.append(["id": "ux-reply", "kind": "reply", "final": true,
                        "text": "## Wrapped table\n\n| Metric | Description | Result |\n| --- | --- | --- |\n| Latency | A deliberately long description that must wrap within its column | +12% |\n| Unicode | café 東京 résumé | 42 |\n\nA complete fixture response.", "ts_ms": timestamp + 2])
        if responses > 1 {
            entries.append(["id": "ux-incoming", "kind": "reply", "final": true,
                            "text": "Incoming café update after refresh.", "ts_ms": timestamp + 3])
        }
        result["entries"] = entries
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_PENDING_QUESTION"] != "1" {
            result["pending_ask"] = NSNull()
        }
        result["working"] = NSNull()
        result["model"] = ["provider": "fixture", "id": "fixture-model"]
        result["plan"] = [
            ["text": "Review the table", "done": false, "status": "in_progress", "phase": "Verification"],
            ["text": "Ship after review", "done": false, "status": "blocked", "phase": "Verification", "blocker": "Independent review"]
        ]
        result["recap"] = ["turn_id": "ux-reply", "text": "Fixture recap only: typography is ready for inspection."]
        return ChatMockConversation.encode(id: id, result: result)
    }
}
#endif
