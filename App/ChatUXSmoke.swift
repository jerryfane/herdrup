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
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_LARGE"] == "1" {
            entries += largeTurns(endingBefore: timestamp)
        }
        entries.append(["id": "ux-user", "kind": "user", "author": "owner",
                        "text": "Check typography and wrapped tables.", "ts_ms": timestamp])
        entries.append(["id": "ux-thought", "kind": "thinking",
                        "text": "**Check the table**\n\nUse *wrapped* cells and `literal` code.\n\n- Keep the caption\n- Preserve Unicode: café\n- Find literal `.*[x]` safely.", "ts_ms": timestamp + 1])
        entries.append(["id": "ux-reply", "kind": "reply", "final": true,
                        "text": "## Wrapped table\n\n| Metric | Description | Result |\n| --- | --- | --- |\n| Latency | A deliberately long description that must wrap within its column | +12% |\n| Unicode | café 東京 résumé | 42 |\n\nA complete fixture response.", "ts_ms": timestamp + 2])
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_COPY"] == "1" {
            entries.append(["id": "ux-copy", "kind": "reply", "final": true,
                            "text": "Copy **this** reply, then *paste* it.\n\n```swift\nlet copied = true\nprint(copied)\n```",
                            "ts_ms": timestamp + 2])
        }
        if responses > 1 {
            entries.append(["id": "ux-incoming", "kind": "reply", "final": true,
                            "text": "Incoming café update after refresh.", "ts_ms": timestamp + 3])
            entries.append(["id": "ux-incoming-later", "kind": "reply", "final": true,
                            "text": "Incoming update \(responses).\n\n" + String(repeating: "More streamed content.\n\n", count: responses), "ts_ms": timestamp + 4])
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

    /// Six turns × 80 reply paragraphs: the large fixture says "example" 480 times, once
    /// per reply paragraph and nowhere else in the mock conversation (under the search cap,
    /// so `ChatUXSmokeTests` can expect the exact count).
    private static let largeTurnCount = 6
    private static let largeReplyParagraphs = 80

    /// `HERDR_CHAT_UX_LARGE=1`: a long session like the one that froze Chat search
    /// (herdrup#523 item 8). Six turns with ~14 KB replies, ~6 KB thoughts and 300-character
    /// step details, full of characters that case folding splits or expands (skin tones,
    /// flags, a ZWJ family, ß, İ, the ﬁ ligature, a decomposed é). A one-letter search
    /// finds thousands of matches.
    private static func largeTurns(endingBefore end: UInt64) -> [[String: Any]] {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let reply = String(repeating: "Release review: the service executes every queued request, then rechecks the cache entries 👍🏽 🇺🇸 \(family) Straße İstanbul ﬁle cafe\u{301} example.\n\n",
                           count: largeReplyParagraphs)
        let thought = String(repeating: "Considering whether the deployment needs another pass over the queue 👍🏽 \(family) STRASSE ﬁnal rese\u{301}rve.\n\n",
                             count: 40)
        let detail = String(String(repeating: "verify the release sequence step ", count: 10).prefix(300))
        var entries: [[String: Any]] = []
        var ts = end - 1_000_000
        func add(_ id: String, _ fields: [String: Any]) {
            var entry = fields
            entry["id"] = id
            entry["ts_ms"] = ts
            ts += 1_000
            entries.append(entry)
        }
        for turn in 0..<largeTurnCount {
            add("large-\(turn)u", ["kind": "user", "author": "owner", "text": "Large review \(turn): go over the release notes"])
            add("large-\(turn)t", ["kind": "thinking", "text": thought])
            for step in 0..<(turn == 0 ? 50 : 4) {
                add("large-\(turn)s\(step)", ["kind": "step", "tool": "bash", "intent": "Verifying release step \(step)",
                                              "status": "ok", "detail": detail])
            }
            add("large-\(turn)r", ["kind": "reply", "final": true, "text": reply])
            add("large-\(turn)e", ["kind": "turn_end", "status": "done"])
        }
        return entries
    }
}
#endif
