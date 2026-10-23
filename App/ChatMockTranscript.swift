#if DEBUG
import Foundation
import HerdrKit
import SwiftUI

/// The `chatview` mock's root: the Agents home over `ChatMockTransport`, with the omp agent
/// `herdr-app` blocked on a question. Each launch starts from the Settings default named by
/// `HERDR_MOCK_CHAT_OPENS_IN` (`chat` unless set), so one test's choice can't leak into the next.
struct ChatViewMockHome: View {
    private static let freshPreference: Void = UserDefaults.standard.set(
        ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_OPENS_IN"] ?? ChatPreference.chat,
        forKey: ChatPreference.key)

    @State private var client: HerdrClient = {
        _ = ChatViewMockHome.freshPreference
        return HerdrClient(transport: ChatMockTransport())
    }()

    var body: some View {
        TerminalHomeView(client: client, onDisconnect: {}, onTrustHostKey: { _ in false },
                         livePaneIDs: [ChatMockTransport.paneID, "w9:p2", "w9:p3"])
    }
}

/// The `chatview` screenshot mock and UI-test host: a synthetic omp conversation served as
/// `agent.transcript` pages, the way herdr pages a session file (turns, newest page first,
/// `before` cursors, a pending question). Every word is made up for the mock.
///
/// One conversation per process for the owner (agent `herdr-app`) and one for the guest
/// (agent `llm-opt`, as a guest sees it: no notes, no step details, questions not
/// answerable). The owner's can be answered through `agent.answer`.
final class ChatMockConversation: @unchecked Sendable {
    enum Audience { case owner, guest }

    static let owner = ChatMockConversation(audience: .owner)
    static let guest = ChatMockConversation(audience: .guest)

    /// `HERDR_MOCK_CHAT_ANSWER=<code>`: `agent.answer` refuses with that error code (the
    /// "Answer in Terminal" fallback); unset, it answers.
    static let answerRefusal = ProcessInfo.processInfo.environment["HERDR_MOCK_CHAT_ANSWER"]

    let audience: Audience
    private let lock = NSLock()
    private var answered: String?

    private init(audience: Audience) {
        self.audience = audience
    }

    var askID: String { audience == .owner ? "call_ask_merge" : "call_ask_bench" }
    var question: String {
        audience == .owner ? "Merge #305 and update the servers?" : "Post these to the team bench sheet?"
    }
    var options: [String] {
        audience == .owner ? ["Yes, merge and deploy", "Not yet"] : ["Yes, post them", "No, keep them here"]
    }

    var isAnswered: Bool { lock.withLock { answered != nil } }

    // MARK: Requests

    /// `agent.transcript`: the newest page, an older page (`before`), or a live refresh
    /// (`after`, answered with the newest window: the client merges by id).
    func transcript(id: String, params: [String: Any]) -> String {
        let limit = max(1, min(params["limit"] as? Int ?? 20, 50))
        let turns = lock.withLock { buildTurns() }
        let end: Int
        if let before = params["before"] as? String {
            guard before.hasPrefix("t"), let index = Int(before.dropFirst()), index <= turns.count else {
                return Self.error(id: id, code: "cursor_expired", message: "unknown cursor")
            }
            end = index
        } else {
            end = turns.count
        }
        let start = max(0, end - limit)
        let entries = turns[start..<end].flatMap { $0 }
        var result: [String: Any] = [
            "type": "agent_transcript",
            "agent": audience == .owner ? "herdr-app" : "llm-opt",
            "pane_id": audience == .owner ? ChatMockTransport.paneID : GuestMockTransport.access.agentTarget,
            "session_id": "mock-session",
            "entries": entries,
            "before": start > 0 ? "t\(start)" : NSNull(),
            "after": "a\(turns.count)",
            "working": NSNull(),
            "pending_ask": NSNull(),
        ]
        if lock.withLock({ answered != nil }) {
            result["working"] = ["intent": "Merging #305", "tool": "bash",
                                 "since_ms": Self.today(16, 52)]
        } else {
            result["pending_ask"] = [
                "id": askID,
                "questions": [["question": question, "options": options, "multi": false, "recommended": 0]],
                "answerable": audience == .owner,
            ]
        }
        return Self.encode(id: id, result: result)
    }

