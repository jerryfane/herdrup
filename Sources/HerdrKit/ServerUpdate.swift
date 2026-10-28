import Foundation

// MARK: - Wire (server.update_check / server.update_apply / server.update_status)

/// Result of `server.update_check` (`type: "update_check"`): what the server runs, the newest
/// signed preview for its platform, and whether it can switch to it live. Mirrors herdr's
/// `ResponseResult::UpdateCheck` (jerryfane/herdr#336); the `type` tag is ignored on decode.
public struct ServerUpdateCheck: Decodable, Sendable, Equatable {
    /// The running build. Everything but `version` is absent on a dev build without git context.
    public struct Running: Decodable, Sendable, Equatable {
        public let version: String
        public let commit: String?
        public let buildID: String?
        public let protocolVersion: Int?
        public let endpointGeneration: Int?
        /// Unix seconds of the build's commit (`HERDR_BUILD_COMMIT_TIME`).
        public let commitTime: Int64?

        public init(version: String, commit: String? = nil, buildID: String? = nil,
                    protocolVersion: Int? = nil, endpointGeneration: Int? = nil, commitTime: Int64? = nil) {
            self.version = version
            self.commit = commit
            self.buildID = buildID
            self.protocolVersion = protocolVersion
            self.endpointGeneration = endpointGeneration
            self.commitTime = commitTime
        }

        enum CodingKeys: String, CodingKey {
            case version, commit
            case buildID = "build_id"
            case protocolVersion = "protocol"
            case endpointGeneration = "endpoint_generation"
            case commitTime = "commit_time"
        }
    }

    /// The newest build the signed manifest offers for this server's platform.
    public struct Latest: Decodable, Sendable, Equatable {
        public let version: String
        public let commit: String
        public let buildID: String
        public let builtAt: String?
        public let commitTime: Int64?
        public let notes: String?
        /// Asset size in bytes.
        public let size: Int64?

        public init(version: String, commit: String, buildID: String, builtAt: String? = nil,
                    commitTime: Int64? = nil, notes: String? = nil, size: Int64? = nil) {
            self.version = version
            self.commit = commit
            self.buildID = buildID
            self.builtAt = builtAt
            self.commitTime = commitTime
            self.notes = notes
            self.size = size
        }

        enum CodingKeys: String, CodingKey {
            case version, commit, notes, size
            case buildID = "build_id"
            case builtAt = "built_at"
            case commitTime = "commit_time"
        }
    }

    /// How the server can take the update.
    public enum Mode: Sendable, Equatable {
        /// Live handoff: terminals stay open.
        case live
        /// Can only download now and finish when herdr next restarts.
        case restartRequired
        /// Cannot update from the app at all.
        case unsupported
    }

    /// Why the mode is not `live`.
    public enum Reason: Sendable, Equatable {
        case windows
        case systemdMainProcess
        case packageManaged
        case endpointGenerationChanged
        case noLiveHandoff
        case installDirNotWritable
        case other(String)

        init(wire: String) {
            switch wire {
            case "windows": self = .windows
            case "systemd_main_process": self = .systemdMainProcess
            case "package_managed": self = .packageManaged
            case "endpoint_generation_changed": self = .endpointGenerationChanged
            case "no_live_handoff": self = .noLiveHandoff
            case "install_dir_not_writable": self = .installDirNotWritable
            default: self = .other(wire)
            }
        }
    }

    public let running: Running
    /// Nil when the manifest has no build for this platform.
    public let latest: Latest?
    /// The server's verdict: a different, newer build that has not rolled back here.
    public let updateAvailable: Bool
    public let mode: Mode
    /// Present only when `mode` is not `live`.
    public let reason: Reason?

    public init(running: Running, latest: Latest?, updateAvailable: Bool, mode: Mode, reason: Reason? = nil) {
        self.running = running
        self.latest = latest
        self.updateAvailable = updateAvailable
        self.mode = mode
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case running, latest, mode, reason
        case updateAvailable = "update_available"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Running.self, forKey: .running)
        latest = try c.decodeIfPresent(Latest.self, forKey: .latest)
        updateAvailable = try c.decode(Bool.self, forKey: .updateAvailable)
        switch try c.decode(String.self, forKey: .mode) {
        case "live": mode = .live
        case "restart_required": mode = .restartRequired
        // A mode this app does not know offers no button: the safe reading.
        default: mode = .unsupported
        }
        reason = try c.decodeIfPresent(String.self, forKey: .reason).map(Reason.init(wire:))
    }
}

