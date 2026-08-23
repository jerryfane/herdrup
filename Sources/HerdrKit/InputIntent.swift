import Foundation

/// How a keystroke or message reaches a pane.
///
/// The design position is "send intent, not keystrokes": text goes through
/// `agent.prompt` and navigation through `agent.send_keys`, rather than
/// emulating a byte pipe. That is more reliable — the server verifies delivery
/// and reports composer state — and it suits a phone, where there is no real
/// keyboard to emulate.
///
/// It does not hold universally. A pane running a full-screen TUI (vim, less,
/// an interactive pager) needs keys delivered as keys, and `agent.prompt` would
/// paste text into something with no composer. So the model is explicit about
/// which mode a pane is in rather than pretending one mode fits everything.
public enum InputMode: Equatable, Sendable {
    /// Pane hosts a known agent with a composer. Text becomes a prompt.
    case intent
    /// Pane hosts something else (shell, full-screen TUI). Keys pass through
    /// individually; text is not submitted as a prompt.
    case rawKeys
}

/// A single thing the reader asked for.
public enum InputAction: Equatable, Sendable {
    case submitText(String)
    case key(String)
    /// A raw byte SEQUENCE from a dedicated keycap — a Shift+Tab (`ESC[Z`), a
    /// `Ctrl+<key>` control byte, a `^C` (`\u{03}`). Unlike `.submitText` in
    /// rawKeys this is an explicit KEYPRESS, not typed message text, so it is
    /// delivered verbatim and is NOT newline-guarded: `Ctrl+J`/`Ctrl+M` are
    /// legitimate here. Produced only by the terminal's fixed control caps /
    /// the Ctrl-toggle, never by the free-text reply field.
    case rawSequence(String)
}

/// What the client should actually send.
public enum InputPlan: Equatable, Sendable {
    case prompt(pane: String, text: String)
    /// Literal characters typed into a pane that has no composer — a shell, a
    /// TUI. Deliberately does NOT submit: text goes in, and Enter stays a
    /// separate explicit key.
    ///
    /// That separation is what makes typing into a shell safe. The hazard this
    /// mode originally guarded against was text ARRIVING AND EXECUTING somewhere
    /// unintended; typing without submitting cannot execute anything, and the
    /// reader sees exactly what landed before choosing to run it.
    case text(pane: String, String)
    /// Raw bytes from a dedicated control cap, delivered via `pane.send_text`
    /// WITHOUT the newline refusal `.text` enforces. This path exists ONLY for
    /// explicit control/escape keycaps (Shift+Tab, `Ctrl+<key>`, `^C`) — never for
    /// typed message text — so an intentional `Ctrl+J`/`Ctrl+M` reaches the PTY
    /// while typed text still cannot smuggle a submitting newline through `.text`.
    case rawText(pane: String, String)
    case keys(pane: String, [String])
    /// Refused, with a reason fit to show the reader.
    case refused(reason: String)
}

public struct InputRouter: Sendable {
    public init() {}

    /// Chooses the input mode for a pane from what `agent.list` reports.
    ///
    /// Gate on the presence of a NAMED agent ALONE — not on composer state.
    ///
    /// A pane that hosts a named agent is not a shell, so routing its reply to
    /// `agent.prompt` is safe. And `agent.prompt` is SERVER-gated: it returns
    /// agent_not_ready / agent_input_pending when it genuinely cannot deliver, so
    /// the extra `composer != nil` belt-and-suspenders here bought nothing except
    /// a silent failure mode. A LIVE agent's composer is TRANSIENTLY nil, and
    /// requiring it DOWNGRADED that agent to `.rawKeys` — where the reply was
    /// TYPED into the composer via `send_text` but never submitted, so "the agent
    /// never received it" (the reported terminal bug). Let the server, which
    /// actually knows readiness, decide; the client only needs to know a real
    /// agent is present. (The new-agent PRE-FILL gate is a separate, stricter
    /// signal — see `isPromptable(for:)` — because auto-delivering an unattended
    /// task warrants holding out for a confirmed composer.)
    public func mode(for agent: AgentInfo) -> InputMode {
        guard agent.agent != nil else { return .rawKeys }
        // A named agent showing an interactive MENU (plan-approval / AskUserQuestion) is
        // `blocked` / input_pending: `agent.prompt` is rejected there ("agent is blocked
        // and requires interactive input"). Route input as raw keys instead — typed chars
        // land in the menu's free-text field via `pane.send_text` (which the daemon accepts
        // while blocked) and Enter/arrows navigate via the keycaps. When the menu clears,
        // the agent goes back to `.intent`. See herdrup #157-follow-up / the answer-menus fix.
        if agent.isAwaitingMenuInput { return .rawKeys }
        return .intent
    }

