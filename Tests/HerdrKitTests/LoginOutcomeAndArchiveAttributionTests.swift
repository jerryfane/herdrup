import XCTest
@testable import HerdrKit

/// Two guards for the sign-in sheet and the archive action.
///
/// The sign-in sheet HIDES the input box while it waits, so the classifier is what decides
/// whether the user ever gets it back. Both directions matter: missing a failure strands
/// them on a spinner, and inventing one throws away a sign-in that was still working.
final class LoginOutcomeAndArchiveAttributionTests: XCTestCase {

    // MARK: - sign-in outcome classification

    func testRecognisesACompletedSignIn() {
        XCTAssertEqual(claudeLoginOutcome(from: "You are now logged in."), .signedIn)
        XCTAssertEqual(claudeLoginOutcome(from: "Login successful!"), .signedIn)
        XCTAssertEqual(claudeLoginOutcome(from: "AUTHENTICATION SUCCESSFUL"), .signedIn,
                       "matching must be case-insensitive; terminals shout")
    }

    func testRecognisesARejectedCode() {
        XCTAssertEqual(claudeLoginOutcome(from: "Invalid code, please try again"), .failed)
        XCTAssertEqual(claudeLoginOutcome(from: "Authentication failed"), .failed)
        XCTAssertEqual(claudeLoginOutcome(from: "That code expired"), .failed)
    }

    /// Ordinary terminal output must stay pending. The pane carries the shell prompt, the
    /// command line the user typed, and the harness's own banner — none of that is an
    /// outcome, and treating it as one would end the flow before it started.
    func testOrdinaryOutputStaysPending() {
        let noise = """
        root@box ~ # env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='/root/.claude' claude auth login
        Visit https://claude.ai/oauth/authorize?code=xyz to continue.
        Paste the code here:
        """
        XCTAssertEqual(claudeLoginOutcome(from: noise), .pending)
        XCTAssertEqual(claudeLoginOutcome(from: ""), .pending)
    }

    /// A bare "expired" appears in benign copy. Matching it would hand the input back
    /// during a sign-in that is still fine.
    func testBenignExpiryCopyIsNotAFailure() {
        XCTAssertEqual(claudeLoginOutcome(from: "Your token expires in 30 days."), .pending)
    }

    /// Success wins over an earlier failed attempt in the same scrollback — the pane text
    /// is cumulative, so a retry that eventually succeeds must read as success.
    func testSuccessAfterAnEarlierFailureReadsAsSuccess() {
        let both = "Invalid code, please try again\nPaste the code here:\nYou are now logged in."
        XCTAssertEqual(claudeLoginOutcome(from: both), .signedIn)
    }

    /// THE RETRY CASE. The pane buffer is cumulative, so a rejected first attempt leaves
    /// its rejection in the text permanently. The sheet therefore judges failure only on
    /// output produced AFTER the submission — this pins the classifier half of that: given
    /// only the fresh output, a good retry must NOT read as failed even though the full
    /// buffer still contains the earlier rejection.
    func testFreshOutputOfAGoodRetryIsNotAFailure() {
        let wholeBuffer = """
        Invalid code, please try again
        Paste the code here:
        """
        // What the sheet passes in is the slice after the baseline, not the whole buffer.
        let freshOutput = "\nPaste the code here:\n"
        XCTAssertEqual(claudeLoginOutcome(from: wholeBuffer), .failed,
                       "the cumulative buffer does still contain the old rejection")
        XCTAssertEqual(claudeLoginOutcome(from: freshOutput), .pending,
                       "a retry judged on fresh output only must not inherit the old failure")
    }

    // MARK: - archive attribution

    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            return #"{"id":"x","result":{"type":"agent_info","agent":{"pane_id":"w1:p1"}}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// An archive from the app must say who did it and why. Without both, the daemon
    /// records `by:"api"` and no reason — the same shape it writes for a pane that merely
    /// died, which is what made a deliberate archive indistinguishable from bookkeeping.
    func testArchiveSendsActorAndReason() async throws {
        let t = CapturingTransport()
        _ = try await HerdrClient(transport: t).archiveAgent(
            target: "w1:p1", reason: appArchiveReason, by: appArchiveActor)

        XCTAssertTrue(t.lastRequest.contains(#""by":"herdrup""#), t.lastRequest)
        XCTAssertTrue(t.lastRequest.contains(#""reason":"user action""#), t.lastRequest)
    }

    /// Omitting them must send NO such keys — an older daemon and every existing caller
    /// keep the exact bytes they had before.
    func testArchiveOmitsAttributionWhenNotGiven() async throws {
        let t = CapturingTransport()
        _ = try await HerdrClient(transport: t).archiveAgent(target: "w1:p1")

        XCTAssertFalse(t.lastRequest.contains("\"by\""), "nil by must be omitted, not null")
        XCTAssertFalse(t.lastRequest.contains("\"reason\""), "nil reason must be omitted, not null")
        XCTAssertFalse(t.lastRequest.contains("\"force\""), "false force stays omitted")
    }

    /// The constants are the fleet's matching key, so pin them: tooling that reads the
    /// archived block distinguishes a decision from bookkeeping by these exact strings.
    func testAttributionConstantsAreStable() {
        XCTAssertEqual(appArchiveActor, "herdrup")
        XCTAssertEqual(appArchiveReason, "user action")
    }
}