/// `server.update_apply`'s answer: the attempt started (preflight passed). The download, checks
/// and handoff run after it returns, so their failures arrive as an `update_status` outcome.
struct ServerUpdateApplyResult: Decodable, Sendable {
    let attemptID: String
    enum CodingKeys: String, CodingKey { case attemptID = "attempt_id" }
}

/// `server.update_status`'s answer: the last attempt on this machine, or nil if there never was
/// one. The state lives on disk on the server, so whichever build is serving answers it.
public struct ServerUpdateStatus: Decodable, Sendable, Equatable {
    public let attempt: ServerUpdateAttempt?

    public init(attempt: ServerUpdateAttempt?) { self.attempt = attempt }
}

/// One update attempt as `server.update_status` reports it.
public struct ServerUpdateAttempt: Decodable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case downloading, verifying, testing, switching, confirming, installing
        case other(String)

        init(wire: String) {
            switch wire {
            case "downloading": self = .downloading
            case "verifying": self = .verifying
            case "testing": self = .testing
            case "switching": self = .switching
            case "confirming": self = .confirming
            case "installing": self = .installing
            default: self = .other(wire)
            }
        }

        public var wire: String {
            switch self {
            case .downloading: return "downloading"
            case .verifying: return "verifying"
            case .testing: return "testing"
            case .switching: return "switching"
            case .confirming: return "confirming"
            case .installing: return "installing"
            case .other(let wire): return wire
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case updated
        /// The new build runs, but the copy on disk could not be replaced.
        case updatedDiskStale
        /// The new build failed its checks; herdr switched back to the old one.
        case rolledBack
        /// Nothing changed: the old build never stopped serving.
        case failedNoChange
        /// Even the switch back failed. Nothing was killed; a person has to look.
        case needsAttention
        /// `restart_later`: installed on disk, starts on the next restart.
        case downloadedRestartRequired
        case other(String)

        init(wire: String) {
            switch wire {
            case "updated": self = .updated
            case "updated_disk_stale": self = .updatedDiskStale
            case "rolled_back": self = .rolledBack
            case "failed_no_change": self = .failedNoChange
            case "needs_attention": self = .needsAttention
            case "downloaded_restart_required": self = .downloadedRestartRequired
            default: self = .other(wire)
            }
        }

        public var wire: String {
            switch self {
            case .updated: return "updated"
            case .updatedDiskStale: return "updated_disk_stale"
            case .rolledBack: return "rolled_back"
            case .failedNoChange: return "failed_no_change"
            case .needsAttention: return "needs_attention"
            case .downloadedRestartRequired: return "downloaded_restart_required"
            case .other(let wire): return wire
            }
        }
    }

    public let attemptID: String
    public let buildID: String
    /// "<version> (<short commit>)" of the build that was running.
    public let from: String
    /// "<version> (<short commit>)" of the build being installed.
    public let to: String
    public let phase: Phase
    public let bytesDone: Int64
    /// 0 when the size is not known.
    public let bytesTotal: Int64
    public let restartLater: Bool
    /// Nil while the attempt is still running.
    public let outcome: Outcome?
    public let message: String?
    /// The terminal count from the snapshot taken before the switch (from `switching` on).
    public let panes: Int?

    public init(attemptID: String, buildID: String, from: String, to: String, phase: Phase,
                bytesDone: Int64 = 0, bytesTotal: Int64 = 0, restartLater: Bool = false,
                outcome: Outcome? = nil, message: String? = nil, panes: Int? = nil) {
        self.attemptID = attemptID
        self.buildID = buildID
        self.from = from
        self.to = to
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.restartLater = restartLater
        self.outcome = outcome
        self.message = message
        self.panes = panes
    }

    enum CodingKeys: String, CodingKey {
        case from, to, phase, outcome, message, panes
        case attemptID = "attempt_id"
        case buildID = "build_id"
        case bytesDone = "bytes_done"
        case bytesTotal = "bytes_total"
        case restartLater = "restart_later"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try c.decode(String.self, forKey: .attemptID)
        buildID = try c.decode(String.self, forKey: .buildID)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        phase = Phase(wire: try c.decode(String.self, forKey: .phase))
        bytesDone = try c.decodeIfPresent(Int64.self, forKey: .bytesDone) ?? 0
        bytesTotal = try c.decodeIfPresent(Int64.self, forKey: .bytesTotal) ?? 0
        restartLater = try c.decodeIfPresent(Bool.self, forKey: .restartLater) ?? false
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome).map(Outcome.init(wire:))
        message = try c.decodeIfPresent(String.self, forKey: .message)
        panes = try c.decodeIfPresent(Int.self, forKey: .panes)
    }

    /// What "Copy details" puts on the clipboard: everything someone needs to look into it.
    public func details(host: String) -> String {
        var lines = ["herdr update on \(host)",
                     "attempt: \(attemptID)",
                     "build: \(buildID)",
                     "from: \(from)",
                     "to: \(to)",
                     "phase: \(phase.wire)"]
        if bytesTotal > 0 { lines.append("bytes: \(bytesDone) of \(bytesTotal)") }
        lines.append("outcome: \(outcome?.wire ?? "running")")
        if let message, !message.isEmpty { lines.append("message: \(message)") }
        return lines.joined(separator: "\n")
    }
}