    /// The composer-aware readiness gate the new-agent PRE-FILL delivery polls on.
    ///
    /// Distinct from `mode(for:)` on purpose: routing a reader's reply only needs
    /// to know a real agent is there (the server gates actual delivery), but the
    /// pre-fill loop AUTO-delivers a just-spawned agent's task unattended, so it
    /// holds out for a positive "a prompt will land now" signal — a present
    /// composer — before it fires. A named agent WITHOUT a composer is promptable
    /// enough to ROUTE a manual reply to (`mode == .intent`, server-gated) but is
    /// not yet a confirmed landing spot for an unattended pre-fill.
    public func isPromptable(for agent: AgentInfo) -> Bool {
        agent.agent != nil && agent.composer != nil
    }

    /// Turns a reader action into a concrete plan, or refuses it.
    ///
    /// Refusals are deliberate and visible rather than silent no-ops: a swallowed
    /// keystroke on a phone is indistinguishable from a dropped connection.
    public func plan(action: InputAction, pane: String, mode: InputMode) -> InputPlan {
        switch (action, mode) {
        case (.submitText(let text), .intent):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .refused(reason: "empty prompt")
            }
            return .prompt(pane: pane, text: text)

        case (.submitText(let text), .rawKeys):
            // A pane with no composer still accepts typing. Characters go in
            // literally via pane.send_text; nothing is submitted, so the reader
            // must press Enter deliberately. Refusing outright left shell and
            // TUI panes unable to receive a single character, which made the
            // "keys elsewhere" half of this design fictional (herdr-ios#3).
            guard !text.isEmpty else { return .refused(reason: "empty input") }
            // A newline in this path WOULD submit — send_text writes it to the
            // pty and a shell runs the line. That is the exact "text lands and
            // executes somewhere unintended" hazard rawKeys exists to prevent, so
            // the no-submit guarantee is a lie if CR/LF pass through. Enter stays
            // a separate, explicit key (.key("Enter")); a pasted or typed newline
            // is refused, not silently executed. Scan UNICODE SCALARS, not
            // Characters: Swift clusters "\r\n" into ONE grapheme that equals
            // neither "\n" nor "\r", so a Character scan would wave CRLF through.
            guard !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                return .refused(reason: "newline not allowed here; press Enter to submit")
            }
            return .text(pane: pane, text)

        case (.rawSequence(let seq), _):
            // Deliberate keypress bytes from a dedicated control cap — not typed
            // message text, so the `.text` newline refusal does NOT apply: a
            // bracketed `ESC[Z` (Shift+Tab) or a `Ctrl+J`/`Ctrl+M` is exactly what
            // the reader asked for. Only emptiness is refused; the byte(s) go raw
            // to the PTY via `pane.send_text`. Mode is irrelevant — a named agent's
            // TUI and a shell both take a raw keypress the same way.
            guard !seq.isEmpty else { return .refused(reason: "empty sequence") }
            return .rawText(pane: pane, seq)

        case (.key(let k), .rawKeys):
            // A shell / TUI pane has no agent, so `agent.send_keys` (the `.keys`
            // path) would be rejected `agent_not_found`. Deliver the key as its raw
            // terminal byte sequence via `pane.send_text` instead — the same path
            // the `^C` / Shift+Tab caps already use — so Return, arrows, esc, etc.
            // reach the PTY. See herdrup #157 follow-up.
            guard let bytes = Self.keyBytes(for: k) else {
                return .refused(reason: "unsupported key \(k)")
            }
            return .rawText(pane: pane, bytes)

