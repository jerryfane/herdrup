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
        // A subagent's own conversation: the mock's, at once, without counting as a refresh.
        if params["subagent"] != nil { return ChatMockConversation.owner.transcript(id: id, params: params) }
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
        let environment = ProcessInfo.processInfo.environment
        if environment["HERDR_CHAT_UX_LARGE"] == "1" {
            entries += largeTurns(endingBefore: timestamp)
        }
        let longSession = environment["HERDR_CHAT_UX_LONG_SESSION"] == "1"
        if longSession {
            entries += longSessionTurns(endingBefore: timestamp)
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
        // omp's theme colours (#550): steps with their tool names, headings, and code blocks
        // in known languages and in one the highlighter does not know.
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_COLOURS"] == "1" {
            for (n, step) in [("read", "Reading the sort in AgentList.swift"), ("search", "Searching for scrollPosition"),
                              ("edit", "Anchoring the list on the visible row"), ("bash", "Running the scroll tests")].enumerated() {
                entries.append(["id": "ux-colours-s\(n)", "kind": "step", "tool": step.0, "intent": step.1, "status": "ok",
                                "ts_ms": timestamp + 2])
            }
            entries.append(["id": "ux-colours", "kind": "reply", "final": true, "ts_ms": timestamp + 2, "text": """
                ## Why the list jumps

                The re-sort moves the row under your finger.

                ```swift
                // Keep the visible row anchored
                func resort(_ rows: [Row]) -> [Row] {
                    let name = "herdr", limit = 42
                    return rows.sorted { $0.rank < $1.rank }
                }
                ```

                ### Check it

                ```bash
                # Run the scroll tests
                git status --short | wc -l
                echo "done"
                ```

                ```text
                plain notes stay plain: "quoted" 42
                ```
                """])
        }
        // A diagram reply (#523 item 1), only when a test asks for it: its row grows once the
        // offscreen renderer finishes, which the tail and history-position tests must not see.
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_MERMAID"] == "1" {
            entries.append(["id": "ux-mermaid", "kind": "reply", "final": true,
                            "text": "Here is the flow:\n\n```mermaid\ngraph TD\n  A[Request] --> B{Cached?}\n  B -->|yes| C[Show image]\n  B -->|no| D[Render offscreen]\n  D --> C\n```\n\nThat is the whole pipeline.", "ts_ms": timestamp + 2])
        }
        // The owner's ```svg block (round 4), drawn as an image, then a broken one that must
        // stay code. Only when a test asks: its row grows once the renderer finishes.
        if ProcessInfo.processInfo.environment["HERDR_CHAT_UX_SVG"] == "1" {
            entries.append(["id": "ux-svg", "kind": "reply", "final": true,
                            "text": "The discovery board:\n\n```svg\n\(ownerSVG)\n```\n\nAnd a broken one:\n\n```svg\n<svg viewBox=\"0 0 10 10\"><rect width=\"4\"></svg>\n```",
                            "ts_ms": timestamp + 2])
        }
        // Presentation-only tests hold the transcript; refresh/streaming tests keep updates.
        if responses > 1, !longSession, environment["HERDR_CHAT_UX_STATIC"] != "1" {
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
        result["model"] = ["provider": "fixture", "id": "fixture-model", "thinking_level": "high"]
        result["plan"] = plan(ProcessInfo.processInfo.environment["HERDR_CHAT_UX_PLAN"])
        result["recap"] = ["turn_id": "ux-reply", "text": "Fixture recap only: typography is ready for inspection."]
        return ChatMockConversation.encode(id: id, result: result)
    }

    /// The SVG in the owner's report (round 4): colours from the host page's CSS variables.
    private static let ownerSVG = """
    <svg viewBox="0 0 900 360" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif" font-size="13">
      <rect x="10" y="10" width="880" height="40" rx="6" fill="none" stroke="var(--border)"/>
      <text x="26" y="35" fill="var(--fg)">▶ Play    ❚❚    1×   2×</text>
      <text x="250" y="35" fill="var(--muted)">Business · People · Systems · Data flows · Money · Rules · Pain points</text>
      <rect x="10" y="60" width="540" height="290" rx="6" fill="none" stroke="var(--border)"/>
      <text x="26" y="88" fill="var(--muted)">Consultant</text>
      <text x="26" y="106" fill="var(--fg)">How do insurers pay you: one transfer per claim, or batches?</text>
      <text x="26" y="136" fill="var(--muted)">Finance manager · Up&amp;Running</text>
      <text x="26" y="154" fill="var(--fg)">Batches. Dunebridge sends an Excel advice; Palmline only a PDF by email.</text>
      <text x="26" y="184" fill="var(--muted)">Consultant · follow-up</text>
      <text x="26" y="202" fill="var(--fg)">Does the advice carry your claim number, or theirs?</text>
      <text x="26" y="232" fill="var(--muted)">Finance manager</text>
      <text x="26" y="250" fill="var(--fg)">Ours for Dunebridge. Palmline uses its own reference… </text>
      <rect x="560" y="60" width="330" height="290" rx="6" fill="none" stroke="var(--border)"/>
      <text x="576" y="88" fill="var(--fg)" font-weight="600">What we know so far</text>
      <rect x="576" y="102" width="298" height="50" rx="4" fill="none" stroke="var(--border)"/>
      <text x="588" y="122" fill="var(--fg)">Clinic system (cloud)</text>
      <text x="588" y="140" fill="var(--muted)">Excel export · daily · owner: Ops</text>
      <rect x="576" y="160" width="298" height="50" rx="4" fill="none" stroke="var(--border)"/>
      <text x="588" y="180" fill="var(--fg)">Insurer advices</text>
      <text x="588" y="198" fill="var(--muted)">Excel (2) · PDF by email (1) · new</text>
      <rect x="576" y="218" width="298" height="50" rx="4" fill="none" stroke="var(--border)"/>
      <text x="588" y="238" fill="var(--fg)">Shared IDs</text>
      <text x="588" y="256" fill="var(--muted)">file no. ↔ claim no. ↔ advice ref</text>
      <text x="576" y="296" fill="var(--muted)">Open questions: 3</text>
      <text x="576" y="316" fill="var(--muted)">Problems expected: 4</text>
    </svg>
    """

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

    /// `HERDR_CHAT_UX_LONG_SESSION=1`: a page shaped like the long autonomous session whose
    /// chat lagged in build 221 (`first-page-p9Z.json`: 1709 entries in 20 turns, 922 steps,
    /// 364 thoughts, 252 replies, 109 notes). Twenty turns of thirteen rounds, each a thought
    /// or two, three or four steps and a reply, a note every few rounds, a plan and an
    /// answered question in some turns: about 1,670 entries and 650 chat rows, with the
    /// payload's text lengths (replies ~280 characters with inline markdown, thoughts ~430,
    /// step details ~210, notes ~320).
    private static func longSessionTurns(endingBefore end: UInt64) -> [[String: Any]] {
        let reply = "Checked the **release queue**: `herdr-app` is green on main, and the worker picked up the next job. "
            + "Nothing else is pending, so I will *watch the run* and report when it finishes; the tail of the log "
            + "is quiet and the cache entries are fresh."
        let thought = String(repeating: "The run is still going, so the next step is to read its newest log lines and compare them with the last good build before deciding anything. ", count: 3)
        let detail = "gh run view 40167206376 -R jerryfane/herdrup --log-failed | grep -n 'error' | head -40 && echo checked the native build diagnostics for the simulator job"
        let noteBody = String(repeating: "Message from the fleet: the review of the change is in, read it with gitmoot message show. ", count: 3)
        var entries: [[String: Any]] = []
        var ts = end - 4_000_000
        func add(_ id: String, _ fields: [String: Any]) {
            var entry = fields
            entry["id"] = id
            entry["ts_ms"] = ts
            ts += 1_000
            entries.append(entry)
        }
        for turn in 0..<20 {
            add("long-\(turn)u", ["kind": "user", "author": "owner",
                                  "text": "Long session \(turn): keep the release moving and report back."])
            for round in 0..<13 {
                let id = "long-\(turn)-\(round)"
                for t in 0..<(round % 3 == 0 ? 2 : 1) {
                    add("\(id)t\(t)", ["kind": "thinking", "text": thought])
                }
                for step in 0..<(round % 2 == 0 ? 4 : 3) {
                    add("\(id)s\(step)", ["kind": "step", "tool": "bash", "status": "ok",
                                          "intent": "Reading native build failure diagnostics", "detail": detail])
                }
                add("\(id)r", ["kind": "reply", "final": round == 12, "text": "Round \(round) of turn \(turn). " + reply])
                if round % 5 < 2 {
                    add("\(id)n", ["kind": "note", "source": "gitmoot", "from": "herdr-kimi-review",
                                   "title": "gitmoot reply event for job org-reply:herdr-app \(turn).\(round): new inbox activity",
                                   "body": noteBody])
                }
            }
            if turn % 4 == 0 {
                add("long-\(turn)p", ["kind": "plan", "items": [["text": "Ship the release", "done": false]]])
            }
            if turn % 4 == 1 {
                add("long-\(turn)a", ["kind": "ask", "questions": [[
                    "question": "Merge the release branch?", "options": ["Yes", "Not yet"], "multi": false, "recommended": 0,
                ]], "answer": ["Yes"]])
            }
            add("long-\(turn)e", ["kind": "turn_end", "status": "done"])
        }
        return entries
    }

    /// The to-do fixture: by default two open items; `six` puts the in-progress item in the
    /// middle of six; `done` finishes every item.
    private static func plan(_ variant: String?) -> [[String: Any]] {
        switch variant {
        case "six":
            return [
                ["text": "Plan item one", "done": true, "status": "completed", "phase": "Build"],
                ["text": "Plan item two", "done": true, "status": "completed", "phase": "Build"],
                ["text": "Plan item three", "done": false, "status": "in_progress", "phase": "Build"],
                ["text": "Plan item four", "done": false, "status": "pending", "phase": "Build"],
                ["text": "Plan item five", "done": false, "status": "pending", "phase": "Ship"],
                ["text": "Plan item six", "done": false, "status": "pending", "phase": "Ship"]
            ]
        case "done":
            return [
                ["text": "Plan item one", "done": true, "status": "completed"],
                ["text": "Plan item two", "done": true, "status": "completed"],
                ["text": "Plan item three", "done": true, "status": "completed"]
            ]
        default:
            return [
                ["text": "Review the table", "done": false, "status": "in_progress", "phase": "Verification"],
                ["text": "Ship after review", "done": false, "status": "blocked", "phase": "Verification", "blocker": "Independent review"]
            ]
        }
    }
}
#endif