/// The `server.update_*` error codes the app tells apart.
public enum ServerUpdateErrorCode {
    public static let manifestUnreachable = "update_manifest_unreachable"
    public static let signatureInvalid = "update_signature_invalid"
    public static let manifestInvalid = "update_manifest_invalid"
    public static let buildMismatch = "update_build_mismatch"
    public static let inProgress = "update_in_progress"
    public static let notAvailable = "update_not_available"
    public static let restartRequired = "update_restart_required"
    public static let unsupportedInstall = "update_unsupported_install"
    public static let preflightFailed = "update_preflight_failed"
    /// A guest (or any non-owner) asked: the server's guest gate answers this.
    public static let guestForbidden = "guest_forbidden"
}

// MARK: - What this app needs from the server

/// A server feature this app release uses, advertised as a `ping` capability.
public enum ServerFeature: String, CaseIterable, Sendable, Equatable {
    case agentGroups
    case agentAvatar
    case agentAnswer
    case serverUpdate

    /// How the update card names the feature ("Folders and avatars need herdr 0.9.5").
    public var label: String {
        switch self {
        case .agentGroups: return "folders"
        case .agentAvatar: return "avatars"
        case .agentAnswer: return "answers from notifications"
        case .serverUpdate: return "one-tap updates"
        }
    }

    public func isAdvertised(by capabilities: ServerCapabilities?) -> Bool {
        guard let capabilities else { return false }
        switch self {
        case .agentGroups: return capabilities.agentGroups
        case .agentAvatar: return capabilities.agentAvatar
        case .agentAnswer: return capabilities.agentAnswer
        case .serverUpdate: return capabilities.serverUpdate
        }
    }
}

/// The oldest herdr build this app release is made for (DESIGN §5). A server is "older than the
/// app needs" when it lacks a required feature, or its commit is older than `minCommitTime`.
public struct ServerRequirement: Sendable, Equatable {
    /// Unix seconds of the oldest acceptable herdr commit.
    public let minCommitTime: Int64
    public let features: [ServerFeature]

    public init(minCommitTime: Int64, features: [ServerFeature]) {
        self.minCommitTime = minCommitTime
        self.features = features
    }

    /// This release: herdr 8a02b834 (2026-10-27, folders and stars), plus avatars, answering
    /// from a notification and one-tap updates.
    public static let current = ServerRequirement(
        minCommitTime: 1_793_108_998,
        features: [.agentGroups, .agentAvatar, .agentAnswer, .serverUpdate])

    /// The required features the server does not advertise, in requirement order.
    public func missingFeatures(_ capabilities: ServerCapabilities?) -> [ServerFeature] {
        features.filter { !$0.isAdvertised(by: capabilities) }
    }

    /// Whether the running server meets the requirement. A build that reports no commit time
    /// (a dev build) is judged by its features alone.
    public func isMet(by capabilities: ServerCapabilities?, commitTime: Int64?) -> Bool {
        guard missingFeatures(capabilities).isEmpty else { return false }
        guard let commitTime else { return true }
        return commitTime >= minCommitTime
    }

