#if DEBUG
import Foundation
import HerdrKit

/// The update mock server (`HERDR_SCREENSHOT_MOCK=serverupdate`, herdrup#565): the Agents home
/// on "mac-mini", whose herdr answers `server.update_check` / `update_apply` / `update_status`
/// the way herdr#336 does. `HERDR_MOCK_UPDATE` picks the scenario:
///
/// - `available`: herdr 0.9.3 with 0.9.5 published, live. An update runs to `updated`.
/// - `updating`: the same, but the download holds at 12 of 38 MB.
/// - `failed`: the first download stops at 21 of 38 MB (`failed_no_change`); a retry succeeds.
/// - `rolledback` / `needsattention`: the switch happens, then the checks fail.
/// - `restart`: herdr runs as a system service (`restart_required`); the download finishes
///   with `downloaded_restart_required`.
/// - `old`: herdr 0.9.3 without `server_update`.
/// - `guest`: the connection is not the owner's; `update_check` answers `guest_forbidden`.
/// - `failedcheck`: like `failed`, but after the failure the check can't reach the manifest
///   (`update_manifest_unreachable`), so Try again has nothing to install.
/// - `lostapply`: the status file holds yesterday's failed attempt for the same build, and
///   `update_apply` drops the connection without starting anything.
///
/// Every update drops the connection while it switches over: two `update_status` polls fail.
/// Everything else is the plain mock daemon.
enum ServerUpdateMock {
    enum Scenario: String {
        case available, updating, failed, rolledBack = "rolledback", needsAttention = "needsattention"
        case restart, old, guest
        case failedCheck = "failedcheck", lostApply = "lostapply"
    }

    static let host = "mac-mini"

    static var scenario: Scenario {
        Scenario(rawValue: ProcessInfo.processInfo.environment["HERDR_MOCK_UPDATE"]?.lowercased() ?? "")
            ?? .available
    }

    /// Fast polls, so a whole update takes a few seconds in the simulator.
    static let follower = ServerUpdateFollower(intervalNanoseconds: 400_000_000, maxSilentPolls: 20,
                                               maxForeignPolls: 10)
}

struct ServerUpdateMockTransport: HerdrTransport {
    private let base = MockTransport()
    private let server = ServerUpdateMockServer.shared

    func roundTrip(_ requestLine: String) async throws -> String {
        let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "mock"
        let params = request["params"] as? [String: Any] ?? [:]
        if let answer = try server.answer(id: id, method: request["method"] as? String ?? "", params: params) {
            return answer
        }
        return try await base.roundTrip(requestLine)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> { base.stream(requestLine) }
}

/// The server side, held for the launch.
final class ServerUpdateMockServer: @unchecked Sendable {
    static let shared = ServerUpdateMockServer(scenario: ServerUpdateMock.scenario)

    struct Dropped: Error {}

    private struct Step {
        var phase: String
        var mb: Int64 = 0
        var outcome: String?
        var drop = false
    }

    private static let mb: Int64 = 1_048_576
    private static let totalMB: Int64 = 38
    private static let oldBuild = "2026-10-06-4c1e9a2b5d10"
    private static let newBuild = "2026-10-28-8a02b8349f3c"

    private let lock = NSLock()
    private let scenario: ServerUpdateMock.Scenario
    private var updated = false
    private var rolledBack = false
    private var attempts = 0
    private var steps: [Step] = []
    private var attemptJSON: String?
    private var restartLater = false

    init(scenario: ServerUpdateMock.Scenario) {
        self.scenario = scenario
        if scenario == .lostApply {
            attemptJSON = #"{"attempt_id":"upd-old","build_id":"\#(Self.newBuild)","from":"0.9.3-preview.2026-10-06-4c1e9a2b5d10 (4c1e9a2b)","to":"0.9.5-preview.2026-10-28-8a02b8349f3c (8a02b834)","phase":"downloading","bytes_done":\#(9 * Self.mb),"bytes_total":\#(Self.totalMB * Self.mb),"restart_later":false,"outcome":"failed_no_change","message":"connection reset while downloading"}"#
        }
    }

    func answer(id: String, method: String, params: [String: Any]) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "ping":
            return ok(id, ping)
        case "server.staged_update":
            let (version, sha) = updated ? ("0.9.5", "8a02b83") : ("0.9.3", "4c1e9a2")
            return ok(id, #"{"type":"staged_update","running_version":"\#(version)","running_protocol":22,"running_sha":"\#(sha)","staged":null}"#)
        case "server.update_check":
            if scenario == .old { return unknownMethod(id) }
            if scenario == .guest { return error(id, "guest_forbidden", "guests cannot update herdr") }
            if scenario == .failedCheck && attempts > 0 {
                return error(id, "update_manifest_unreachable", "could not fetch the manifest")
            }
            return ok(id, check)
        case "server.update_apply":
            // The connection drops before the answer, and nothing starts.
            if scenario == .lostApply { throw Dropped() }
            return apply(id: id, params: params)
        case "server.update_status":
            if scenario == .old { return unknownMethod(id) }
            if scenario == .guest { return error(id, "guest_forbidden", "guests cannot update herdr") }
            return try status(id: id)
        default:
            return nil
        }
    }

    // MARK: Answers

    private var ping: String {
        let capabilities: String
        if updated {
            capabilities = #"{"live_handoff":true,"agent_answer":true,"agent_avatar":true,"agent_groups":true,"server_update":true}"#
        } else if scenario == .old {
            capabilities = #"{"live_handoff":true,"agent_answer":true}"#
        } else {
            capabilities = #"{"live_handoff":true,"agent_answer":true,"server_update":true}"#
        }
        return #"{"type":"pong","version":"\#(updated ? "0.9.5" : "0.9.3")","protocol":22,"capabilities":\#(capabilities)}"#
    }