        case (.key(let k), .intent):
            // A named agent takes keys through `agent.send_keys` (dialog navigation),
            // which the server verifies against the live pane.
            guard let canonical = Self.canonicalKey(k) else {
                return .refused(reason: "unsupported key \(k)")
            }
            return .keys(pane: pane, [canonical])
        }
    }

    /// The terminal byte sequence for an allowed named key, or nil if the name is
    /// not one we send. Used to deliver a keycap to a pane with no agent (a shell /
    /// TUI) as raw bytes via `pane.send_text`, since `agent.send_keys` needs an
    /// agent. Enter is CR (`\r`) — the PTY line discipline turns it into a submit —
    /// and the cursor/nav keys use the standard xterm sequences.
    static func keyBytes(for raw: String) -> String? {
        guard let canonical = canonicalKey(raw) else { return nil }
        switch canonical {
        case "Enter": return "\r"
        case "Escape": return "\u{1b}"
        case "Tab": return "\t"
        case "Backspace": return "\u{7f}"
        case "Space": return " "
        case "Up": return "\u{1b}[A"
        case "Down": return "\u{1b}[B"
        case "Right": return "\u{1b}[C"
        case "Left": return "\u{1b}[D"
        case "Home": return "\u{1b}[H"
        case "End": return "\u{1b}[F"
        case "PageUp": return "\u{1b}[5~"
        case "PageDown": return "\u{1b}[6~"
        default: return nil
        }
    }

    /// The control byte for a "Ctrl + `character`" chord, or nil if the character
    /// has no control code. Letters map case-insensitively (`Ctrl+C` == `Ctrl+c`
    /// == `\u{03}`) and the `@ A-Z [ \ ] ^ _` block maps into `0x00...0x1f`;
    /// everything else returns nil so the caller leaves the character untouched.
    /// `Ctrl+J`/`Ctrl+M` legitimately yield LF/CR here — they are delivered via
    /// the `.rawSequence` keypress path, which (unlike typed text) is not
    /// newline-guarded, so the intended control byte reaches the PTY.
    public static func controlByte(for character: Character) -> Character? {
        guard let ascii = character.asciiValue else { return nil }
        // 0x40–0x5f (@ A-Z [ \ ] ^ _) and 0x61–0x7a (a-z) have control codes.
        guard (ascii >= 0x40 && ascii <= 0x5f) || (ascii >= 0x61 && ascii <= 0x7a) else {
            return nil
        }
        return Character(UnicodeScalar(ascii & 0x1f))
    }

    /// How a reply tap should be delivered when a pane may hold a PRE-FILLED task
    /// (the new-agent flow opens the spawned agent's pane with its task ready).
    ///
    /// The invariant this encodes: a pre-filled task must ONLY ever reach the agent
    /// as a prompt — NEVER as rawKeys `send_text`. A just-spawned pane is a booting
    /// shell; typing the task there does not submit it, and a later Return would
    /// EXECUTE it as a shell command (both review witnesses flagged this). So while
    /// a pre-fill is pending we return `.prompt` when the agent is promptable and
    /// `.waitForComposer` otherwise — but NEVER a raw path, at any time (including
    /// after any UI timeout). A normal reply falls through to `.normalReply` and
    /// the usual `plan(...)` routing.
    public enum PrefillDelivery: Equatable, Sendable { case prompt, waitForComposer, normalReply }
    public func prefillDelivery(pendingPrefill: Bool, isPromptable: Bool) -> PrefillDelivery {
        guard pendingPrefill else { return .normalReply }
        return isPromptable ? .prompt : .waitForComposer
    }

    /// Keys the client is willing to send.
    ///
    /// Deliberately conservative. herdr#21 records that keys whose effect depends
    /// on unverifiable pane state are hazardous on agent send paths, so this
    /// allows an explicit set and refuses everything else rather than forwarding
    /// arbitrary strings the server may interpret unpredictably.
    static let allowed: Set<String> = [
        "Enter", "Escape", "Tab", "Backspace", "Space",
        "Up", "Down", "Left", "Right",
        "Home", "End", "PageUp", "PageDown",
    ]

    static func canonicalKey(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        for candidate in allowed where candidate.lowercased() == lowered {
            return candidate
        }
        return nil
    }
}

/// Tracks a submitted prompt so the UI can show it immediately without claiming
/// the server accepted it.
///
/// Optimistic echo is a lie unless it is labelled. Over a link where a single
/// request costs ~100ms (herdr#29) plus SSH delay, the gap between "typed" and
/// "confirmed" is visible, and the reader deserves to see which state they are
/// looking at.
public struct PendingSubmission: Equatable, Sendable {
    /// Mirrors herdr's own two-step delivery truth rather than collapsing it.
    /// `AgentPromptDelivery` distinguishes WrittenToPty (bytes reached the
    /// composer) from Submitted (a turn actually started) because they are
    /// different facts — herdr#18 and #26 both exist in the gap between them.
    /// A client that renders one "sent" state lies about which one it knows.
    public enum State: Equatable, Sendable {
        /// Request in flight; nothing confirmed.
        case pending
        /// Server acknowledged the bytes reached the pane's composer.
        case writtenToPty
        /// Server confirmed a turn started.
        case submitted
        case failed(String)
    }

    public let pane: String
    public let text: String
    public var state: State

    public init(pane: String, text: String, state: State = .pending) {
        self.pane = pane
        self.text = text
        self.state = state
    }

    /// True until a turn is confirmed started.
    ///
    /// Optimism belongs in a composer chip keyed to the request, never as fake
    /// characters painted into the grid: the phone has strictly less information
    /// about delivery than the server does.
    public var needsPendingTreatment: Bool { state != .submitted }

    /// True once bytes are known to have reached the composer but no turn has
    /// started — the stranded-draft state herdr#18/#26 are about, and the one
    /// worth showing the reader explicitly.
    public var isStrandedDraft: Bool { state == .writtenToPty }
}
