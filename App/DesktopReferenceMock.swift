#if DEBUG
import Foundation
import HerdrKit
import SwiftUI
import UIKit

/// Herdrup Desktop's pixel-parity references (`HERDR_SCREENSHOT_MOCK=desktopref`,
/// herdrup-desktop#16): the Agents home over a fake herdr, held still so every capture of
/// a state is the same picture. `DesktopReferenceShots` drives it;
/// design/reference/agent-list/README.md says how the pictures are made.
///
/// - `HERDR_DESKTOPREF_STATE`: `populated` (the default), `empty` (no agents), `loading`
///   (`agent.list` never answers), or one of the served states: `folders`, `avatars`,
///   `sessions`, `federated`, `needs-you`.
/// - `HERDR_DESKTOPREF_AGENT_LIST`: the `agent.list` result of `populated`, served verbatim.
///   The UI test reads it from its vendored copy of herdrup-desktop's cmd/fakeherdr/agents.json.
/// - `HERDR_DESKTOPREF_SERVED`: everything a served state answers, one JSON object keyed by
///   what it answers (`DesktopReferenceMock.Served`). The UI test reads it from
///   HerdrUITests/Fixtures/desktop-reference-<state>.json, the same file Herdrup Desktop's
///   fake herdr serves.
/// - `HERDR_MOCK_NOW`: the pinned clock (`MockClock`).
///
/// Held still means: no UIKit or SwiftUI animation, the working ring at rest, the empty
/// detail column's glyph field drawn once from a fixed seed, and, while loading, the
/// window's layers frozen so the spinner holds its first frame.
enum DesktopReferenceMock {
    enum State: String {
        case populated, empty, loading
        case folders, avatars, sessions, federated
        case needsYou = "needs-you"
    }

    static let holdsStill = ScreenshotMock.mode == .desktopReference

    static let state = State(
        rawValue: ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_STATE"] ?? ""
    ) ?? .populated

    /// The glyph field's seed (SplitMix64, `FieldDice` in SelectAgentField.swift).
    static let glyphFieldSeed: UInt64? = holdsStill ? 0x4845_5244_5255_5031 : nil

    /// Runs once, on the main actor, before the home is built. Every launch starts as on a
    /// device that never minimised the sidebar or opened a folder (the `needs-you-rail` shot
    /// minimises it, the `folders` shot opens one). The mock home has no host key, so its open
    /// folders are kept under the empty one.
    @MainActor static let prepared: Void = {
        UIView.setAnimationsEnabled(false)
        UserDefaults.standard.removeObject(forKey: TerminalHomeView.sidebarMinimizedKey)
        UserDefaults.standard.removeObject(forKey: AgentGroupsStore.openFoldersKey(host: ""))
    }()

    /// The served `agent.list` result, verbatim, or nil when the test passed none.
    static let agentList: String? = ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_AGENT_LIST"]

    /// A served state's answers (`HERDR_DESKTOPREF_SERVED`). Keys:
    /// - `ping`, `agent.list`, `agent.groups.get`: each method's `result`.
    /// - `agent.avatar.get`: the `result` for each picture, by its sha256.
    /// - `herdr session list --json`: that command's output, the machine's herdr sessions.
    /// - `agent.list in session`: the `agent.list` result of each other running session, by name.
    /// A key the state does not have is a method this herdr refuses as unknown. Immutable
    /// once parsed, so safe to share across the transport's tasks.
    struct Served: @unchecked Sendable {
        private let object: [String: Any]

        init?(_ text: String?) {
            guard let text,
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { return nil }
            self.object = object
        }

