#if DEBUG
import CryptoKit
import Foundation
import HerdrKit
import SwiftUI
import UIKit

/// Herdrup Desktop's pixel-parity references (`HERDR_SCREENSHOT_MOCK=desktopref`,
/// herdrup-desktop#16): Agents, Gram and Settings over a fixture herdr, held still so
/// every capture of a state is the same picture. `DesktopReferenceShots` drives it.
///
/// - `HERDR_DESKTOPREF_STATE`: `populated` (the default), `empty` (no agents), `loading`
///   (`agent.list` never answers), or one of the served states: `folders`, `avatars`,
///   `sessions`, `federated`, `needs-you`, `gram`, `gram-loading`, `settings`.
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
        case gram, settings
        case gramLoading = "gram-loading"
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
        if state == .gram || state == .gramLoading {
            // Capture the inbox's empty state, not the first-use setup instructions.
            // Like the sidebar resets above, this is prepared once, never in a view init.
            UserDefaults.standard.set(true, forKey: "gram.setupCardDismissed")
        }
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
    private static let gram = GramState()

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
            case .folders, .avatars, .sessions, .federated, .needsYou, .gram, .gramLoading, .settings:
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
        case "machine.status", "server.staged_update", "guest.list", "guest.audit":
            guard let answer = served?.json(method) else { return Self.unknownMethod(id) }
            return Self.result(id, answer)
        case "accounts.list":
            if let answer = served?.json(method) { return Self.result(id, answer) }
            if [.gram, .gramLoading, .settings].contains(DesktopReferenceMock.state) {
                return Self.unknownMethod(id)
            }
            return Self.result(id, #"{"type":"accounts_list","accounts":[]}"#)
        case "gram.list":
            if DesktopReferenceMock.state == .gramLoading {
                while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
                throw CancellationError()
            }
            guard served?.json(method) != nil else {
                if [.gram, .settings].contains(DesktopReferenceMock.state) { return Self.unknownMethod(id) }
                // Original agent-list references predate Gram fixtures.
                return Self.result(id, #"{"type":"gram_list","messages":[],"unread_count":0}"#)
            }
            return try await Self.gram.answer(id: id, method: method, requestLine: requestLine)
        case "gram.mark_read", "gram.get_file", "gram.get_file_chunk", "gram.upload_chunk", "gram.upload.discard":
            return try await Self.gram.answer(id: id, method: method, requestLine: requestLine)
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


    /// Process-local daemon state. Saved messages and search remain the production app's
    /// local operations; only read marks and staged file bytes are server mutations here.
    private actor GramState {
        private var readIDs: Set<String> = []
        private var uploads: [String: Data] = [:]

        func answer(id: String, method: String, requestLine: String) throws -> String {
            let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
            let params = request?["params"] as? [String: Any] ?? [:]
            let fixture = DesktopReferenceMock.served
            func object(_ key: String, _ member: String? = nil) -> [String: Any]? {
                guard let json = fixture?.json(key, member) else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            }
            func reply(_ value: Any) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                return DesktopReferenceMockTransport.result(id, String(decoding: data, as: UTF8.self))
            }
            guard let list = object("gram.list"),
                  let original = list["messages"] as? [[String: Any]] else {
                return DesktopReferenceMockTransport.unknownMethod(id)
            }
            switch method {
            case "gram.list":
                // Capture fixtures serve the owner view, not an invented agent projection.
                if params["caller_pane_id"] is String {
                    return DesktopReferenceMockTransport.error(id, "invalid_params", "owner fixture has no agent view")
                }
                var messages = original.map { message -> [String: Any] in
                    var message = message
                    if let messageID = message["id"] as? String, readIDs.contains(messageID) {
                        message["read_by_owner"] = true
                    }
                    return message
                }
                let unread = messages.filter {
                    $0["direction"] as? String == "agent_to_owner" && $0["read_by_owner"] as? Bool == false
                }.count
                let bytes = try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let before = params["before_id"] as? String
                if before == nil, params["if_unchanged_digest"] as? String == digest {
                    return try reply(["type": "gram_list_unchanged", "digest": digest, "unread_count": unread])
                }
                if params["only_queue"] as? Bool == true {
                    messages = messages.filter {
                        $0["direction"] as? String == "owner_to_agent" && !($0["to"] is String) && !($0["grabbed_by"] is String)
                    }
                }
                if params["unread_only"] as? Bool == true {
                    messages = messages.filter {
                        $0["direction"] as? String == "agent_to_owner" && $0["read_by_owner"] as? Bool == false
                    }
                }
                if let before {
                    guard let index = messages.firstIndex(where: { $0["id"] as? String == before }) else {
                        return DesktopReferenceMockTransport.error(id, "not_found", "unknown Gram cursor")
                    }
                    messages = Array(messages.dropFirst(index + 1))
                }
                let limit = max(1, params["limit"] as? Int ?? messages.count)
                let hasMore = messages.count > limit
                messages = Array(messages.prefix(limit))
                var answer: [String: Any] = [
                    "type": "gram_list", "messages": messages, "digest": digest,
                    "unread_count": unread, "has_more": hasMore,
                ]
                if hasMore { answer["next_before_id"] = messages.last?["id"] }
                return try reply(answer)
            case "gram.mark_read":
                guard let messageID = params["id"] as? String,
                      let message = original.first(where: { $0["id"] as? String == messageID }),
                      message["direction"] as? String == "agent_to_owner" else {
                    return DesktopReferenceMockTransport.error(id, "not_found", "no incoming message with that id")
                }
                readIDs.insert(messageID)
                return try reply(["type": "ok"])
            case "gram.get_file", "gram.get_file_chunk":
                guard let messageID = params["id"] as? String,
                      var file = object("gram.get_file", messageID) else {
                    return DesktopReferenceMockTransport.error(id, "not_found", "no file with that message id")
                }
                if method == "gram.get_file_chunk" {
                    guard let encoded = file["data_base64"] as? String, let bytes = Data(base64Encoded: encoded),
                          let offset = params["offset"] as? Int, offset >= 0, offset <= bytes.count,
                          let length = params["length"] as? Int, length > 0 else {
                        return DesktopReferenceMockTransport.error(id, "invalid_params", "invalid file range")
                    }
                    file["type"] = "gram_file_chunk"
                    file["offset"] = offset
                    file["data_base64"] = bytes.subdata(in: offset..<(offset + min(length, bytes.count - offset))).base64EncodedString()
                }
                return try reply(file)
            case "gram.upload_chunk":
                guard let expected = object("gram.upload.fixture")?["data_base64"] as? String,
                      let expectedBytes = Data(base64Encoded: expected),
                      let uploadID = params["upload_id"] as? String, !uploadID.isEmpty,
                      let offset = params["offset"] as? Int, offset >= 0,
                      let encoded = params["data_base64"] as? String,
                      let chunk = Data(base64Encoded: encoded) else {
                    return DesktopReferenceMockTransport.error(id, "invalid_params", "no matching upload fixture")
                }
                var staged = uploads[uploadID] ?? Data()
                guard offset <= staged.count, offset <= expectedBytes.count,
                      chunk.count <= expectedBytes.count - offset,
                      expectedBytes.subdata(in: offset..<(offset + chunk.count)) == chunk else {
                    return DesktopReferenceMockTransport.error(id, "invalid_params", "upload bytes or offset do not match fixture")
                }
                if offset == staged.count {
                    staged.append(chunk)
                } else if offset + chunk.count > staged.count || staged.subdata(in: offset..<(offset + chunk.count)) != chunk {
                    return DesktopReferenceMockTransport.error(id, "invalid_params", "conflicting upload replay")
                }
                uploads[uploadID] = staged
                return try reply(["type": "ok"])
            case "gram.upload.discard":
                guard let uploadID = params["upload_id"] as? String else {
                    return DesktopReferenceMockTransport.error(id, "invalid_params", "missing upload id")
                }
                return try reply(["type": "gram_upload_discarded", "discarded": uploads.removeValue(forKey: uploadID) != nil])
            default:
                return DesktopReferenceMockTransport.unknownMethod(id)
            }
        }
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
            if let window, [.loading, .gramLoading].contains(DesktopReferenceMock.state) {
                window.layer.speed = 0
            }
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
                "locale=\(Locale.current.identifier)",
                "timeZone=\(TimeZone.current.identifier)",
                "timeZoneOffset=\(TimeZone.current.secondsFromGMT(for: MockClock.pinned ?? Date()))",
                "calendar=\(Calendar.current.identifier)",
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
