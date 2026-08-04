import XCTest
@testable import HerdrKit

private func makeAgent(pane: String, agent: String?, hasComposer: Bool) throws -> AgentInfo {
    var fields = ["\"pane_id\":\"\(pane)\""]
    if let agent { fields.append("\"agent\":\"\(agent)\"") }
    if hasComposer { fields.append("\"composer\":{\"state\":\"unknown\"}") }
    let json = "{\"id\":\"x\",\"result\":{\"agents\":[{\(fields.joined(separator: ","))}]}}"
    return try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]
}

final class InputRouterTests: XCTestCase {
    let router = InputRouter()

    func testAgentPaneWithComposerUsesIntentMode() throws {
        let a = try makeAgent(pane: "p1", agent: "claude", hasComposer: true)
        XCTAssertEqual(router.mode(for: a), .intent)
    }

    /// A shell pane must not be treated as promptable — that is how text ends up
    /// pasted somewhere it was never meant to go.
    func testPaneWithoutAgentFallsBackToRawKeys() throws {
        XCTAssertEqual(router.mode(for: try makeAgent(pane: "p1", agent: nil, hasComposer: true)), .rawKeys)
        XCTAssertEqual(router.mode(for: try makeAgent(pane: "p1", agent: "claude", hasComposer: false)), .rawKeys)
    }

    func testTextBecomesAPromptInIntentMode() {
        XCTAssertEqual(
            router.plan(action: .submitText("ship it"), pane: "p1", mode: .intent),
            .prompt(pane: "p1", text: "ship it")
        )
    }

    /// AXIS (the new-agent pre-fill invariant): a pending pre-filled task delivers
    /// as a PROMPT only when the agent is promptable, and WAITS otherwise — it must
    /// never resolve to a normal (rawKeys-capable) reply. Both review witnesses
    /// flagged that a pre-fill typed into a booting shell can be executed by a later
    /// Return, so `.waitForComposer` (not `.normalReply`) for the not-ready case is
    /// the security-bearing assertion. (Mutation guard: returning `.normalReply`
    /// when not promptable KILLs the middle assertion.)
    func testPendingPrefillNeverFallsToRawReply() {
        XCTAssertEqual(router.prefillDelivery(pendingPrefill: true, isPromptable: true), .prompt)
        XCTAssertEqual(router.prefillDelivery(pendingPrefill: true, isPromptable: false), .waitForComposer)
        // No pre-fill pending → the usual reply routing, regardless of readiness.
        XCTAssertEqual(router.prefillDelivery(pendingPrefill: false, isPromptable: true), .normalReply)
        XCTAssertEqual(router.prefillDelivery(pendingPrefill: false, isPromptable: false), .normalReply)
    }

    /// herdr-ios#3: a shell pane must be typeable. Refusing left those panes
    /// unable to receive a single character, so "keys elsewhere" was fictional.
    func testShellPanesAcceptLiteralTyping() {
        XCTAssertEqual(
            router.plan(action: .submitText("ls -la"), pane: "p1", mode: .rawKeys),
            .text(pane: "p1", "ls -la")
        )
    }

    /// The safety property that makes typing into a shell acceptable: text
    /// lands, nothing runs. Enter must remain a separate deliberate action, so
    /// no plan for text may carry a submission.
    func testTypingIntoAShellNeverSubmits() {
        guard case .text(_, let sent) = router.plan(
            action: .submitText("rm -rf /tmp/x"), pane: "p1", mode: .rawKeys
        ) else { return XCTFail("expected literal text") }
        XCTAssertFalse(sent.contains("\n"), "typed text must not carry a newline")
        XCTAssertFalse(sent.contains("\r"), "typed text must not carry a carriage return")
        // Submitting is a separate, explicit key.
        XCTAssertEqual(
            router.plan(action: .key("Enter"), pane: "p1", mode: .rawKeys),
            .keys(pane: "p1", ["Enter"])
        )
    }

    /// AXIS: a newline in rawKeys text WOULD execute (send_text writes it to the
    /// pty and the shell runs the line). The pre-existing "never submits" test
    /// used a payload with no newline, so it proved nothing about this — it
    /// survived because the input could not have submitted either way. These pass
    /// CR/LF explicitly and require a REFUSAL, never a `.text` reaching the pane.
    func testRawKeysRefusesNewlineBearingText() {
        for payload in ["deploy\n", "cmd\r", "a\r\nb", "\n", "ok\n "] {
            guard case .refused = router.plan(action: .submitText(payload), pane: "p1", mode: .rawKeys) else {
                return XCTFail("newline-bearing rawKeys text was not refused: \(payload.debugDescription)")
            }
        }
    }

