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

        case (.submitText, .rawKeys):
            // No composer to submit into. Typing a paragraph at a shell and
            // calling it "sent" would be a lie about what happened.
            return .refused(
                reason: "this pane has no agent composer; send keys instead of a prompt"
            )

        case (.key(let k), _):
            guard let canonical = Self.canonicalKey(k) else {
                return .refused(reason: "unsupported key \(k)")
            }
            return .keys(pane: pane, [canonical])
        }
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
    public enum State: Equatable, Sendable {
        case inFlight
        case confirmed
        case failed(String)
    }

    public let pane: String
    public let text: String
    public var state: State

    public init(pane: String, text: String, state: State = .inFlight) {
        self.pane = pane
        self.text = text
        self.state = state
    }

    /// True while the UI must visually distinguish this from delivered text.
    public var needsPendingTreatment: Bool { state == .inFlight }
}
