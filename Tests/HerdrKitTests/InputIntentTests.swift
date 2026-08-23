import XCTest
@testable import HerdrKit

private func makeAgent(pane: String, agent: String?, hasComposer: Bool) throws -> AgentInfo {
    var fields = ["\"pane_id\":\"\(pane)\""]
    if let agent { fields.append("\"agent\":\"\(agent)\"") }
    if hasComposer { fields.append("\"composer\":{\"state\":\"unknown\"}") }
    let json = "{\"id\":\"x\",\"result\":{\"agents\":[{\(fields.joined(separator: ","))}]}}"
    return try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]
}

private func makeAgentWithStatus(pane: String, agent: String?, status: String?, inputPending: Bool?) throws -> AgentInfo {
    var fields = ["\"pane_id\":\"\(pane)\""]
    if let agent { fields.append("\"agent\":\"\(agent)\"") }
    if let status { fields.append("\"agent_status\":\"\(status)\"") }
    if let inputPending { fields.append("\"input_pending\":\(inputPending)") }
    let json = "{\"id\":\"x\",\"result\":{\"agents\":[{\(fields.joined(separator: ","))}]}}"
    return try JSONDecoder().decode(ResultEnvelope<AgentListResult>.self, from: Data(json.utf8)).result.agents[0]
}

final class InputRouterTests: XCTestCase {
    let router = InputRouter()

    func testAgentPaneWithComposerUsesIntentMode() throws {
        let a = try makeAgent(pane: "p1", agent: "claude", hasComposer: true)
        XCTAssertEqual(router.mode(for: a), .intent)
    }

    /// A pane with NO named agent is a shell — it must stay rawKeys so text is not
    /// pasted somewhere it was never meant to go.
    func testPaneWithoutAgentFallsBackToRawKeys() throws {
        XCTAssertEqual(router.mode(for: try makeAgent(pane: "p1", agent: nil, hasComposer: true)), .rawKeys)
    }

    /// THE BUG (herdr-ios terminal): a pane that hosts a NAMED agent whose composer
    /// is transiently nil must STILL route its reply as intent (→ `agent.prompt`,
    /// which submits) — not fall to rawKeys `send_text`, which types the reply into
    /// the composer but never submits it ("the agent never received it"). The gate
    /// is the agent alone; `agent.prompt` is server-gated for real readiness.
    /// (Mutation guard: restoring the `composer != nil` half returns `.rawKeys` here
    /// and re-opens the never-submitted bug, so this assertion KILLs that mutation.)
    func testNamedAgentWithoutComposerStillRoutesAsIntent() throws {
        XCTAssertEqual(router.mode(for: try makeAgent(pane: "p1", agent: "claude", hasComposer: false)), .intent)
    }

    /// A named agent showing a MENU (blocked / input_pending — a plan-approval or an
    /// AskUserQuestion) must route as rawKeys: agent.prompt is rejected while blocked, so a
    /// typed answer has to go via pane.send_text into the menu's free-text field. Mutation
    /// guard: dropping the isAwaitingMenuInput check returns .intent here → the reply hits
    /// agent.prompt → "agent is blocked" (the reported bug).
    func testBlockedAgentRoutesAsRawKeysSoMenusAreAnswerable() throws {
        let blocked = try makeAgentWithStatus(pane: "p1", agent: "claude", status: "blocked", inputPending: nil)
        XCTAssertTrue(blocked.isAwaitingMenuInput)
        XCTAssertEqual(router.mode(for: blocked), .rawKeys)
        // A typed reply then plans to .text → pane.send_text (accepted while blocked).
        XCTAssertEqual(
            router.plan(action: .submitText("2"), pane: "p1", mode: router.mode(for: blocked)),
            .text(pane: "p1", "2")
        )
        // input_pending without a "blocked" status also counts (enumerated-select menus).
        let pending = try makeAgentWithStatus(pane: "p1", agent: "claude", status: "idle", inputPending: true)
        XCTAssertEqual(router.mode(for: pending), .rawKeys)
        // A working/idle agent with no menu still routes as intent (agent.prompt).
        let working = try makeAgentWithStatus(pane: "p1", agent: "claude", status: "working", inputPending: false)
        XCTAssertFalse(working.isAwaitingMenuInput)
        XCTAssertEqual(router.mode(for: working), .intent)
    }

    func testAgentInfoDecodesInputPendingFields() throws {
        let a = try makeAgentWithStatus(pane: "p1", agent: "claude", status: "blocked", inputPending: true)
        XCTAssertEqual(a.inputPending, true)
        XCTAssertEqual(a.agentStatus, "blocked")
        // Absent on an older server → nil, still decodes.
        let old = try makeAgent(pane: "p1", agent: "claude", hasComposer: true)
        XCTAssertNil(old.inputPending)
        XCTAssertFalse(old.isAwaitingMenuInput)
    }