    /// The guarantee stated positively over both submitting and non-submitting
    /// inputs: NO rawKeys `.text` plan may carry a newline into pane.send_text.
    func testNoRawKeysTextPlanCarriesANewline() {
        for payload in ["ls -la", "deploy\n", "x\r", "safe input"] {
            if case .text(_, let sent) = router.plan(action: .submitText(payload), pane: "p1", mode: .rawKeys) {
                XCTAssertFalse(sent.contains("\n") || sent.contains("\r"),
                               "a .text plan carried a newline that would execute: \(sent.debugDescription)")
            }
        }
    }

    /// Agent panes still route text as a prompt, not as literal keystrokes.
    func testAgentPanesStillUseIntent() {
        XCTAssertEqual(
            router.plan(action: .submitText("ship it"), pane: "p1", mode: .intent),
            .prompt(pane: "p1", text: "ship it")
        )
    }

    func testEmptyAndWhitespacePromptsAreRefused() {
        for text in ["", "   ", "\n\t "] {
            guard case .refused = router.plan(action: .submitText(text), pane: "p1", mode: .intent) else {
                return XCTFail("expected refusal for \(text.debugDescription)")
            }
        }
    }

    func testNavigationKeysWorkInBothModes() {
        for mode in [InputMode.intent, .rawKeys] {
            XCTAssertEqual(router.plan(action: .key("Up"), pane: "p1", mode: mode), .keys(pane: "p1", ["Up"]))
            XCTAssertEqual(router.plan(action: .key("Enter"), pane: "p1", mode: mode), .keys(pane: "p1", ["Enter"]))
        }
    }

    func testKeyNamesAreCaseInsensitiveButCanonicalised() {
        XCTAssertEqual(router.plan(action: .key("enter"), pane: "p1", mode: .intent), .keys(pane: "p1", ["Enter"]))
        XCTAssertEqual(router.plan(action: .key("ESCAPE"), pane: "p1", mode: .intent), .keys(pane: "p1", ["Escape"]))
    }

    /// Allowlist, not passthrough — refusing unknown keys is the point (herdr#21).
    func testUnknownKeysAreRefused() {
        for key in ["Ctrl+C", "F13", "Meta", "\u{1B}[A", "rm -rf"] {
            guard case .refused = router.plan(action: .key(key), pane: "p1", mode: .intent) else {
                return XCTFail("expected refusal for \(key)")
            }
        }
    }

    func testAllowlistDoesNotAdmitChordsOrControlSequences() {
        XCTAssertNil(InputRouter.canonicalKey("Ctrl+U"))
        XCTAssertNil(InputRouter.canonicalKey(""))
        XCTAssertNotNil(InputRouter.canonicalKey("PageDown"))
    }
}

final class PendingSubmissionTests: XCTestCase {
    func testPendingSubmissionIsVisuallyDistinct() {
        let p = PendingSubmission(pane: "p1", text: "hello")
        XCTAssertTrue(p.needsPendingTreatment, "unconfirmed text must not read as delivered")
        XCTAssertFalse(p.isStrandedDraft)
    }

    /// WrittenToPty and Submitted are different facts. Collapsing them would
    /// hide exactly the stranded-draft state herdr#18/#26 are about.
    func testWrittenToPtyIsNotTreatedAsSubmitted() {
        var p = PendingSubmission(pane: "p1", text: "hello")
        p.state = .writtenToPty
        XCTAssertTrue(p.isStrandedDraft, "bytes in the composer with no turn is its own state")
        XCTAssertTrue(p.needsPendingTreatment, "written != submitted; must not read as delivered")
    }

    func testOnlySubmittedClearsPendingTreatment() {
        var p = PendingSubmission(pane: "p1", text: "hello")
        p.state = .submitted
        XCTAssertFalse(p.needsPendingTreatment)
        XCTAssertFalse(p.isStrandedDraft)
    }

    func testFailureIsNotAStrandedDraft() {
        var p = PendingSubmission(pane: "p1", text: "hello")
        p.state = .failed("agent_prompt_stalled")
        XCTAssertFalse(p.isStrandedDraft)
        XCTAssertTrue(p.needsPendingTreatment)
    }
}

/// Read-only live checks.
///
/// These deliberately do NOT send prompts or keys. Every pane on this box hosts
/// a working fleet agent, and injecting input would disrupt real sessions. Input
/// delivery against a live pane needs a scratch pane and is left for v1b, where
/// it can be driven from a device against a pane created for the purpose.
final class LiveInputTests: XCTestCase {
    func testModeIsClassifiableForEveryLivePane() async throws {
        let path = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: path), "no live herdr server")

        let agents = try await HerdrClient(transport: UnixSocketTransport(path: path)).agentList()
        XCTAssertFalse(agents.isEmpty)
        let router = InputRouter()
        // Every real pane must classify without crashing, and agent-hosting panes
        // on this fleet should reach intent mode — if none do, the classifier is
        // too strict to be useful.
        let intentCount = agents.filter { router.mode(for: $0) == .intent }.count
        XCTAssertGreaterThan(intentCount, 0, "no live pane classified as promptable")
    }
}