    /// `agent.answer` (owner only): records the choice; the next page shows it answered.
    func answer(id: String, params: [String: Any]) -> String {
        let option = params["option"] as? String ?? ""
        let ask = params["ask_id"] as? String ?? ""
        return lock.withLock {
            if let refusal = Self.answerRefusal {
                return Self.error(id: id, code: refusal, message: "mock refusal")
            }
            guard ask == askID, answered == nil else {
                return Self.error(id: id, code: "ask_not_pending", message: "no pending question with that id")
            }
            guard options.contains(option) else {
                return Self.error(id: id, code: "selection_mismatch", message: "not one of the options")
            }
            answered = option
            return Self.encode(id: id, result: ["type": "agent_answer", "status": "answered"])
        }
    }

    // MARK: The conversation

    /// Older filler turns first (so there is history to page in), then the mockup's turns.
    private func buildTurns() -> [[[String: Any]]] {
        let fillerCount = 40
        var turns: [[[String: Any]]] = (0..<fillerCount).map { index in
            let at = Self.daysAgo(fillerCount - index + 1, hour: 11, minute: 15)
            let n = index + 1
            return [
                Self.entry("f\(n)u", at, ["kind": "user", "text": "Synthetic question \(n): is check \(n) green?",
                                         "author": "owner"]),
                Self.entry("f\(n)s", at + 20_000, ["kind": "step", "tool": "bash", "intent": "Running check \(n)",
                                                   "status": "ok"]),
                Self.entry("f\(n)r", at + 60_000, ["kind": "reply", "text": "Check \(n) is green.", "final": true]),
                Self.entry("f\(n)e", at + 61_000, ["kind": "turn_end", "status": "done"]),
            ]
        }
        turns += audience == .owner ? ownerTurns() : guestTurns()
        return turns
    }

    private static let ownerStepIntents = [
        "Reading the scroll code in the terminal view", "Searching for the history cursor",
        "Reading the pane.history handler", "Writing the paging loop", "Running the unit tests",
        "Building the app for the simulator", "Running the scroll UI test", "Checking the gaps between pages",
    ]

