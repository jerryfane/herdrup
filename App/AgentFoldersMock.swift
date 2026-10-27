#if DEBUG
import Foundation
import HerdrKit

/// The folders mock daemon (`HERDR_SCREENSHOT_MOCK=folders`, herdrup#552): it advertises
/// `agent_groups` and keeps the owner's folders and stars in memory for the launch, the way the
/// herdr server answers `agent.groups.get` and `agent.groups.set`. `HERDR_MOCK_GROUPS=off` is
/// an older server: no capability, and `agent.groups.*` is an unknown method.
///
/// The roster is long enough to scroll the waiting rows away (the needs-you pill), with two
/// folders that each hold someone waiting:
/// - Enyo: enyo-review (waiting), enyo-efm (stopped), enyo (working), enyo-scout (idle)
/// - Herdr: herdr-ios (waiting), herdr-app (working)
/// and vetrina starred.
struct AgentFoldersMockTransport: HerdrTransport {
    private let base = MockTransport()

    static var advertisesGroups: Bool {
        ProcessInfo.processInfo.environment["HERDR_MOCK_GROUPS"] != "off"
    }

    static let idleStatus = ProcessInfo.processInfo.environment["HERDR_PROBE_NO_IDLE"] == "1" ? "working" : "idle"

    /// (pane id, name, status); a status of "stopped" is a pane that is gone.
    static let roster: [(String, String, String)] = [
        ("w1:p1", "jarvis", "blocked"),
        ("w1:p2", "vetrina", "blocked"),
        ("w1:p3", "enyo-review", "blocked"),
        ("w1:p4", "herdr-ios", "blocked"),
        ("w3:p1", "enyo-efm", "stopped"),
        ("w2:p1", "bank-qa", "working"),
        ("w2:p2", "huurjacht", "working"),
        ("w2:p3", "trend-scout", "working"),
        ("w2:p4", "aste-screener", "working"),
        ("w2:p5", "discovery", "working"),
        ("w2:p6", "clientloop", "working"),
        ("w2:p7", "deimos", "working"),
        ("w2:p8", "fleet-tools", "working"),
        ("w2:p9", "gram-relay", "working"),
        ("w2:p10", "omp-docs", "working"),
        ("w2:p11", "mcb-sync", "working"),
        ("w2:p12", "enyo", "working"),
        ("w2:p13", "herdr-app", "working"),
        // TEMPORARY probe switch (folders hang, #552): HERDR_PROBE_NO_IDLE=1 makes them work.
        ("w4:p1", "enyo-scout", Self.idleStatus),
        ("w4:p2", "vesta", Self.idleStatus),
    ]

    static let livePaneIDs = Set(roster.filter { $0.2 != "stopped" }.map { $0.0 })

    static let initialDocument = AgentGroupsDocument(
        revision: 3,
        folders: [
            AgentFolder(id: "enyo", name: "Enyo", order: 0,
                        members: ["enyo-review", "enyo-efm", "enyo", "enyo-scout"]),
            AgentFolder(id: "herdr", name: "Herdr", order: 1, members: ["herdr-ios", "herdr-app"]),
        ],
        stars: ["vetrina"]
    )

    static let agentList: String = {
        let agents = roster.map { pane, name, status in
            let wire = status == "stopped" ? "idle" : status
            return #"{"pane_id":"\#(pane)","name":"\#(name)","agent":"claude","agent_status":"\#(wire)","cwd":"/root/\#(name)","terminal_title_stripped":"\#(status == "blocked" ? "asking to run tests" : "editing the build")"}"#
        }
        return #"{"id":"mock","result":{"type":"agent_list","agents":[\#(agents.joined(separator: ","))]}}"#
    }()

    /// This device's open folders start closed on every launch, so each test sees the same
    /// list, unless `HERDR_MOCK_KEEP_OPEN_FOLDERS=1` (a relaunch that checks they were kept).
    /// The mock home has no host key, so its open folders are kept under the empty one.
    static let prepared: Void = {
        guard ProcessInfo.processInfo.environment["HERDR_MOCK_KEEP_OPEN_FOLDERS"] != "1" else { return }
        UserDefaults.standard.removeObject(forKey: AgentGroupsStore.openFoldersKey(host: ""))
    }()

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        switch request["method"] as? String {
        case "ping":
            let capabilities = Self.advertisesGroups ? #"{"agent_groups":true}"# : "{}"
            return #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.5","protocol":22,"capabilities":\#(capabilities)}}"#
        case "agent.list":
            return Self.agentList
        case "agent.groups.get", "agent.groups.set":
            guard Self.advertisesGroups else {
                return #"{"id":"\#(id)","error":{"code":"unknown_method","message":"unknown method"}}"#
            }
            let params = (request["params"] as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            }
            return AgentFoldersMockServer.shared.answer(id: id, method: request["method"] as? String ?? "",
                                                        params: params)
        default:
            return try await base.roundTrip(requestLine)
        }
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
}

/// The document, held for the launch. A set from a stale revision is refused with
/// `groups_conflict` and the current document, like the server.
final class AgentFoldersMockServer: @unchecked Sendable {
    static let shared = AgentFoldersMockServer()

    private let lock = NSLock()
    private var document = AgentFoldersMockTransport.initialDocument

    func answer(id: String, method: String, params: Data?) -> String {
        lock.lock()
        defer { lock.unlock() }
        if method == "agent.groups.set" {
            guard let params, let proposed = try? JSONDecoder().decode(AgentGroupsDocument.self, from: params) else {
                return #"{"id":"\#(id)","error":{"code":"invalid_groups","message":"malformed document"}}"#
            }
            guard proposed.revision == document.revision else {
                return #"{"id":"\#(id)","error":{"code":"groups_conflict","message":"stale revision","current":\#(Self.json(document))}}"#
            }
            document = proposed
            document.revision += 1
        }
        return #"{"id":"\#(id)","result":\#(Self.json(document, type: true))}"#
    }

    private static func json(_ document: AgentGroupsDocument, type: Bool = false) -> String {
        guard let data = try? JSONEncoder().encode(document),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        if type { object["type"] = "agent_groups" }
        guard let out = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: out, as: UTF8.self)
    }
}
#endif
