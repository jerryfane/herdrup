#if DEBUG
import SwiftUI
import HerdrKit

/// A stand-in daemon for the home list's live status stream receipt
/// (`HERDR_SCREENSHOT_MOCK=liveevents` / `liveevents-legacy`).
///
/// It keeps its own roster, so `agent.list` always answers the current truth, and
/// counts every `agent.list` and `events.subscribe` it serves. The UI test reads
/// those counts off the harness overlay: a row that changes while the list count
/// stands still changed from a streamed event, and a count that climbs every 5 s
/// is the old poll.
@MainActor
final class LiveEventsDriver: ObservableObject {
    static let shared = LiveEventsDriver(eventsV2: ScreenshotMock.mode != .liveEventsLegacy)

    /// Whether this daemon advertises `events_v2` (in `ping` and `agent.list`).
    let eventsV2: Bool
    @Published private(set) var agentListCalls = 0
    @Published private(set) var subscriptions = 0

    private var statuses: [String: String] = [
        "w1:p1": "working",
        "build/w1:p2": "working",
        "w1:p3": "idle",
    ]
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var streamGeneration = 0
    private var heartbeat: Task<Void, Never>?
    private var seq: UInt64 = 100

    init(eventsV2: Bool) {
        self.eventsV2 = eventsV2
    }

    /// Answers `ping` and `agent.list`; nil lets MockTransport's canned answers serve
    /// everything else.
    func answer(_ requestLine: String) -> String? {
        if requestLine.contains(#""method":"ping""#) {
            let capabilities = eventsV2 ? #"{"live_handoff":true,"events_v2":true}"# : #"{"live_handoff":true}"#
            return #"{"id":"mock","result":{"type":"pong","version":"0.9.0","protocol":16,"capabilities":\#(capabilities)}}"#
        }
        if requestLine.contains(#""method":"agent.list""#) {
            agentListCalls += 1
            return agentList()
        }
        return nil
    }

    /// The all-panes subscription. Acknowledges, then stays open (a live stream
    /// never ends by itself) with a heartbeat every 15 s like the daemon.
    nonisolated func stream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in self.attach(continuation) }
        }
    }

    /// The federated row turns blocked, and the stream says so.
    func emitRemoteBlocked() {
        statuses["build/w1:p2"] = "blocked"
        seq += 1
        continuation?.yield(#"{"seq":\#(seq),"event":"pane.agent_status_changed","data":{"pane_id":"build/w1:p2","workspace_id":"build/w1","agent_status":"blocked","input_pending":true,"input_prompt_kind":"confirm","agent":"codex","turn":2,"turn_epoch":1}}"#)
    }

    /// A local row turns blocked while the stream is behind: its event is among the
    /// ones the daemon dropped, so only the `lagged` reload can show it.
    func emitLagged() {
        statuses["w1:p1"] = "blocked"
        let first = seq + 1
        seq += 50
        continuation?.yield(#"{"control":"lagged","seq":\#(seq),"first_missed_seq":\#(first),"last_missed_seq":\#(seq)}"#)
    }

    /// The SSH channel drops.
    func dropStream() {
        heartbeat?.cancel()
        continuation?.finish()
        continuation = nil
    }

    private func attach(_ next: AsyncThrowingStream<String, Error>.Continuation) {
        subscriptions += 1
        streamGeneration += 1
        let generation = streamGeneration
        continuation?.finish()
        continuation = next
        next.onTermination = { _ in
            Task { @MainActor in self.detach(generation) }
        }
        next.yield(#"{"id":"herdrkit:events.subscribe:agent-status","result":{"type":"subscription_started"}}"#)
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                self.continuation?.yield(#"{"control":"heartbeat","seq":\#(self.seq)}"#)
            }
        }
    }

    private func detach(_ generation: Int) {
        guard generation == streamGeneration else { return }
        heartbeat?.cancel()
        continuation = nil
    }

    private func agentList() -> String {
        func status(_ pane: String) -> String { statuses[pane] ?? "idle" }
        let origin = eventsV2 ? #","origin_capabilities":{"live_handoff":true,"events_v2":true}"# : ""
        return #"""
        {"id":"mock","result":{"type":"agent_list","agents":[
          {"pane_id":"w1:p1","name":"lead","agent":"claude","agent_status":"\#(status("w1:p1"))","cwd":"/root/herdr","terminal_title_stripped":"wiring the relay"},
          {"pane_id":"build/w1:p2","name":"build/relay-check","agent":"codex","agent_status":"\#(status("build/w1:p2"))","machine_id":"build","machine_label":"build","reachability":"reachable","cwd":"/srv/relay","terminal_title_stripped":"cargo nextest"},
          {"pane_id":"w1:p3","name":"quiet","agent":"claude","agent_status":"\#(status("w1:p3"))","cwd":"/root/notes","terminal_title_stripped":"standing by"}
        ]\#(origin)}}
        """#
    }
}

/// The home list over `LiveEventsDriver`, with the controls and counters the
/// UI test drives. Nothing here animates, so XCUITest reaches idle.
struct LiveEventsHarness: View {
    @ObservedObject var driver: LiveEventsDriver
    @State private var client: HerdrClient

    init(driver: LiveEventsDriver) {
        self.driver = driver
        _client = State(initialValue: HerdrClient(transport: MockTransport(liveEventsDriver: driver)))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TerminalHomeView(client: client, onDisconnect: {}, onTrustHostKey: { _ in false })
            VStack(alignment: .leading, spacing: 6) {
                Text("list=\(driver.agentListCalls) subscribe=\(driver.subscriptions)")
                    .accessibilityIdentifier("live-events-counters")
                HStack(spacing: 6) {
                    control("status", id: "live-emit-status", action: driver.emitRemoteBlocked)
                    control("lagged", id: "live-emit-lagged", action: driver.emitLagged)
                    control("drop", id: "live-drop-stream", action: driver.dropStream)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 12)
            .padding(.bottom, 96)
        }
    }

    private func control(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier(id)
    }
}
#endif
