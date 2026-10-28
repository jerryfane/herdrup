import Foundation
import XCTest
@testable import HerdrKit

/// In-app herdr updates (herdrup#565, herdr#336): the `server.update_*` wire types as the server
/// serializes them, `ServerRequirement`, which card Settings › Machines shows, and following an
/// attempt across the handoff that drops the connection.
final class ServerUpdateTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func capabilities(_ json: String) throws -> ServerCapabilities {
        try decoder.decode(ServerCapabilities.self, from: Data(json.utf8))
    }

    /// A server that has everything this app release needs.
    private func current() throws -> ServerCapabilities {
        try capabilities(#"{"agent_groups":true,"agent_avatar":true,"agent_answer":true,"server_update":true}"#)
    }

    private func check(_ json: String) throws -> ServerUpdateCheck {
        try decoder.decode(ServerUpdateCheck.self, from: Data(json.utf8))
    }

    /// The answer the server gives for 0.9.3 with 0.9.5 published, live mode.
    private static let availableJSON = #"""
    {"type":"update_check",
     "running":{"version":"0.9.3-preview.2026-10-06-4c1e9a2b0000","commit":"4c1e9a2b00000000000000000000000000000000","build_id":"2026-10-06-4c1e9a2b0000","protocol":20,"endpoint_generation":1,"commit_time":1791280000},
     "latest":{"version":"0.9.5-preview.2026-10-28-8a02b8340000","commit":"8a02b83400000000000000000000000000000000","build_id":"2026-10-28-8a02b8340000","built_at":"2026-10-28T08:00:00Z","commit_time":1793200000,"notes":"Folders, stars, avatars.","size":39845888,"protocol":22,"endpoint_generation":1},
     "update_available":true,"mode":"live"}
    """#

    private func attempt(phase: ServerUpdateAttempt.Phase, outcome: ServerUpdateAttempt.Outcome? = nil,
                         done: Int64 = 0, total: Int64 = 0, panes: Int? = nil, restartLater: Bool = false,
                         id: String = "a1") -> ServerUpdateAttempt {
        ServerUpdateAttempt(attemptID: id, buildID: "2026-10-28-8a02b8340000",
                            from: "0.9.3-preview.2026-10-06-4c1e9a2b0000 (4c1e9a2b)",
                            to: "0.9.5-preview.2026-10-28-8a02b8340000 (8a02b834)",
                            phase: phase, bytesDone: done, bytesTotal: total, restartLater: restartLater,
                            outcome: outcome, message: outcome == nil ? nil : "detail", panes: panes)
    }

    // MARK: Wire

    func testUpdateCheckDecodesTheServersAnswer() throws {
        let decoded = try check(Self.availableJSON)
        XCTAssertEqual(decoded.running.version, "0.9.3-preview.2026-10-06-4c1e9a2b0000")
        XCTAssertEqual(decoded.running.buildID, "2026-10-06-4c1e9a2b0000")
        XCTAssertEqual(decoded.running.protocolVersion, 20)
        XCTAssertEqual(decoded.running.endpointGeneration, 1)
        XCTAssertEqual(decoded.running.commitTime, 1_791_280_000)
        let latest = try XCTUnwrap(decoded.latest)
        XCTAssertEqual(latest.buildID, "2026-10-28-8a02b8340000")
        XCTAssertEqual(latest.commitTime, 1_793_200_000)
        XCTAssertEqual(latest.size, 39_845_888)
        XCTAssertEqual(latest.notes, "Folders, stars, avatars.")
        XCTAssertEqual(latest.builtAt, "2026-10-28T08:00:00Z")
        XCTAssertTrue(decoded.updateAvailable)
        XCTAssertEqual(decoded.mode, .live)
        XCTAssertNil(decoded.reason)
    }

    /// A dev build reports only its version; no published build is `latest: null`.
    func testUpdateCheckDecodesADevBuildWithNothingPublished() throws {
        let decoded = try check(#"""
        {"type":"update_check","running":{"version":"0.9.5"},"latest":null,"update_available":false,
         "mode":"restart_required","reason":"systemd_main_process"}
        """#)
        XCTAssertNil(decoded.running.commit)
        XCTAssertNil(decoded.running.commitTime)
        XCTAssertNil(decoded.latest)
        XCTAssertEqual(decoded.mode, .restartRequired)
        XCTAssertEqual(decoded.reason, .systemdMainProcess)
    }

    func testEveryReasonDecodes() throws {
        let expected: [(String, ServerUpdateCheck.Reason)] = [
            ("windows", .windows), ("systemd_main_process", .systemdMainProcess),
            ("package_managed", .packageManaged), ("endpoint_generation_changed", .endpointGenerationChanged),
            ("no_live_handoff", .noLiveHandoff), ("install_dir_not_writable", .installDirNotWritable),
            ("launchd", .other("launchd")),
        ]
        for (wire, reason) in expected {
            let decoded = try check(#"{"running":{"version":"0.9.5"},"latest":null,"update_available":false,"mode":"unsupported","reason":"\#(wire)"}"#)
            XCTAssertEqual(decoded.reason, reason, wire)
        }
    }

    /// A mode this app does not know must not offer a button.
    func testUnknownModeReadsAsUnsupported() throws {
        let decoded = try check(#"{"running":{"version":"0.9.5"},"latest":null,"update_available":true,"mode":"later"}"#)
        XCTAssertEqual(decoded.mode, .unsupported)
    }

    func testUpdateStatusWithoutAnAttemptIsNil() throws {
        let decoded = try decoder.decode(ServerUpdateStatus.self,
                                         from: Data(#"{"type":"update_status","attempt":null}"#.utf8))
        XCTAssertNil(decoded.attempt)
    }

    func testUpdateStatusDecodesARunningAttempt() throws {
        let decoded = try decoder.decode(ServerUpdateStatus.self, from: Data(#"""
        {"type":"update_status","attempt":{"attempt_id":"u-1","build_id":"2026-10-28-8a02b8340000",
         "from":"0.9.3 (4c1e9a2b)","to":"0.9.5 (8a02b834)","phase":"downloading",
         "bytes_done":12582912,"bytes_total":39845888,"restart_later":false}}
        """#.utf8))
        let attempt = try XCTUnwrap(decoded.attempt)
        XCTAssertEqual(attempt.attemptID, "u-1")
        XCTAssertEqual(attempt.phase, .downloading)
        XCTAssertEqual(attempt.bytesDone, 12_582_912)
        XCTAssertEqual(attempt.bytesTotal, 39_845_888)
        XCTAssertFalse(attempt.restartLater)
        XCTAssertNil(attempt.outcome)
        XCTAssertNil(attempt.panes)
    }

    func testEveryPhaseAndOutcomeDecodes() throws {
        let phases: [(String, ServerUpdateAttempt.Phase)] = [
            ("downloading", .downloading), ("verifying", .verifying), ("testing", .testing),
            ("switching", .switching), ("confirming", .confirming), ("installing", .installing),
        ]
        let outcomes: [(String, ServerUpdateAttempt.Outcome)] = [
            ("updated", .updated), ("updated_disk_stale", .updatedDiskStale), ("rolled_back", .rolledBack),
            ("failed_no_change", .failedNoChange), ("needs_attention", .needsAttention),
            ("downloaded_restart_required", .downloadedRestartRequired),
        ]
        for (phaseWire, phase) in phases {
            for (outcomeWire, outcome) in outcomes {
                let decoded = try decoder.decode(ServerUpdateAttempt.self, from: Data(#"""
                {"attempt_id":"u","build_id":"b","from":"f","to":"t","phase":"\#(phaseWire)",
                 "bytes_done":0,"bytes_total":0,"outcome":"\#(outcomeWire)","message":"m","panes":14}
                """#.utf8))
                XCTAssertEqual(decoded.phase, phase)
                XCTAssertEqual(decoded.outcome, outcome)
                XCTAssertEqual(decoded.outcome?.wire, outcomeWire)
                XCTAssertEqual(decoded.panes, 14)
            }
        }
    }

    func testServerUpdateCapabilityDecodes() throws {
        XCTAssertTrue(try capabilities(#"{"server_update":true}"#).serverUpdate)
        XCTAssertFalse(try capabilities(#"{"agent_groups":true}"#).serverUpdate)
    }

    // MARK: Client

    func testUpdateApplySendsTheConfirmedBuildAndReturnsTheAttempt() async throws {
        let transport = RecordingTransport(reply: #"{"id":"x","result":{"type":"update_apply","attempt_id":"u-7"}}"#)
        let client = HerdrClient(transport: transport)
        let attemptID = try await client.updateApply(buildID: "2026-10-28-8a02b8340000", restartLater: true)
        XCTAssertEqual(attemptID, "u-7")
        let sent = try transport.last()
        XCTAssertEqual(sent.method, "server.update_apply")
        XCTAssertEqual(sent.params["build_id"] as? String, "2026-10-28-8a02b8340000")
        XCTAssertEqual(sent.params["restart_later"] as? Bool, true)
    }

    func testUpdateApplyRefusalSurfacesTheServersCode() async throws {
        let client = HerdrClient(transport: RecordingTransport.error(code: "update_build_mismatch", message: "manifest changed"))
        do {
            try await client.updateApply(buildID: "old", restartLater: false)
            XCTFail("a refused apply must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, ServerUpdateErrorCode.buildMismatch)
        }
    }

    func testUpdateCheckAndStatusUseTheirMethods() async throws {
        let transport = RecordingTransport(replies: [
            "server.update_check": #"{"id":"x","result":\#(Self.availableJSON)}"#,
            "server.update_status": #"{"id":"x","result":{"type":"update_status","attempt":null}}"#,
        ])
        let client = HerdrClient(transport: transport)
        let checked = try await client.updateCheck()
        XCTAssertEqual(checked.latest?.buildID, "2026-10-28-8a02b8340000")
        let status = try await client.updateStatus()
        XCTAssertNil(status)
        XCTAssertEqual(transport.requests.map(\.method), ["server.update_check", "server.update_status"])
    }

    // MARK: ServerRequirement

    func testMissingFeaturesAreListedInRequirementOrder() throws {
        let requirement = ServerRequirement(minCommitTime: 100, features: [.agentGroups, .agentAvatar, .serverUpdate])
        XCTAssertEqual(requirement.missingFeatures(try capabilities(#"{"agent_avatar":true}"#)),
                       [.agentGroups, .serverUpdate])
        XCTAssertEqual(requirement.missingFeatures(nil), [.agentGroups, .agentAvatar, .serverUpdate])
        XCTAssertEqual(requirement.missingFeatures(try current()), [])
    }

    func testAServerMissingAFeatureDoesNotMeetTheRequirement() throws {
        let requirement = ServerRequirement(minCommitTime: 100, features: [.agentGroups, .serverUpdate])
        XCTAssertFalse(requirement.isMet(by: try capabilities(#"{"server_update":true}"#), commitTime: 200))
        XCTAssertTrue(requirement.isMet(by: try current(), commitTime: 200))
    }

    /// Every feature but an older commit: still older than the app needs.
    func testAnOlderCommitDoesNotMeetTheRequirement() throws {
        let requirement = ServerRequirement(minCommitTime: 100, features: [.serverUpdate])
        XCTAssertFalse(requirement.isMet(by: try current(), commitTime: 99))
        XCTAssertTrue(requirement.isMet(by: try current(), commitTime: 100))
    }

    /// A dev build reports no commit time and is judged by its features.
    func testABuildWithoutACommitTimeIsJudgedByFeatures() throws {
        let requirement = ServerRequirement(minCommitTime: 100, features: [.serverUpdate])
        XCTAssertTrue(requirement.isMet(by: try current(), commitTime: nil))
        XCTAssertFalse(requirement.isMet(by: nil, commitTime: nil))
    }

    func testAPublishedBuildMeetsTheRequirementByCommitTimeOnly() {
        let requirement = ServerRequirement(minCommitTime: 100, features: [.serverUpdate])
        XCTAssertTrue(requirement.isMet(by: .init(version: "0.9.5", commit: "c", buildID: "b", commitTime: 100)))
        XCTAssertFalse(requirement.isMet(by: .init(version: "0.9.5", commit: "c", buildID: "b", commitTime: 99)))
        XCTAssertFalse(requirement.isMet(by: .init(version: "0.9.5", commit: "c", buildID: "b")))
    }

    /// This release needs folders (herdr 8a02b834, committed 2026-10-27) and one-tap updates.
    func testThisReleasesRequirement() {
        XCTAssertEqual(ServerRequirement.current.minCommitTime, 1_793_108_998)
        XCTAssertTrue(ServerRequirement.current.features.contains(.agentGroups))
        XCTAssertTrue(ServerRequirement.current.features.contains(.serverUpdate))
    }

    // MARK: Which card

    private func card(_ caps: ServerCapabilities?, known: Bool = true, check: ServerUpdateCheckState,
                      flow: ServerUpdateFlow = .idle, pending: ServerUpdateAttempt? = nil,
                      missingBefore: [ServerFeature] = []) -> ServerUpdateCard {
        ServerUpdateCard.make(capabilities: caps, capabilitiesKnown: known, check: check, flow: flow,
                              pendingRestart: pending, missingBefore: missingBefore,
                              requirement: ServerRequirement(minCommitTime: 1_793_108_998,
                                                             features: [.agentGroups, .agentAvatar, .serverUpdate]))
    }

    /// The server predates `server_update`: the card with the commands to run once by hand.
    func testAServerWithoutServerUpdateGetsTheTooOldCard() throws {
        XCTAssertEqual(card(try capabilities(#"{"agent_groups":true}"#), check: .unknown), .tooOld)
        XCTAssertEqual(card(nil, check: .unknown), .tooOld)
    }

    /// Before the ping answers nothing is known, and nothing is claimed.
    func testNoCardBeforeTheCapabilitiesAreKnown() {
        XCTAssertEqual(card(nil, known: false, check: .unknown), .hidden)
    }

    func testAnOldServerWithABuildPublishedGetsTheAvailableCard() throws {
        let caps = try capabilities(#"{"server_update":true}"#)
        let result = card(caps, check: .loaded(try check(Self.availableJSON)))
        XCTAssertEqual(result, .available(old: "0.9.3", new: "0.9.5", missing: [.agentGroups, .agentAvatar],
                                          notes: "Folders, stars, avatars.", restartLater: false, reason: nil))
    }

    func testRestartRequiredOffersTheDownloadToFinishOnRestart() throws {
        let json = Self.availableJSON.replacingOccurrences(of: #""mode":"live""#,
                                                           with: #""mode":"restart_required","reason":"systemd_main_process""#)
        guard case .available(_, _, _, _, let restartLater, let reason) = card(try current(), check: .loaded(try check(json))) else {
            return XCTFail("restart_required must still offer the build")
        }
        XCTAssertTrue(restartLater)
        XCTAssertEqual(reason, .systemdMainProcess)
    }

    func testAPackageManagedInstallGetsNoButton() throws {
        let json = Self.availableJSON.replacingOccurrences(of: #""mode":"live""#,
                                                           with: #""mode":"unsupported","reason":"package_managed""#)
        XCTAssertEqual(card(try current(), check: .loaded(try check(json))), .unsupported(reason: .packageManaged))
    }

    /// Older than the app needs, but nothing new enough has been published.
    func testNoPublishedBuildMeetsTheRequirement() throws {
        let stale = Self.availableJSON.replacingOccurrences(of: #""commit_time":1793200000"#,
                                                            with: #""commit_time":1792000000"#)
        XCTAssertEqual(card(try capabilities(#"{"server_update":true}"#), check: .loaded(try check(stale))),
                       .unpublished(old: "0.9.3"))
        let none = #"{"running":{"version":"0.9.3","commit_time":1791280000},"latest":null,"update_available":false,"mode":"live"}"#
        XCTAssertEqual(card(try current(), check: .loaded(try check(none))), .unpublished(old: "0.9.3"))
    }

    /// Up to date with what the app needs and nothing newer: no card.
    func testACurrentServerWithNothingNewShowsNoCard() throws {
        let json = #"{"running":{"version":"0.9.5","commit_time":1793200000},"latest":null,"update_available":false,"mode":"live"}"#
        XCTAssertEqual(card(try current(), check: .loaded(try check(json))), .hidden)
    }

    /// A non-owner is refused `server.update_check` (`guest_forbidden`): no card at all, even
    /// for a server too old to update itself, and even mid-update.
    func testAForbiddenCheckHidesEveryCard() throws {
        XCTAssertEqual(card(try capabilities(#"{"server_update":true}"#), check: .forbidden), .hidden)
        XCTAssertEqual(card(try current(), check: .forbidden, flow: .running(nil, restartLater: false)), .hidden)
    }

    func testAFailedCheckOffersNothing() throws {
        XCTAssertEqual(card(try current(), check: .failed(code: ServerUpdateErrorCode.signatureInvalid)), .hidden)
    }

    func testUpdatingMapsPhasesToTheThreeSteps() throws {
        let caps = try current()
        let loaded = ServerUpdateCheckState.loaded(try check(Self.availableJSON))
        XCTAssertEqual(card(caps, check: loaded, flow: .running(nil, restartLater: false)),
                       .updating(step: 0, fraction: 0, phase: .downloading, bytesDone: 0, bytesTotal: 0, restartLater: false))
        let downloading = attempt(phase: .downloading, done: 12 << 20, total: 38 << 20)
        guard case .updating(0, let fraction, .downloading, _, _, false) =
                card(caps, check: loaded, flow: .running(downloading, restartLater: false)) else {
            return XCTFail("downloading is step 0")
        }
        XCTAssertEqual(fraction, 12.0 / 38.0, accuracy: 0.0001)
        for (phase, step) in [(ServerUpdateAttempt.Phase.verifying, 1), (.testing, 1), (.switching, 2),
                              (.confirming, 2), (.installing, 2)] {
            guard case .updating(let got, _, _, _, _, _) =
                    card(caps, check: loaded, flow: .running(attempt(phase: phase), restartLater: false)) else {
                return XCTFail("\(phase) is still updating")
            }
            XCTAssertEqual(got, step, "\(phase)")
        }
    }

    func testDoneSaysWhatTurnedOn() throws {
        let result = card(try current(), check: .loaded(try check(Self.availableJSON)),
                          flow: .finished(attempt(phase: .confirming, outcome: .updated, panes: 14)),
                          missingBefore: [.agentGroups, .agentAvatar, .serverUpdate])
        XCTAssertEqual(result, .done(new: "0.9.5", panes: 14, nowOn: [.agentGroups, .agentAvatar], diskStale: false))
    }

    func testADownloadThatStoppedSaysWhere() throws {
        let failed = attempt(phase: .downloading, outcome: .failedNoChange, done: 21 << 20, total: 38 << 20)
        XCTAssertEqual(card(try current(), check: .unknown, flow: .finished(failed)),
                       .failed(old: "0.9.3", failure: .downloadStopped(bytesDone: 21 << 20, bytesTotal: 38 << 20),
                               canRetry: true))
    }

    /// A rolled-back build is not offered again on this machine, so it cannot be retried.
    func testRollbackAndNeedsAttentionCannotBeRetried() throws {
        XCTAssertEqual(card(try current(), check: .unknown, flow: .finished(attempt(phase: .confirming, outcome: .rolledBack))),
                       .failed(old: "0.9.3", failure: .rolledBack(message: "detail"), canRetry: false))
        XCTAssertEqual(card(try current(), check: .unknown, flow: .finished(attempt(phase: .confirming, outcome: .needsAttention))),
                       .failed(old: "0.9.3", failure: .needsAttention(message: "detail"), canRetry: false))
    }

    func testARefusedApplyIsAFailureWithNothingChanged() throws {
        let loaded = ServerUpdateCheckState.loaded(try check(Self.availableJSON))
        XCTAssertEqual(card(try current(), check: loaded, flow: .refused(code: "update_preflight_failed", message: "disk")),
                       .failed(old: "0.9.3", failure: .refused(code: "update_preflight_failed", message: "disk"), canRetry: true))
        guard case .failed(_, _, false) = card(try current(), check: loaded,
                                               flow: .refused(code: "update_unsupported_install", message: "brew")) else {
            return XCTFail("an unsupported install cannot be retried")
        }
    }

    func testDownloadedForRestartShowsTheRestartCardUntilTheServerRestarts() throws {
        let caps = try current()
        let downloaded = attempt(phase: .installing, outcome: .downloadedRestartRequired, restartLater: true)
        let json = Self.availableJSON.replacingOccurrences(of: #""mode":"live""#,
                                                           with: #""mode":"restart_required","reason":"systemd_main_process""#)
        let stillOld = ServerUpdateCheckState.loaded(try check(json))
        XCTAssertEqual(card(caps, check: stillOld, flow: .finished(downloaded)),
                       .restartPending(new: "0.9.5", reason: .systemdMainProcess))
        // Found on a later connect, while the old build still runs.
        XCTAssertEqual(card(caps, check: stillOld, pending: downloaded),
                       .restartPending(new: "0.9.5", reason: .systemdMainProcess))
        // After the restart the running build is the downloaded one: no card.
        let restarted = #"{"running":{"version":"0.9.5","build_id":"2026-10-28-8a02b8340000","commit_time":1793200000},"latest":null,"update_available":false,"mode":"live"}"#
        XCTAssertEqual(card(caps, check: .loaded(try check(restarted)), pending: downloaded), .hidden)
    }

    // MARK: Badge

    func testTheBadgeClearsOnceSeenAndReturnsForANewerVersion() {
        let available = ServerUpdateCard.available(old: "0.9.3", new: "0.9.5", missing: [], notes: nil,
                                                   restartLater: false, reason: nil)
        XCTAssertTrue(available.showsBadge(seen: nil))
        XCTAssertFalse(available.showsBadge(seen: available.badgeKey))
        let newer = ServerUpdateCard.available(old: "0.9.3", new: "0.9.6", missing: [], notes: nil,
                                               restartLater: false, reason: nil)
        XCTAssertTrue(newer.showsBadge(seen: available.badgeKey))
    }

    func testAPendingRestartKeepsTheBadge() {
        let pending = ServerUpdateCard.restartPending(new: "0.9.5", reason: nil)
        XCTAssertTrue(pending.showsBadge(seen: pending.badgeKey))
    }

    func testNothingToActOnHasNoBadge() {
        XCTAssertFalse(ServerUpdateCard.hidden.showsBadge(seen: nil))
        XCTAssertFalse(ServerUpdateCard.done(new: "0.9.5", panes: 14, nowOn: [], diskStale: false).showsBadge(seen: nil))
        XCTAssertFalse(ServerUpdateCard.updating(step: 0, fraction: 0, phase: .downloading, bytesDone: 0,
                                                 bytesTotal: 0, restartLater: false).showsBadge(seen: nil))
        XCTAssertTrue(ServerUpdateCard.tooOld.showsBadge(seen: nil))
        XCTAssertFalse(ServerUpdateCard.tooOld.showsBadge(seen: ServerUpdateCard.tooOld.badgeKey))
    }

    // MARK: Versions and details

    func testVersionLabels() {
        XCTAssertEqual(ServerUpdateVersion.base("0.9.6-preview.2026-10-28-0123456789ab"), "0.9.6")
        XCTAssertEqual(ServerUpdateVersion.base("0.9.5 (8a02b834)"), "0.9.5")
        let different = ServerUpdateVersion.labels(old: "0.9.3-preview.2026-10-06-aa", new: "0.9.5-preview.2026-10-28-bb")
        XCTAssertEqual(different.old, "0.9.3")
        XCTAssertEqual(different.new, "0.9.5")
        // Previews often carry the same version: the dates tell them apart.
        let same = ServerUpdateVersion.labels(old: "0.9.5-preview.2026-10-06-aa", new: "0.9.5-preview.2026-10-28-bb")
        XCTAssertEqual(same.old, "0.9.5 of 2026-10-06")
        XCTAssertEqual(same.new, "0.9.5 of 2026-10-28")
    }

    func testCopyDetailsCarriesEverythingToLookInto() {
        let text = attempt(phase: .downloading, outcome: .failedNoChange, done: 21, total: 38).details(host: "mac-mini")
        for part in ["mac-mini", "attempt: a1", "build: 2026-10-28-8a02b8340000", "phase: downloading",
                     "bytes: 21 of 38", "outcome: failed_no_change", "message: detail"] {
            XCTAssertTrue(text.contains(part), "missing \(part) in \(text)")
        }
    }

    // MARK: Following an attempt across the handoff

    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Result<String, Error>]
        private(set) var asked = 0
        init(_ replies: [Result<String, Error>]) { self.replies = replies }
        func next() throws -> String {
            try lock.withLock {
                asked += 1
                return try (replies.count > 1 ? replies.removeFirst() : replies[0]).get()
            }
        }
    }

    private struct Dropped: Error {}

    private static func status(_ phase: String, outcome: String? = nil, id: String = "u-1") -> Result<String, Error> {
        let tail = outcome.map { #","outcome":"\#($0)","panes":14"# } ?? ""
        return .success(#"{"id":"x","result":{"type":"update_status","attempt":{"attempt_id":"\#(id)","build_id":"b","from":"0.9.3 (4c1e9a2b)","to":"0.9.5 (8a02b834)","phase":"\#(phase)","bytes_done":1,"bytes_total":2\#(tail)}}}"#)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [ServerUpdateAttempt.Phase] = []
        func add(_ phase: ServerUpdateAttempt.Phase) { lock.withLock { phases.append(phase) } }
        var all: [ServerUpdateAttempt.Phase] { lock.withLock { phases } }
    }

    /// The handoff drops the connection: the polls that fail in between must not end the follow.
    func testFollowingSurvivesTheDroppedConnection() async throws {
        let script = Script([Self.status("downloading"), Self.status("switching"), .failure(Dropped()),
                             .failure(Dropped()), .failure(Dropped()), Self.status("confirming"),
                             Self.status("confirming", outcome: "updated")])
        let client = HerdrClient(transport: RecordingTransport { _, _ in try script.next() })
        let seen = Seen()
        let result = await ServerUpdateFollower(intervalNanoseconds: 0, maxSilentPolls: 5)
            .follow(attemptID: "u-1", client: { client }, sleep: { _ in }, progress: { seen.add($0.phase) })
        guard case .finished(let attempt) = result else { return XCTFail("expected an outcome, got \(result)") }
        XCTAssertEqual(attempt.outcome, .updated)
        XCTAssertEqual(attempt.panes, 14)
        XCTAssertEqual(seen.all, [.downloading, .switching, .confirming, .confirming])
    }

    /// A reconnect replaces the client: the follow carries on with the new one and keeps the
    /// attempt it had.
    func testFollowingMovesToTheReconnectedClient() async throws {
        let dead = HerdrClient(transport: RecordingTransport { _, _ in throw Dropped() })
        let fresh = HerdrClient(transport: RecordingTransport { _, _ in
            try Self.status("confirming", outcome: "updated").get()
        })
        let polls = Script([.success("dead"), .success("dead"), .success("fresh")])
        let result = await ServerUpdateFollower(intervalNanoseconds: 0, maxSilentPolls: 5)
            .follow(attemptID: "u-1", client: { (try? polls.next()) == "fresh" ? fresh : dead },
                    sleep: { _ in }, progress: { _ in })
        guard case .finished(let attempt) = result else { return XCTFail("expected an outcome, got \(result)") }
        XCTAssertEqual(attempt.outcome, .updated)
    }

    func testFollowingGivesUpOnASilentServerAndKeepsWhatItKnew() async throws {
        let script = Script([Self.status("switching"), .failure(Dropped())])
        let client = HerdrClient(transport: RecordingTransport { _, _ in try script.next() })
        let result = await ServerUpdateFollower(intervalNanoseconds: 0, maxSilentPolls: 3)
            .follow(attemptID: "u-1", client: { client }, sleep: { _ in }, progress: { _ in })
        guard case .lostTrack(let last) = result else { return XCTFail("expected lostTrack, got \(result)") }
        XCTAssertEqual(last?.phase, .switching)
        XCTAssertEqual(script.asked, 4)
    }

    /// Another attempt's status is not this one's progress.
    func testFollowingIgnoresAnotherAttempt() async throws {
        let script = Script([Self.status("confirming", outcome: "updated", id: "other")])
        let client = HerdrClient(transport: RecordingTransport { _, _ in try script.next() })
        let result = await ServerUpdateFollower(intervalNanoseconds: 0, maxSilentPolls: 3)
            .follow(attemptID: "u-1", client: { client }, sleep: { _ in }, progress: { _ in })
        guard case .lostTrack(let last) = result else { return XCTFail("expected lostTrack, got \(result)") }
        XCTAssertNil(last)
    }
}
