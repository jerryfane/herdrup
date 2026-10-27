#if DEBUG
import Foundation
import HerdrKit

/// The mock daemons' avatar store (herdrup#538): `agent.avatar.set` / `agent.avatar.get`
/// and the `avatar` field overlaid on `agent.list`, the way the herdr server keys them by
/// target. Kept in UserDefaults, so a choice survives a relaunch like the real server's
/// `agent-avatars/index.json`. `HERDR_MOCK_AVATARS=reset` starts the launch from the
/// fixture's avatars; any other value keeps what an earlier launch stored.
///
/// The plain `list` mock advertises `agent_avatar` only under `HERDR_MOCK_AVATARS`, so
/// other receipts keep their ping answer; the `chatview` mock always does.
enum AgentAvatarMockServer {
    static let enabled = ProcessInfo.processInfo.environment["HERDR_MOCK_AVATARS"] != nil

    private static let storeKey = "mock.agentAvatars.descriptors"
    private static let blobKey = "mock.agentAvatars.blobs"
    private static let lock = NSLock()

    private static let reset: Void = {
        if ProcessInfo.processInfo.environment["HERDR_MOCK_AVATARS"] == "reset" {
            UserDefaults.standard.removeObject(forKey: storeKey)
            UserDefaults.standard.removeObject(forKey: blobKey)
        }
    }()

    /// The answer to an avatar request, or nil for any other method.
    static func answer(_ requestLine: String) -> String? {
        guard requestLine.contains("agent.avatar.") else { return nil }
        _ = reset
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        let params = request["params"] as? [String: Any] ?? [:]
        switch request["method"] as? String {
        case "agent.avatar.set": return set(id: id, params: params)
        case "agent.avatar.get": return get(id: id, params: params)
        default: return nil
        }
    }

    /// `agent.list` with every stored choice applied to the agent it targets.
    static func overlay(_ agentList: String) -> String {
        _ = reset
        let stored = descriptors()
        guard !stored.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: Data(agentList.utf8))) as? [String: Any],
              var result = root["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return agentList }
        result["agents"] = agents.map { agent -> [String: Any] in
            var agent = agent
            let keys = [agent["terminal_id"], agent["pane_id"], agent["name"]].compactMap { $0 as? String }
            if let key = keys.first(where: { stored[$0] != nil }), let value = stored[key] {
                agent["avatar"] = value
            }
            return agent
        }
        root["result"] = result
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return agentList }
        return String(decoding: data, as: UTF8.self)
    }

    private static func set(id: String, params: [String: Any]) -> String {
        guard let target = params["target"] as? String else { return error(id, "invalid_request", "missing target") }
        let descriptor: Any
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        switch params["avatar"] {
        case nil, is NSNull:
            descriptor = NSNull()
        case let avatar as [String: Any] where avatar["style"] as? String == "mascot":
            guard let mascot = avatar["mascot"] as? String,
                  mascot.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil else {
                return error(id, "invalid_avatar", "bad mascot id")
            }
            descriptor = ["style": "mascot", "mascot": mascot, "sha256": NSNull(), "updated_unix_ms": now] as [String: Any]
        case let avatar as [String: Any] where avatar["style"] as? String == "image":
            guard let base64 = params["image_base64"] as? String, let bytes = Data(base64Encoded: base64),
                  AgentAvatarImage.mime(of: bytes) != nil else {
                return error(id, "invalid_avatar", "image must be JPEG or PNG")
            }
            guard bytes.count <= AgentAvatarImage.maxBytes else { return error(id, "avatar_too_large", "image over 64 KiB") }
            let sha256 = AgentAvatarImage.sha256(of: bytes)
            lock.withLock {
                var blobs = UserDefaults.standard.dictionary(forKey: blobKey) as? [String: String] ?? [:]
                blobs[sha256] = base64
                UserDefaults.standard.set(blobs, forKey: blobKey)
            }
            descriptor = ["style": "image", "mascot": NSNull(), "sha256": sha256, "updated_unix_ms": now] as [String: Any]
        default:
            return error(id, "invalid_avatar", "unknown style")
        }
        lock.withLock {
            var stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
            stored[target] = json(descriptor)
            UserDefaults.standard.set(stored, forKey: storeKey)
        }
        return #"{"id":"\#(id)","result":{"type":"agent_avatar_set","avatar":\#(json(descriptor))}}"#
    }

    private static func get(id: String, params: [String: Any]) -> String {
        let sha256 = (params["sha256"] as? String ?? "").lowercased()
        if sha256 == MockWireFixtures.avatarImageSHA256 {
            return MockWireFixtures.avatarImage.replacingOccurrences(of: #""id":"mock""#, with: #""id":"\#(id)""#)
        }
        let blobs = UserDefaults.standard.dictionary(forKey: blobKey) as? [String: String] ?? [:]
        guard let base64 = blobs[sha256], let bytes = Data(base64Encoded: base64),
              let mime = AgentAvatarImage.mime(of: bytes) else {
            return error(id, "avatar_not_found", "no such avatar image")
        }
        return #"{"id":"\#(id)","result":{"type":"agent_avatar_image","mime":"\#(mime)","data_base64":"\#(base64)"}}"#
    }

    private static func descriptors() -> [String: Any] {
        let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        return stored.compactMapValues { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
        }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func error(_ id: String, _ code: String, _ message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }
}
#endif