    /// Whether a published build is new enough. Features of a build that is not running are
    /// unknown, so only its commit time can say; one without a commit time does not count.
    public func isMet(by latest: ServerUpdateCheck.Latest) -> Bool {
        guard let commitTime = latest.commitTime else { return false }
        return commitTime >= minCommitTime
    }
}

// MARK: - Versions as people read them

public enum ServerUpdateVersion {
    /// "0.9.6" from "0.9.6-preview.2026-10-28-0123456789ab" or "0.9.6 (01234567)".
    public static func base(_ version: String) -> String {
        let end = version.firstIndex(where: { $0 == "-" || $0 == " " || $0 == "+" }) ?? version.endIndex
        return String(version[..<end])
    }

    /// The build date in a preview version ("2026-10-28"), if it carries one.
    public static func date(_ version: String) -> String? {
        guard let range = version.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return String(version[range])
    }

    /// Labels for two builds that are always told apart: the base versions when they differ,
    /// else the base version with each build's date ("0.9.5 of 2026-10-28").
    public static func labels(old: String, new: String) -> (old: String, new: String) {
        let oldBase = base(old), newBase = base(new)
        guard oldBase == newBase else { return (oldBase, newBase) }
        let oldDate = date(old), newDate = date(new)
        guard let oldDate, let newDate, oldDate != newDate else { return (old, new) }
        return ("\(oldBase) of \(oldDate)", "\(newBase) of \(newDate)")
    }
}

// MARK: - What the Machines card shows

/// The server's update check as the app last saw it.
public enum ServerUpdateCheckState: Sendable, Equatable {
    /// Not asked yet, or the server does not advertise `server_update`.
    case unknown
    case loaded(ServerUpdateCheck)
    /// The server refused for this user (`guest_forbidden`): it is not the owner's connection.
    case forbidden
    /// The check failed (manifest unreachable, signature not published yet, …).
    case failed(code: String)
}

/// The app's side of an update the user started (or found running on connect).
public enum ServerUpdateFlow: Sendable, Equatable {
    case idle
    /// `update_apply` sent, or an attempt without an outcome found on connect. The attempt is
    /// nil until the first `update_status` answers.
    case running(ServerUpdateAttempt?, restartLater: Bool)
    /// The attempt has an outcome.
    case finished(ServerUpdateAttempt)
    /// `update_apply` was refused before anything started.
    case refused(code: String, message: String)
    /// The server stopped answering for longer than any update takes.
    case lostTrack(ServerUpdateAttempt?)
}

/// One state of the update card in Settings › Machines (proposal B), derived from what the
/// server said. Copy and layout live in the app; this decides WHICH card.
public enum ServerUpdateCard: Sendable, Equatable {
    /// No card (no update, a guest, or a check that failed).
    case hidden
    /// A newer build is ready. `restartLater`: the server can't switch live, so the button
    /// downloads now and finishes on the next restart.
    case available(old: String, new: String, missing: [ServerFeature], notes: String?,
                   restartLater: Bool, reason: ServerUpdateCheck.Reason?)
    /// The server is older than this app needs and no published build is new enough.
    case unpublished(old: String)
    /// The server can't update itself from the app (package manager, Windows, read-only dir).
    case unsupported(reason: ServerUpdateCheck.Reason?)
    /// Download → Check → Switch over. `step` is 0, 1 or 2; `fraction` fills the download.
    case updating(step: Int, fraction: Double, phase: ServerUpdateAttempt.Phase,
                  bytesDone: Int64, bytesTotal: Int64, restartLater: Bool)
    case done(new: String, panes: Int?, nowOn: [ServerFeature], diskStale: Bool)
    /// Nothing changed. `canRetry` is false when the server would refuse the same build.
    case failed(old: String, failure: ServerUpdateFailure, canRetry: Bool)
    /// Installed on disk; herdr picks it up on its next restart.
    case restartPending(new: String, reason: ServerUpdateCheck.Reason?)
    /// The server predates `server_update`: it must be updated once by hand.
    case tooOld

    /// What the Settings tab's "1" stands for, or nil for a card that asks for nothing. Opening
    /// Settings › Machines marks the key seen; a newer version is a new key, so it comes back.
    public var badgeKey: String? {
        switch self {
        case .available(_, let new, _, _, _, _): return "available \(new)"
        case .tooOld: return "too-old"
        case .failed(let old, _, _): return "failed \(old)"
        case .restartPending(let new, _): return "restart \(new)"
        case .hidden, .unpublished, .unsupported, .updating, .done: return nil
        }
    }