    /// The pre-fill readiness gate stays STRICTER than routing on purpose: an
    /// unattended just-spawned task holds out for a confirmed composer, even though
    /// a manual reply to the same pane would already route as intent. Composer
    /// present → promptable; agent-but-no-composer / no-agent → not promptable.
    func testIsPromptableRequiresComposerEvenThoughRoutingDoesNot() throws {
        let named = try makeAgent(pane: "p1", agent: "claude", hasComposer: false)
        XCTAssertEqual(router.mode(for: named), .intent, "routing needs only a named agent")
        XCTAssertFalse(router.isPromptable(for: named), "pre-fill delivery still needs a composer")
        XCTAssertTrue(router.isPromptable(for: try makeAgent(pane: "p1", agent: "claude", hasComposer: true)))
        XCTAssertFalse(router.isPromptable(for: try makeAgent(pane: "p1", agent: nil, hasComposer: true)))
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
        // Submitting is a separate, explicit key — and on a shell (no agent) it goes
        // as a raw CR via pane.send_text, NOT agent.send_keys (which would be rejected
        // agent_not_found). herdrup #157 follow-up.
        XCTAssertEqual(
            router.plan(action: .key("Enter"), pane: "p1", mode: .rawKeys),
            .rawText(pane: "p1", "\r")
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

    /// A named agent takes keys through agent.send_keys (dialog navigation, server-verified).
    func testNamedKeysUseSendKeysInIntentMode() {
        XCTAssertEqual(router.plan(action: .key("Up"), pane: "p1", mode: .intent), .keys(pane: "p1", ["Up"]))
        XCTAssertEqual(router.plan(action: .key("Enter"), pane: "p1", mode: .intent), .keys(pane: "p1", ["Enter"]))
    }

    /// A shell/TUI pane (no agent) takes keys as raw terminal bytes via pane.send_text —
    /// agent.send_keys there is rejected agent_not_found (the shipped #157 bug).
    func testNamedKeysBecomeRawBytesInRawKeysMode() {
        XCTAssertEqual(router.plan(action: .key("Enter"), pane: "p1", mode: .rawKeys), .rawText(pane: "p1", "\r"))
        XCTAssertEqual(router.plan(action: .key("Up"), pane: "p1", mode: .rawKeys), .rawText(pane: "p1", "\u{1b}[A"))
        XCTAssertEqual(router.plan(action: .key("Escape"), pane: "p1", mode: .rawKeys), .rawText(pane: "p1", "\u{1b}"))
        XCTAssertEqual(router.plan(action: .key("Tab"), pane: "p1", mode: .rawKeys), .rawText(pane: "p1", "\t"))
        // No .keys plan is ever produced in rawKeys mode (that path needs an agent).
        if case .keys = router.plan(action: .key("Enter"), pane: "p1", mode: .rawKeys) {
            XCTFail("rawKeys must never route a key through agent.send_keys")
        }
    }

    func testKeyBytesCoversEveryAllowedKeyAndRejectsOthers() {
        for name in InputRouter.allowed {
            XCTAssertNotNil(InputRouter.keyBytes(for: name), "no bytes for allowed key \(name)")
        }
        XCTAssertEqual(InputRouter.keyBytes(for: "enter"), "\r", "name-matching is case-insensitive")
        XCTAssertNil(InputRouter.keyBytes(for: "F13"))
        // An unsupported key is refused in rawKeys too, not silently dropped.
        guard case .refused = router.plan(action: .key("F13"), pane: "p1", mode: .rawKeys) else {
            return XCTFail("unsupported key in rawKeys should be refused")
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

    /// A dedicated control cap's raw sequence goes out as `.rawText` — verbatim, in
    /// either mode (a named agent's TUI and a shell both take a raw keypress).
    func testRawSequenceBecomesRawTextInBothModes() {
        for mode in [InputMode.intent, .rawKeys] {
            XCTAssertEqual(
                router.plan(action: .rawSequence("\u{1b}[Z"), pane: "p1", mode: mode),
                .rawText(pane: "p1", "\u{1b}[Z"))
        }
    }

    /// AXIS: `.rawText` is the DELIBERATE-keypress path, so — unlike typed `.text`
    /// — it is NOT newline-guarded: `Ctrl+J` (LF) and `Ctrl+M` (CR) must pass
    /// through so those chords actually reach the PTY. (Mutation guard: adding the
    /// `.text` newline refusal to this path would refuse `Ctrl+J`/`Ctrl+M` and this
    /// KILLs it.)
    func testRawSequenceIsNotNewlineGuarded() {
        XCTAssertEqual(router.plan(action: .rawSequence("\n"), pane: "p1", mode: .intent), .rawText(pane: "p1", "\n"))
        XCTAssertEqual(router.plan(action: .rawSequence("\r"), pane: "p1", mode: .rawKeys), .rawText(pane: "p1", "\r"))
        XCTAssertEqual(router.plan(action: .rawSequence("\u{03}"), pane: "p1", mode: .intent), .rawText(pane: "p1", "\u{03}"))
    }

    func testEmptyRawSequenceIsRefused() {
        guard case .refused = router.plan(action: .rawSequence(""), pane: "p1", mode: .intent) else {
            return XCTFail("empty raw sequence must be refused")
        }
    }

    /// The Ctrl-toggle chord math: letters map case-insensitively into the control
    /// range, `Ctrl+J`/`Ctrl+M` are the intentional LF/CR, and a non-control
    /// character returns nil so the caller leaves it in the message untouched.
    func testControlByteMapsChordsAndRejectsNonControl() {
        XCTAssertEqual(InputRouter.controlByte(for: "c"), "\u{03}")
        XCTAssertEqual(InputRouter.controlByte(for: "C"), "\u{03}", "Ctrl is case-insensitive")
        XCTAssertEqual(InputRouter.controlByte(for: "a"), "\u{01}")
        XCTAssertEqual(InputRouter.controlByte(for: "z"), "\u{1a}")
        XCTAssertEqual(InputRouter.controlByte(for: "j"), "\u{0a}", "Ctrl+J is LF")
        XCTAssertEqual(InputRouter.controlByte(for: "m"), "\u{0d}", "Ctrl+M is CR")
        XCTAssertEqual(InputRouter.controlByte(for: "["), "\u{1b}", "Ctrl+[ is ESC")
        XCTAssertNil(InputRouter.controlByte(for: "1"))
        XCTAssertNil(InputRouter.controlByte(for: " "))
        XCTAssertNil(InputRouter.controlByte(for: "é"), "non-ASCII has no control code")
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
