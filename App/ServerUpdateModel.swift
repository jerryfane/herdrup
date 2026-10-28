import Foundation
import Observation
import HerdrKit

/// The herdr update for one machine (herdrup#565): what the server runs, what it can update to,
/// and an update in flight. Drives the Settings tab's "1" and the update card in Settings ›
/// Machines (proposal B).
///
/// One per machine for the life of the app (`forHost`), not per connected home: the update's
/// handoff drops the connection, and a reconnect remounts the home with a new client. The
/// model keeps the attempt and the follow loop across that, and `attach` hands the loop the
/// new client.
@MainActor @Observable
final class ServerUpdateModel {
    private static var models: [String: ServerUpdateModel] = [:]

    /// The model for one machine's server. `key` tells machines (and herdr sessions) apart;
    /// `displayName` is the machine as the Connection row names it.
    static func forHost(_ key: String, displayName: String) -> ServerUpdateModel {
        if let model = models[key] {
            model.host = displayName
            return model
        }
        let model = ServerUpdateModel(key: key, host: displayName)
        models[key] = model
        return model
    }

    #if DEBUG
    /// Forgets the model kept for `key`, and what its badge has seen: each UI-test launch
    /// starts clean.
    static func reset(host key: String) {
        models[key] = nil
        UserDefaults.standard.removeObject(forKey: seenDefaultsKey(key))
    }
    #endif

    private let key: String
    private(set) var host: String
    private(set) var runningVersion: String?
    private(set) var capabilities: ServerCapabilities?
    private(set) var capabilitiesKnown = false
    private(set) var check: ServerUpdateCheckState = .unknown
    private(set) var flow: ServerUpdateFlow = .idle
    /// The server's last attempt when it is a `restart_later` download, as of the last refresh.
    /// Whether it is still pending is decided against the build the server runs now
    /// (`ServerUpdateCard.make`), so a restart into it clears the card and the badge.
    private(set) var pendingRestart: ServerUpdateAttempt?
    /// What the server lacked when the update started, so Done can say what is on now.
    private(set) var missingBefore: [ServerFeature] = []
    /// Bumped when an update lands, so the home asks the new server what it supports.
    private(set) var completedUpdates = 0
    /// The badge key last seen in Settings › Machines (per machine, across launches).
    private(set) var seenKey: String?

    @ObservationIgnored private var client: HerdrClient?
    @ObservationIgnored private var follow: Task<Void, Never>?
    /// What the follow loop is following, for Look again.
    @ObservationIgnored private var target: ServerUpdateTarget?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var follower = ServerUpdateFollower()

    private init(key: String, host: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.host = host
        self.defaults = defaults
        seenKey = defaults.string(forKey: Self.seenDefaultsKey(key))
    }

    private static func seenDefaultsKey(_ key: String) -> String { "serverUpdate.seen.\(key)" }

    var card: ServerUpdateCard {
        ServerUpdateCard.make(capabilities: capabilities, capabilitiesKnown: capabilitiesKnown, check: check,
                              flow: flow, pendingRestart: pendingRestart, missingBefore: missingBefore)
    }

    var showsBadge: Bool { card.showsBadge(seen: seenKey) }

    /// The check's newest build, when there is one to install.
    var latest: ServerUpdateCheck.Latest? {
        if case .loaded(let loaded) = check, loaded.updateAvailable { return loaded.latest }
        return nil
    }

    /// Settings › Machines is on screen: what the card shows has been seen.
    func markSeen() {
        guard let key = card.badgeKey, key != seenKey else { return }
        seenKey = key
        defaults.set(key, forKey: Self.seenDefaultsKey(self.key))
    }

    /// The connected home's client. Starts the first check, or hands a running follow the new
    /// connection after a reconnect.
    func attach(client: HerdrClient) {
        let changed = self.client !== client
        self.client = client
        guard changed else { return }
        Task { await refresh() }
    }