    private var check: String {
        let running = updated
            ? #"{"version":"0.9.5-preview.2026-10-28-8a02b8349f3c","commit":"8a02b8349f3c","build_id":"\#(Self.newBuild)","protocol":22,"endpoint_generation":1,"commit_time":1793108998}"#
            : #"{"version":"0.9.3-preview.2026-10-06-4c1e9a2b5d10","commit":"4c1e9a2b5d10","build_id":"\#(Self.oldBuild)","protocol":22,"endpoint_generation":1,"commit_time":1791280000}"#
        let latest = #"{"version":"0.9.5-preview.2026-10-28-8a02b8349f3c","commit":"8a02b8349f3c0000000000000000000000000000","build_id":"\#(Self.newBuild)","built_at":"2026-10-28T08:00:00Z","commit_time":1793108998,"notes":"folders, stars, avatars, and answering agents from a notification.","size":\#(Self.totalMB * Self.mb),"protocol":22,"endpoint_generation":1}"#
        let available = !updated && !rolledBack
        let mode = scenario == .restart ? #""mode":"restart_required","reason":"systemd_main_process""# : #""mode":"live""#
        return #"{"type":"update_check","running":\#(running),"latest":\#(latest),"update_available":\#(available),\#(mode)}"#
    }

    private func apply(id: String, params: [String: Any]) -> String {
        guard params["build_id"] as? String == Self.newBuild else {
            return error(id, "update_build_mismatch", "the manifest changed; check again")
        }
        if updated || rolledBack { return error(id, "update_not_available", "nothing newer to install") }
        if !steps.isEmpty { return error(id, "update_in_progress", "an update is already running") }
        let later = params["restart_later"] as? Bool ?? false
        if scenario == .restart && !later {
            return error(id, "update_restart_required", "this herdr can't switch while running")
        }
        attempts += 1
        restartLater = later
        steps = script(attempt: attempts)
        return ok(id, #"{"type":"update_apply","attempt_id":"u-\#(attempts)"}"#)
    }

    private func script(attempt: Int) -> [Step] {
        let download = [4, 12, 26, 38].map { Step(phase: "downloading", mb: Int64($0)) }
        let checks = [Step(phase: "verifying", mb: Self.totalMB), Step(phase: "testing", mb: Self.totalMB)]
        let switching = [Step(phase: "switching", mb: Self.totalMB), Step(phase: "switching", drop: true),
                         Step(phase: "switching", drop: true), Step(phase: "confirming", mb: Self.totalMB)]
        func ending(_ outcome: String) -> Step { Step(phase: "confirming", mb: Self.totalMB, outcome: outcome) }
        switch scenario {
        case .updating:
            return [Step(phase: "downloading", mb: 4), Step(phase: "downloading", mb: 12)]
        case .failed where attempt == 1, .failedCheck:
            return [6, 14, 21].map { Step(phase: "downloading", mb: $0) }
                + [Step(phase: "downloading", mb: 21, outcome: "failed_no_change")]
        case .rolledBack:
            return download + checks + switching + [ending("rolled_back")]
        case .needsAttention:
            return download + checks + switching + [ending("needs_attention")]
        case .restart:
            return download + checks + [Step(phase: "installing", mb: Self.totalMB),
                                        Step(phase: "installing", mb: Self.totalMB, outcome: "downloaded_restart_required")]
        case .available, .failed, .old, .guest, .lostApply:
            return download + checks + switching + [ending("updated")]
        }
    }

    /// Each poll moves one step; the last step repeats.
    private func status(id: String) throws -> String {
        guard !steps.isEmpty || attemptJSON != nil else {
            return ok(id, #"{"type":"update_status","attempt":null}"#)
        }
        if !steps.isEmpty {
            let step = steps.count > 1 ? steps.removeFirst() : steps[0]
            if step.drop { throw Dropped() }
            let message: String
            switch step.outcome {
            case "failed_no_change": message = #","message":"connection reset while downloading""#
            case "rolled_back": message = #","message":"pane w2:p4 missing after the switch""#
            case "needs_attention": message = #","message":"the switch back did not become ready""#
            default: message = ""
            }
            let outcome = step.outcome.map { #","outcome":"\#($0)""# } ?? ""
            let panes = step.phase == "downloading" || step.phase == "verifying" || step.phase == "testing" ? "" : #","panes":14"#
            attemptJSON = #"{"attempt_id":"u-\#(attempts)","build_id":"\#(Self.newBuild)","from":"0.9.3-preview.2026-10-06-4c1e9a2b5d10 (4c1e9a2b)","to":"0.9.5-preview.2026-10-28-8a02b8349f3c (8a02b834)","phase":"\#(step.phase)","bytes_done":\#(step.mb * Self.mb),"bytes_total":\#(Self.totalMB * Self.mb),"restart_later":\#(restartLater)\#(outcome)\#(message)\#(panes)}"#
            if let finished = step.outcome {
                steps = []
                if finished == "updated" { updated = true }
                if finished == "rolled_back" { rolledBack = true }
            }
        }
        return ok(id, #"{"type":"update_status","attempt":\#(attemptJSON ?? "null")}"#)
    }

    // MARK: Envelopes

    private func ok(_ id: String, _ result: String) -> String { #"{"id":"\#(id)","result":\#(result)}"# }

    private func error(_ id: String, _ code: String, _ message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    /// What a server older than the method answers.
    private func unknownMethod(_ id: String) -> String {
        error(id, "invalid_request", "unknown variant")
    }
}
#endif