    private func ownerTurns() -> [[[String: Any]]] {
        let ci = Self.today(14, 5)
        var first: [[String: Any]] = [
            Self.entry("o1u", ci, ["kind": "user", "text": "Is the herdr fork's CI running again?", "author": "owner"]),
            Self.entry("o1t", ci + 4_000, ["kind": "thinking",
                                           "text": "Check the Actions banner and the newest run, not the old queued one."]),
        ]
        for step in 0..<6 {
            first.append(Self.entry("o1s\(step)", ci + 10_000 + UInt64(step) * 20_000, [
                "kind": "step", "tool": "bash", "intent": ["Opening the fork's Actions page", "Reading the newest run",
                                                          "Checking each platform's job", "Finding the run from Oct 8",
                                                          "Cancelling the stuck run", "Confirming the queue is empty"][step],
                "status": "ok", "detail": "gh run list --limit 5",
            ]))
        }
        first.append(Self.entry("o1r", ci + 125_000, [
            "kind": "reply", "final": true,
            "text": "Yes. The first run since Oct 8 passed on **macOS, Windows, Linux and Nix**. I cancelled the stuck run from Oct 8, so nothing is queued now.",
        ]))
        first.append(Self.entry("o1e", ci + 126_000, ["kind": "turn_end", "status": "done"]))

        let scroll = Self.today(16, 12)
        var second: [[String: Any]] = [
            Self.entry("o2u", scroll, ["kind": "user", "author": "owner",
                                       "text": "Scrolling up in a terminal stops too early. Keep loading, like Gram."]),
            Self.entry("o2t", scroll + 5_000, ["kind": "thinking",
                                               "text": "The phone only gets the last 1,000 rows; the server keeps far more, so the app has to page. Each page should follow its row while the pane keeps writing."]),
        ]
        // 112 steps over 38 minutes.
        for step in 0..<112 {
            var entry: [String: Any] = ["kind": "step", "tool": "bash", "status": "ok",
                                        "intent": Self.ownerStepIntents[step % Self.ownerStepIntents.count]]
            if audience == .owner { entry["detail"] = "step \(step + 1) of the synthetic run" }
            second.append(Self.entry("o2s\(step)", scroll + 10_000 + UInt64(step) * 20_250, entry))
        }
        let noteAt = scroll + 2_290_000
        second.append(Self.entry("o2n", noteAt, [
            "kind": "note", "source": "gitmoot", "title": "Review approved · herdr #305", "from": "herdr-kimi-review",
            "body": "Approved. The cursor follows its row and the pages meet without gaps.",
        ]))
        second.append(Self.entry("o2p", noteAt + 1_000, ["kind": "plan", "items": [
            ["text": "Page history on the server", "done": true],
            ["text": "Load it in the app as you scroll", "done": true],
            ["text": "Test it end to end", "done": true],
            ["text": "Merge and deploy", "done": false],
        ]]))
        second.append(Self.entry("o2r", noteAt + 2_000, [
            "kind": "reply", "final": false,
            "text": "Done. Scrolling up now keeps loading older output, **500 lines at a time**, back to the very start.\n\n- Tested on a real server: 3,661 older lines, no gaps, with live output arriving between pages.\n- The app part is in `#477`; the server part is `#305`.",
        ]))
        var ask: [String: Any] = ["kind": "ask", "questions": [[
            "question": question, "options": options, "multi": false, "recommended": 0,
        ]]]
        let answer = answered
        if let answer { ask["answer"] = [answer] }
        second.append(Self.entry(askID, noteAt + 3_000, ask))
        if answer != nil {
            second.append(Self.entry("o2after", noteAt + 9_000, [
                "kind": "reply", "final": false, "text": "Merging #305 and updating the servers.",
            ]))
            second.append(Self.entry("o2merge", noteAt + 10_000, [
                "kind": "step", "tool": "bash", "intent": "Merging #305", "status": "running",
            ]))
        }
        return [first, second]
    }

    private func guestTurns() -> [[[String: Any]]] {
        let q4 = Self.daysAgo(1, hour: 18, minute: 40)
        var first: [[String: Any]] = [
            Self.entry("g1u", q4, ["kind": "user", "author": "guest", "author_name": "plotarmordev",
                                   "text": "What changed between the Q4 and Q5 builds?"]),
        ]
        for step in 0..<4 {
            first.append(Self.entry("g1s\(step)", q4 + 5_000 + UInt64(step) * 15_000, [
                "kind": "step", "tool": "read", "intent": "Reading the Q5 changelog", "status": "ok",
            ]))
        }
        first.append(Self.entry("g1r", q4 + 70_000, [
            "kind": "reply", "final": true,
            "text": "Q5 switches the attention kernel to the fused path and drops the extra KV copy. Decode should be faster; prefill about the same.",
        ]))
        first.append(Self.entry("g1e", q4 + 71_000, ["kind": "turn_end", "status": "done"]))

        let bench = Self.today(10, 2)
        var second: [[String: Any]] = [
            Self.entry("g2u", bench, ["kind": "user", "author": "guest", "author_name": "plotarmordev",
                                      "text": "Can you rerun the TensorFold bench against our Q5 build and send me the table?"]),
            Self.entry("g2t", bench + 3_000, ["kind": "thinking",
                                              "text": "Q5 needs the warm-up pass first, or decode looks slower than it is."]),
        ]
        for step in 0..<14 {
            second.append(Self.entry("g2s\(step)", bench + 6_000 + UInt64(step) * 25_000, [
                "kind": "step", "tool": "bash", "intent": "Running the TensorFold bench", "status": "ok",
            ]))
        }
        second.append(Self.entry("g2r", bench + 362_000, [
            "kind": "reply", "final": false,
            "text": "Here are the Q5 numbers against the last baseline:\n\n| Metric | Q5 | Change |\n|---|---|---|\n| Decode | 41.2 tok/s | +36% |\n| Prefill | 1,180 tok/s | +4% |\n\nFull results are in `results/tensorfold-q5.md`.",
        ]))
        second.append(Self.entry(askID, bench + 363_000, ["kind": "ask", "questions": [[
            "question": question, "options": options, "multi": false, "recommended": 0,
        ]]]))
        return [first, second]
    }

