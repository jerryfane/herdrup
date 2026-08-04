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
    case keys(pane: String, [String])
    /// Refused, with a reason fit to show the reader.
    case refused(reason: String)
}

public struct InputRouter: Sendable {
    public init() {}

    /// Chooses the input mode for a pane from what `agent.list` reports.
    ///
    /// A pane only qualifies for intent mode when the server both names an agent
    /// and exposes composer state for it. Absent either, treating text as a
    /// prompt risks pasting into a shell — the exact "text lands somewhere
    /// unintended" failure that herdr#26 and #18 are about.
    public func mode(for agent: AgentInfo) -> InputMode {
        guard agent.agent != nil, agent.composer != nil else { return .rawKeys }
        return .intent
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
                return .refused(reason: "newline not allowed here — press Enter to submit")
            }
            return .text(pane: pane, text)

        case (.key(let k), _):
            guard let canonical = Self.canonicalKey(k) else {
                return .refused(reason: "unsupported key \(k)")
            }
            return .keys(pane: pane, [canonical])
        }
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
