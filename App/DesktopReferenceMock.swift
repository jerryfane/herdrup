#if DEBUG
import Foundation
import HerdrKit
import SwiftUI
import UIKit

/// Herdrup Desktop's pixel-parity references (`HERDR_SCREENSHOT_MOCK=desktopref`,
/// herdrup-desktop#16): the Agents home over the desktop's fake herdr `agent.list`, held
/// still so every capture of a state is the same picture. `DesktopReferenceShots` drives
/// it; design/reference/agent-list/README.md says how the pictures are made.
///
/// - `HERDR_DESKTOPREF_AGENT_LIST`: the `agent.list` result to serve verbatim. The UI test
///   reads it from its vendored copy of herdrup-desktop's cmd/fakeherdr/agents.json.
/// - `HERDR_DESKTOPREF_STATE`: `populated` (the default), `empty` (no agents) or `loading`
///   (`agent.list` never answers).
/// - `HERDR_MOCK_NOW`: the pinned clock (`MockClock`).
///
/// Held still means: no UIKit or SwiftUI animation, the working ring at rest, the empty
/// detail column's glyph field drawn once from a fixed seed, and, while loading, the
/// window's layers frozen so the spinner holds its first frame.
enum DesktopReferenceMock {
    enum State: String {
        case populated, empty, loading
    }

    static let holdsStill = ScreenshotMock.mode == .desktopReference

    static let state = State(
        rawValue: ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_STATE"] ?? ""
    ) ?? .populated

    /// The glyph field's seed (SplitMix64, `FieldDice` in SelectAgentField.swift).
    static let glyphFieldSeed: UInt64? = holdsStill ? 0x4845_5244_5255_5031 : nil

    /// Runs once, on the main actor, before the home is built.
    @MainActor static let prepared: Void = {
        UIView.setAnimationsEnabled(false)
    }()

    /// The served `agent.list` result, verbatim, or nil when the test passed none.
    static let agentList: String? = ProcessInfo.processInfo.environment["HERDR_DESKTOPREF_AGENT_LIST"]
}

/// The daemon behind `desktopref`. Its ping advertises what a current herdr fork does,
/// except `agent_groups`, so the roster shows no folders and stars. Everything the home
/// asks for on launch is answered; anything else is refused like an unknown method.
struct DesktopReferenceMockTransport: HerdrTransport {
    static let capabilities = #"{"live_handoff":true,"pane_input_stream":true,"gram_upload_stream":true,"agent_session_transfer":true,"agent_session_transfer_harnesses":["claude","codex","omp"],"events_v2":true,"agent_forget":true,"api_bridge_multi":true,"pane_history":true,"agent_transcript":true,"agent_answer":true,"agent_avatar":true}"#

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        switch request["method"] as? String {
        case "ping":
            return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.5","protocol":22,"capabilities":\#(Self.capabilities)}}"#
        case "agent.list":
            switch DesktopReferenceMock.state {
            case .loading:
                // Never answers; the home keeps its spinner until the test is done.
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
                throw CancellationError()
            case .empty:
                return #"{"id":"\#(id)","result":{"type":"agent_list","agents":[]}}"#
            case .populated:
                guard let list = DesktopReferenceMock.agentList else {
                    return #"{"id":"\#(id)","error":{"code":"no_fixture","message":"HERDR_DESKTOPREF_AGENT_LIST is not set"}}"#
                }
                return #"{"id":"\#(id)","result":\#(list)}"#
            }
        case "accounts.list":
            return #"{"id":"\#(id)","result":{"type":"accounts_list","accounts":[]}}"#
        case "gram.list":
            return #"{"id":"\#(id)","result":{"type":"gram_list","messages":[],"unread_count":0}}"#
        default:
            return #"{"id":"\#(id)","error":{"code":"unknown_method","message":"not served by the desktopref mock"}}"#
        }
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

    /// A stream this daemon does not serve.
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