    /// Whether the Settings tab carries the "1", given the key last seen in Machines. A pending
    /// restart keeps it until herdr restarts.
    public func showsBadge(seen: String?) -> Bool {
        guard let key = badgeKey else { return false }
        if case .restartPending = self { return true }
        return key != seen
    }
}

/// Why an update did not finish.
public enum ServerUpdateFailure: Sendable, Equatable {
    /// The download stopped part way.
    case downloadStopped(bytesDone: Int64, bytesTotal: Int64)
    /// The new build failed before the switch; the old one never stopped.
    case noChange(message: String?)
    /// The new build failed its checks after the switch; herdr switched back.
    case rolledBack(message: String?)
    /// The switch back failed too. Nothing was killed.
    case needsAttention(message: String?)
    /// The server refused to start (`update_apply` error).
    case refused(code: String, message: String)
    /// The server stopped answering while it switched.
    case lostTrack
}

extension ServerUpdateCard {
    /// Picks the card. `missingBefore` is what the server lacked when the update started, so
    /// the done card can say what is on now.
    public static func make(capabilities: ServerCapabilities?, capabilitiesKnown: Bool,
                            check: ServerUpdateCheckState, flow: ServerUpdateFlow,
                            pendingRestart: ServerUpdateAttempt?,
                            missingBefore: [ServerFeature],
                            requirement: ServerRequirement = .current) -> ServerUpdateCard {
        if check == .forbidden { return .hidden }
        let loadedCheck: ServerUpdateCheck? = {
            if case .loaded(let loaded) = check { return loaded }
            return nil
        }()
        let runningVersion = loadedCheck?.running.version

        switch flow {
        case .running(let attempt, let restartLater):
            return updating(attempt, restartLater: restartLater)
        case .finished(let attempt):
            return finished(attempt, capabilities: capabilities, missingBefore: missingBefore,
                            reason: loadedCheck?.reason)
        case .refused(let code, let message):
            let old = runningVersion.map(ServerUpdateVersion.base) ?? ""
            // A build that changed under the user, or one already running, is re-checked
            // rather than retried blind; the rest can be tried again as is.
            let retry = code != ServerUpdateErrorCode.unsupportedInstall
                && code != ServerUpdateErrorCode.notAvailable
            return .failed(old: old, failure: .refused(code: code, message: message), canRetry: retry)
        case .lostTrack(let attempt):
            let old = attempt.map { ServerUpdateVersion.base($0.from) }
                ?? runningVersion.map(ServerUpdateVersion.base) ?? ""
            return .failed(old: old, failure: .lostTrack, canRetry: false)
        case .idle:
            break
        }

        guard capabilitiesKnown else { return .hidden }
        guard ServerFeature.serverUpdate.isAdvertised(by: capabilities) else { return .tooOld }
        guard case .loaded(let loaded) = check else { return .hidden }

        if let pending = pendingRestart, pending.outcome == .downloadedRestartRequired,
           loaded.running.buildID != pending.buildID {
            return .restartPending(new: ServerUpdateVersion.labels(old: pending.from, new: pending.to).new,
                                   reason: loaded.reason)
        }

        let meets = requirement.isMet(by: capabilities, commitTime: loaded.running.commitTime)
        guard loaded.updateAvailable, let latest = loaded.latest else {
            return meets ? .hidden : .unpublished(old: ServerUpdateVersion.base(loaded.running.version))
        }
        if !meets && !requirement.isMet(by: latest) {
            return .unpublished(old: ServerUpdateVersion.base(loaded.running.version))
        }
        switch loaded.mode {
        case .unsupported:
            return .unsupported(reason: loaded.reason)
        case .live, .restartRequired:
            let labels = ServerUpdateVersion.labels(old: loaded.running.version, new: latest.version)
            let missing = requirement.missingFeatures(capabilities).filter { $0 != .serverUpdate }
            return .available(old: labels.old, new: labels.new, missing: missing, notes: latest.notes,
                              restartLater: loaded.mode == .restartRequired, reason: loaded.reason)
        }
    }