    /// Asks the server what it runs and what it can update to. A server too old for
    /// `server_update` stops at the ping; a non-owner stops at `guest_forbidden`. Returns false
    /// when the server did not answer.
    @discardableResult
    func refresh() async -> Bool {
        guard let client else { return false }
        do {
            let pong = try await client.serverVersionAndCapabilities()
            runningVersion = pong.version
            capabilities = pong.capabilities
            capabilitiesKnown = true
        } catch {
            return false
        }
        guard capabilities?.serverUpdate == true else { return true }
        do {
            check = .loaded(try await client.updateCheck())
        } catch let error as APIError {
            check = error.code == ServerUpdateErrorCode.guestForbidden ? .forbidden : .failed(code: error.code)
            if check == .forbidden { return true }
        } catch {
            // Transport trouble: keep what was known.
            return false
        }
        let attempt: ServerUpdateAttempt?
        do { attempt = try await client.updateStatus() } catch { return false }
        pendingRestart = attempt?.outcome == .downloadedRestartRequired ? attempt : nil
        if let attempt, attempt.outcome == nil, case .idle = flow {
            // An update is already running (started from another device, or before a relaunch).
            missingBefore = ServerRequirement.current.missingFeatures(capabilities)
            flow = .running(attempt, restartLater: attempt.restartLater)
            startFollowing(.attempt(attempt.attemptID))
        }
        return true
    }

    /// The user confirmed: update to the build the card offered.
    func apply() {
        guard let latest, case .available(_, _, _, _, let restartLater, _) = card else { return }
        missingBefore = ServerRequirement.current.missingFeatures(capabilities)
        flow = .running(nil, restartLater: restartLater)
        Task { await start(buildID: latest.buildID, restartLater: restartLater) }
    }

    private func start(buildID: String, restartLater: Bool) async {
        guard let client else { return }
        // The attempt the server reports before this apply. If the apply's answer is lost, only
        // a different attempt for this build can be the one it started.
        let previous: ServerUpdateAttempt?
        do {
            previous = try await client.updateStatus()
        } catch let error as APIError {
            flow = .refused(code: error.code, message: error.message)
            return
        } catch {
            flow = .refused(code: ServerUpdateErrorCode.noAnswer,
                            message: ServerUpdateErrorCode.describe(ServerUpdateErrorCode.noAnswer, host: host))
            return
        }
        do {
            let attemptID = try await client.updateApply(buildID: buildID, restartLater: restartLater)
            startFollowing(.attempt(attemptID))
        } catch let error as APIError {
            flow = .refused(code: error.code, message: error.message)
        } catch {
            // The connection dropped before the answer. The attempt may have started.
            startFollowing(.started(buildID: buildID, previous: previous?.attemptID))
        }
    }

    /// Try again after a failure: check afresh, then update to what the check offers. A check
    /// that fails (or a server that doesn't answer) keeps the failed card, with the reason.
    func retry() {
        follow?.cancel()
        flow = .idle
        Task {
            let reached = await refresh()
            if case .available = card {
                apply()
            } else if let refusal = ServerUpdateFlow.retryRefusal(check: check, reached: reached, host: host) {
                flow = refusal
            }
        }
    }

    /// After the app lost track: look again without starting anything new.
    func lookAgain() {
        guard case .lostTrack(let attempt) = flow else { return }
        guard let target = attempt.map({ ServerUpdateTarget.attempt($0.attemptID) }) ?? target else { return }
        flow = .running(attempt, restartLater: attempt?.restartLater ?? false)
        startFollowing(target)
    }

    /// "Copy details": the attempt as the server reported it, or the refusal.
    var details: String {
        switch flow {
        case .finished(let attempt): return attempt.details(host: host)
        case .running(let attempt?, _), .lostTrack(let attempt?): return attempt.details(host: host)
        case .refused(let code, let message): return "herdr update on \(host)\nrefused: \(code)\nmessage: \(message)"
        case .idle, .running(.none, _), .lostTrack(.none): return "herdr update on \(host)"
        }
    }

    private func startFollowing(_ target: ServerUpdateTarget) {
        follow?.cancel()
        self.target = target
        let follower = follower
        follow = Task { [weak self] in
            let result = await follower.follow(
                target: target,
                client: { [weak self] in await self?.client },
                progress: { [weak self] attempt in
                    await self?.progressed(attempt)
                })
            await self?.followed(result)
        }
    }

    private func progressed(_ attempt: ServerUpdateAttempt) {
        guard case .running(_, let restartLater) = flow else { return }
        flow = .running(attempt, restartLater: restartLater)
    }

    private func followed(_ result: ServerUpdateFlow) async {
        if case .running = result { return }   // cancelled
        // `.idle`: the apply's answer was lost and no attempt of ours appeared, so it never
        // started. The refresh below shows what the server offers now.
        flow = result
        if case .finished(let attempt) = result,
           attempt.outcome == .updated || attempt.outcome == .updatedDiskStale {
            completedUpdates += 1
        }
        // What runs now, and what it can do: the Done card names what turned on.
        await refresh()
    }
}
