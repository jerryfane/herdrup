#if DEBUG
import Foundation
import HerdrKit

/// The needs-you pill's mock daemon (`HERDR_SCREENSHOT_MOCK=needsyou`, herdrup#551): a roster
/// long enough to scroll the waiting rows out of sight, on an iPad's sidebar too.
/// `HERDR_MOCK_WAITING` says how many agents are asking (default 3, may be 0); sixteen
/// working agents follow them. `HERDR_MOCK_WAITING_MANUAL=1` holds the asking agents
/// until the fixture button is tapped after the test establishes its scroll position.
struct NeedsYouMockTransport: HerdrTransport {
    private let base = MockTransport()

    static let waitingNames = ["jarvis", "vetrina", "enyo-review", "phobos", "atlas"]
    static let workingNames = [
        "herdr-app", "trend-scout", "bank-qa", "huurjacht", "aste-screener", "discovery",
        "clientloop", "enyo-efm", "deimos", "fleet-tools", "gram-relay", "omp-docs",
        "mcb-sync", "vesta", "kairos", "ledger",
    ]

    static var waitingCount: Int {
        let raw = ProcessInfo.processInfo.environment["HERDR_MOCK_WAITING"].flatMap(Int.init)
        return min(max(raw ?? 3, 0), waitingNames.count)
    }

    static let manualWaiting = ProcessInfo.processInfo.environment["HERDR_MOCK_WAITING_MANUAL"] == "1"
    private static let waitingGate = WaitingGate()

    // The UI opens the gate; transport requests may read it off the main thread.
    private final class WaitingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false

        var isStarted: Bool { lock.withLock { started } }
        func start() { lock.withLock { started = true } }
    }

    static func startWaiting() { waitingGate.start() }

    static var agentList: String {
        let asking = !manualWaiting || waitingGate.isStarted ? waitingCount : 0
        let waiting = waitingNames.prefix(asking).enumerated().map { index, name in
            #"{"pane_id":"w1:p\#(index + 1)","name":"\#(name)","agent":"claude","agent_status":"blocked","cwd":"/root/\#(name)","terminal_title_stripped":"asking to run tests"}"#
        }
        let working = workingNames.enumerated().map { index, name in
            #"{"pane_id":"w2:p\#(index + 1)","name":"\#(name)","agent":"codex","agent_status":"working","cwd":"/root/\#(name)","terminal_title_stripped":"editing the build"}"#
        }
        let agents = (waiting + working).joined(separator: ",")
        return #"{"id":"mock","result":{"type":"agent_list","agents":[\#(agents)]}}"#
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        if requestLine.contains("agent.list") { return Self.agentList }
        return try await base.roundTrip(requestLine)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
}
#endif