    // MARK: Helpers

    private static func entry(_ id: String, _ ms: UInt64, _ fields: [String: Any]) -> [String: Any] {
        var entry = fields
        entry["id"] = id
        entry["ts_ms"] = ms
        return entry
    }

    private static func today(_ hour: Int, _ minute: Int) -> UInt64 {
        ms(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
    }

    private static func daysAgo(_ days: Int, hour: Int, minute: Int) -> UInt64 {
        let day = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return ms(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day)
    }

    private static func ms(_ date: Date) -> UInt64 { UInt64(max(date.timeIntervalSince1970, 0) * 1000) }

    static func encode(id: String, result: [String: Any]) -> String {
        let object: [String: Any] = ["id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func error(id: String, code: String, message: String) -> String {
        encode(id: id, result: [:]).replacingOccurrences(
            of: #""result":{}"#, with: #""error":{"code":"\#(code)","message":"\#(message)"}"#)
    }

    static func requestObject(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }
}

/// The owner side of the `chatview` mock: the Agents home with an omp agent (`herdr-app`)
/// waiting on a question, on a server that advertises `agent_transcript` and `agent_answer`.
/// Everything else falls through to `MockTransport`.
struct ChatMockTransport: HerdrTransport {
    static let paneID = "w9:p1"
    private let base = MockTransport()

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = ChatMockConversation.requestObject(requestLine)
        let id = request["id"] as? String ?? "mock"
        let params = request["params"] as? [String: Any] ?? [:]
        switch request["method"] as? String {
        case "ping":
            return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.4","protocol":22,"capabilities":{"agent_transcript":true,"agent_answer":true}}}"#
        case "agent.list":
            return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[\#(Self.agentsJSON)]}}"#
        case "agent.transcript":
            let target = params["target"] as? String
            guard target == Self.paneID || target == "herdr-app" else {
                return ChatMockConversation.error(id: id, code: "transcript_unsupported", message: "not an omp agent")
            }
            return ChatMockConversation.owner.transcript(id: id, params: params)
        case "agent.answer":
            return ChatMockConversation.owner.answer(id: id, params: params)
        case "agent.prompt":
            return #"{"id":"\#(id)","result":{"type":"agent_prompted","delivery":"submitted"}}"#
        default:
            return try await base.roundTrip(requestLine)
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        base.stream(requestLine)
    }

    /// `HERDR_MOCK_STILL=1`: no agent reads working. A working row's spinner animates
    /// forever, which keeps XCUITest from ever seeing the app idle.
    private static let still = ProcessInfo.processInfo.environment["HERDR_MOCK_STILL"] == "1"

    /// herdr-app (omp, waiting on the question; working once answered), a Claude agent and a
    /// second omp agent, as in the iPad mockup's sidebar.
    private static var agentsJSON: String {
        let working = still ? "idle" : "working"
        let status = ChatMockConversation.owner.isAnswered ? working : "blocked"
        return [
            #"{"pane_id":"\#(paneID)","name":"herdr-app","agent":"omp","agent_status":"\#(status)","cwd":"/root/herdr","terminal_title_stripped":"Merge #305 and update the servers?"}"#,
            #"{"pane_id":"w9:p2","name":"keephair","agent":"claude","agent_status":"\#(working)","cwd":"/root/keephair-repo","terminal_title_stripped":"Running the iPad tests"}"#,
            #"{"pane_id":"w9:p3","name":"llm-opt","agent":"omp","agent_status":"done","cwd":"/root/llm-opt","terminal_title_stripped":"Bench results posted"}"#,
        ].joined(separator: ",")
    }
}
#endif