    /// Download is step 0 (filled by bytes), verifying and testing are step 1, the rest step 2.
    static func updating(_ attempt: ServerUpdateAttempt?, restartLater: Bool) -> ServerUpdateCard {
        guard let attempt else {
            return .updating(step: 0, fraction: 0, phase: .downloading, bytesDone: 0, bytesTotal: 0,
                             restartLater: restartLater)
        }
        let step: Int
        var fraction = 1.0
        switch attempt.phase {
        case .downloading:
            step = 0
            fraction = attempt.bytesTotal > 0
                ? min(1, max(0, Double(attempt.bytesDone) / Double(attempt.bytesTotal))) : 0
        case .verifying, .testing:
            step = 1
        case .switching, .confirming, .installing, .other:
            step = 2
        }
        return .updating(step: step, fraction: fraction, phase: attempt.phase,
                         bytesDone: attempt.bytesDone, bytesTotal: attempt.bytesTotal,
                         restartLater: attempt.restartLater || restartLater)
    }

    static func finished(_ attempt: ServerUpdateAttempt, capabilities: ServerCapabilities?,
                         missingBefore: [ServerFeature], reason: ServerUpdateCheck.Reason?) -> ServerUpdateCard {
        let labels = ServerUpdateVersion.labels(old: attempt.from, new: attempt.to)
        switch attempt.outcome {
        case .updated, .updatedDiskStale:
            let nowOn = missingBefore.filter { $0 != .serverUpdate && $0.isAdvertised(by: capabilities) }
            return .done(new: labels.new, panes: attempt.panes, nowOn: nowOn,
                         diskStale: attempt.outcome == .updatedDiskStale)
        case .downloadedRestartRequired:
            return .restartPending(new: labels.new, reason: reason)
        case .rolledBack:
            // The server does not offer a build that rolled back here again.
            return .failed(old: labels.old, failure: .rolledBack(message: attempt.message), canRetry: false)
        case .needsAttention:
            return .failed(old: labels.old, failure: .needsAttention(message: attempt.message), canRetry: false)
        case .failedNoChange, .other, .none:
            let failure: ServerUpdateFailure = attempt.phase == .downloading
                ? .downloadStopped(bytesDone: attempt.bytesDone, bytesTotal: attempt.bytesTotal)
                : .noChange(message: attempt.message)
            return .failed(old: labels.old, failure: failure, canRetry: true)
        }
    }
}

// MARK: - Following an attempt across the handoff

/// Polls `server.update_status` until the attempt has an outcome. The handoff drops every
/// client, so failed polls are expected for a few seconds: they are counted, not fatal. Each
/// poll asks `client()` for the connection to use, so a reconnect that replaces the client
/// carries on with the new one.
public struct ServerUpdateFollower: Sendable {
    /// Between polls.
    public var intervalNanoseconds: UInt64
    /// Consecutive polls without an answer about the attempt before the app stops waiting. At the default
    /// interval, two minutes: longer than any handoff, shorter than forever.
    public var maxSilentPolls: Int

    public init(intervalNanoseconds: UInt64 = 1_000_000_000, maxSilentPolls: Int = 120) {
        self.intervalNanoseconds = intervalNanoseconds
        self.maxSilentPolls = maxSilentPolls
    }

    /// Follows `attemptID` (nil: whichever attempt the server reports) and returns how it
    /// ended: `.finished` with the outcome, `.lostTrack` when the server stayed silent, or
    /// `.running` if the task was cancelled first. `progress` sees every answer on the way.
    public func follow(
        attemptID: String?,
        client: @Sendable () async -> HerdrClient?,
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        progress: @Sendable (ServerUpdateAttempt) async -> Void
    ) async -> ServerUpdateFlow {
        var last: ServerUpdateAttempt?
        var silent = 0
        while !Task.isCancelled {
            var answered = false
            if let connection = await client() {
                do {
                    // Only this attempt counts as an answer: a server that keeps reporting
                    // another one (or none) has lost it, and is given up on like silence.
                    if let attempt = try await connection.updateStatus(),
                       attemptID == nil || attempt.attemptID == attemptID {
                        answered = true
                        last = attempt
                        await progress(attempt)
                        if attempt.outcome != nil { return .finished(attempt) }
                    }
                } catch {
                    // The handoff closed the connection, or the new server is not up yet.
                }
            }
            silent = answered ? 0 : silent + 1
            if silent >= maxSilentPolls { return .lostTrack(last) }
            do { try await sleep(intervalNanoseconds) } catch { break }
        }
        return .running(last, restartLater: last?.restartLater ?? false)
    }
}