        /// The value at `key` (then `member`, for keyed answers) as JSON, or nil.
        func json(_ key: String, _ member: String? = nil) -> String? {
            var value = object[key]
            if let member { value = (value as? [String: Any])?[member] }
            guard let value, !(value is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let served = Served(ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_SERVED"])
}

/// The daemon behind `desktopref`. For `populated`, `empty` and `loading`, its ping
/// advertises what a current herdr fork does, except `agent_groups`, so the roster shows no
/// folders and stars. A served state answers from its fixture instead. Everything the home
/// asks for on launch is answered; anything else is refused like an unknown method.
///
/// A machine with herdr sessions, too: `herdr session list --json` and other sessions'
/// `agent.list` come from the served state's fixture, and a state without them lists no
/// sessions, like a herdr without named sessions.
struct DesktopReferenceMockTransport: SessionListingTransport {
    static let capabilities = #"{"live_handoff":true,"pane_input_stream":true,"gram_upload_stream":true,"agent_session_transfer":true,"agent_session_transfer_harnesses":["claude","codex","omp"],"events_v2":true,"agent_forget":true,"api_bridge_multi":true,"pane_history":true,"agent_transcript":true,"agent_answer":true,"agent_avatar":true}"#

    private var served: DesktopReferenceMock.Served? { DesktopReferenceMock.served }

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        let method = request["method"] as? String ?? ""
        switch method {
        case "ping":
            let pong = served?.json("ping")
                ?? #"{"type":"pong","version":"0.9.5","protocol":22,"capabilities":\#(Self.capabilities)}"#
            return Self.result(id, pong)
        case "agent.list":
            switch DesktopReferenceMock.state {
            case .loading:
                // Never answers; the home keeps its spinner until the test is done.
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
                throw CancellationError()
            case .empty:
                return Self.result(id, #"{"type":"agent_list","agents":[]}"#)
            case .populated:
                guard let list = DesktopReferenceMock.agentList else {
                    return Self.error(id, "no_fixture", "HERDR_DESKTOPREF_AGENT_LIST is not set")
                }
                return Self.result(id, list)
            case .folders, .avatars, .sessions, .federated, .needsYou:
                guard let list = served?.json("agent.list") else {
                    return Self.error(id, "no_fixture", "HERDR_DESKTOPREF_SERVED has no agent.list")
                }
                return Self.result(id, list)
            }
        case "agent.groups.get":
            guard let groups = served?.json("agent.groups.get") else { return Self.unknownMethod(id) }
            return Self.result(id, groups)
        case "agent.avatar.get":
            guard let images = served, images.json("agent.avatar.get") != nil else { return Self.unknownMethod(id) }
            let sha256 = ((request["params"] as? [String: Any])?["sha256"] as? String ?? "").lowercased()
            guard let image = images.json("agent.avatar.get", sha256) else {
                return Self.error(id, "avatar_not_found", "no such avatar image")
            }
            return Self.result(id, image)
        case "accounts.list":
            return Self.result(id, #"{"type":"accounts_list","accounts":[]}"#)
        case "gram.list":
            return Self.result(id, #"{"type":"gram_list","messages":[],"unread_count":0}"#)
        default:
            return Self.unknownMethod(id)
        }
    }

    func listSessions() async throws -> [HerdrSession] {
        guard let output = served?.json("herdr session list --json") else { throw Unserved() }
        return try HerdrSession.decodeList(Data(output.utf8))
    }

    /// Another session's `agent.list`, for its pill's needs-you count. The home's own
    /// session (the default) is this daemon.
    func roundTrip(_ requestLine: String, inSession session: String?) async throws -> String {
        guard let session, session != "default" else { return try await roundTrip(requestLine) }
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        guard request["method"] as? String == "agent.list",
              let list = served?.json("agent.list in session", session) else { return Self.unknownMethod(id) }
        return Self.result(id, list)
    }

    /// The all-panes status subscription: acknowledged, then a heartbeat every 15 s like
    /// the daemon, and never an event, so the roster stays as `agent.list` drew it.
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard requestLine.contains(#""method":"events.subscribe""#) else {
                continuation.finish(throwing: Unserved())
                return
            }
            continuation.yield(#"{"id":"herdrkit:events.subscribe:agent-status","result":{"type":"subscription_started"}}"#)
            let heartbeat = Task {
                var seq = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    seq += 1
                    continuation.yield(#"{"control":"heartbeat","seq":\#(seq)}"#)
                }
            }
            continuation.onTermination = { _ in heartbeat.cancel() }
        }
    }

    private static func result(_ id: String, _ result: String) -> String {
        #"{"id":"\#(id)","result":\#(result)}"#
    }

    private static func error(_ id: String, _ code: String, _ message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private static func unknownMethod(_ id: String) -> String {
        error(id, "unknown_method", "not served by the desktopref mock")
    }

    /// A stream, or a session listing, this daemon does not serve.
    private struct Unserved: Error {}
}

/// A 1×1 point, invisible, that reports what the references were taken under: window size,
/// scale, status-bar height, safe area, Dynamic Type size, appearance and the pinned clock,
/// as its accessibility value. While loading it also freezes the window's layers, so the
/// spinner holds its first frame.
struct DesktopReferenceProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "desktopref-probe"
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, DesktopReferenceMock.state == .loading { window.layer.speed = 0 }
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let window else { return }
            let statusBar = window.windowScene?.statusBarManager?.statusBarFrame.height ?? -1
            let traits = window.traitCollection
            let fields = [
                "window=\(Self.points(window.bounds.width))x\(Self.points(window.bounds.height))",
                "scale=\(Self.points(traits.displayScale))",
                "statusBar=\(Self.points(statusBar))",
                "safeTop=\(Self.points(window.safeAreaInsets.top))",
                "contentSize=\(traits.preferredContentSizeCategory.rawValue)",
                "style=\(traits.userInterfaceStyle == .dark ? "dark" : "light")",
                "now=\(MockClock.pinned.map { ISO8601DateFormatter().string(from: $0) } ?? "unpinned")",
            ]
            accessibilityValue = fields.joined(separator: ";")
        }

        private static func points(_ value: CGFloat) -> String {
            value.rounded() == value ? String(Int(value)) : String(Double(value))
        }
    }
}

/// A screenshot mock's pinned "now": `HERDR_MOCK_NOW` as ISO 8601 (e.g.
/// `2026-10-28T09:41:00Z`). nil when unset, and then every clock reads the real time.
enum MockClock {
    static let pinned: Date? = ProcessInfo.processInfo.environment["HERDR_MOCK_NOW"]
        .flatMap { ISO8601DateFormatter().date(from: $0) }
}
#endif
