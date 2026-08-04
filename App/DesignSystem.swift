import SwiftUI
import HerdrKit

// Design tokens for herdr mobile, taken from the Claude Design kit
// (herdr mobile.dc.html + DESIGN-BRIEF.md). The brief's rules are load-bearing:
// deep desaturated navy ground (never black); colour is MEANING, not decoration
// (amber = waiting on you, red = died, blue = working, green = done); monospace is
// the MACHINE voice, a proportional sans is the APP voice.
//
// Fonts: the design specifies Geist (app) + IBM Plex Mono (machine). Those font
// files are not yet bundled, so this uses the system proportional + monospaced
// faces as stand-ins; swapping in the real families is a later refinement that
// won't touch call sites (they go through Typography, not Font directly).

enum Palette {
    // Ground → elevated. Deep desaturated indigo/navy, not black.
    static let ground = Color(hex: 0x0B0D1C)      // app background
    static let groundDeep = Color(hex: 0x0A0C18)  // behind the ground (device edges)
    static let surface = Color(hex: 0x13162A)      // search field, tab bar
    static let card = Color(hex: 0x1D2038)         // list cards
    static let cardRaised = Color(hex: 0x232742)
    static let hairline = Color(hex: 0x2E3358)     // section rules, borders

    // Text tiers.
    static let text = Color(hex: 0xEEF0F7)         // primary
    static let textDim = Color(hex: 0x99A0BC)      // secondary
    static let textFaint = Color(hex: 0x666D91)    // tertiary / micro-labels

    // Status = meaning. The ONLY palette that carries colour.
    static let waiting = Color(hex: 0xE9A63C)      // amber — an agent is asking you
    static let died = Color(hex: 0xE2584E)         // red — exited / crashed
    static let working = Color(hex: 0x5B9BE8)      // blue — running
    static let done = Color(hex: 0x5FB37F)         // green — finished
}

/// Type roles. The contrast encodes WHO is speaking (brief §6).
enum Typography {
    /// App voice — proportional sans (screen titles, names, buttons, labels).
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    /// Machine voice — monospace (terminal, pane ids, status words, counts, keys).
    static func machine(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Uppercase micro-label for section headers, with letter-spacing.
    static let microLabel = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

/// The four agent states the design distinguishes — by SHAPE and colour, so they
/// survive a sideways glance or colour-blindness (brief §9.2).
enum AgentState: Int, Comparable {
    case needsYou   // amber, "!" — blocked on a question
    case stopped    // red, "✕" — exited / died
    case working    // blue, elapsed time
    case done       // green, "✓"
    case idle       // dim

    static func < (l: AgentState, r: AgentState) -> Bool { l.rawValue < r.rawValue }

    /// Best-effort mapping from the API's `agent_status` string.
    static func from(_ status: String?) -> AgentState {
        switch (status ?? "").lowercased() {
        case let s where s.contains("wait") || s.contains("input") || s.contains("pending") || s.contains("ask") || s.contains("block"):
            return .needsYou
        case let s where s.contains("exit") || s.contains("dead") || s.contains("stop") || s.contains("error") || s.contains("crash") || s.contains("fail"):
            return .stopped
        case let s where s.contains("work") || s.contains("run"):
            return .working
        case let s where s.contains("done") || s.contains("complete") || s.contains("finish"):
            return .done
        default:
            return .idle
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return Palette.waiting
        case .stopped: return Palette.died
        case .working: return Palette.working
        case .done: return Palette.done
        case .idle: return Palette.textFaint
        }
    }

    /// Uppercase section header for a group of this state.
    var sectionTitle: String {
        switch self {
        case .needsYou: return "NEEDS YOU"
        case .stopped: return "STOPPED"
        case .working: return "WORKING"
        case .done: return "DONE"
        case .idle: return "IDLE"
        }
    }
}

/// A subtle gradient carrying agent identity — the one place colour is allowed to
/// be decorative (brief §5, from the Termius reference). Keyed by agent kind.
enum AgentIdentity {
    static func gradient(for agent: String?) -> LinearGradient {
        let (a, b): (UInt32, UInt32)
        switch (agent ?? "").lowercased() {
        case let s where s.contains("claude"): (a, b) = (0xCE58A4, 0xA32E77)  // magenta
        case let s where s.contains("codex"):  (a, b) = (0xE8923C, 0xC5622A)  // orange
        case let s where s.contains("gemini"): (a, b) = (0x5B9BE8, 0x3E6FBF)  // blue
        default:                                 (a, b) = (0x8B79F6, 0x5B44C9)  // violet
        }
        return LinearGradient(colors: [Color(hex: a), Color(hex: b)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// One glyph for the identity chip. Distinct per kind so two same-coloured
    /// icons never collide on a bare first letter (claude/codex both → "C").
    /// The marks echo each vendor: Claude's spoked asterisk, a plain C for codex.
    static func glyph(for agent: String?) -> String {
        switch (agent ?? "").lowercased() {
        case let s where s.contains("claude"): return "\u{2733}"   // ✳ eight-spoked asterisk
        case let s where s.contains("codex"):  return "C"
        case let s where s.contains("gemini"): return "\u{2726}"   // ✦ four-pointed star
        default: return String((agent ?? "?").prefix(1)).uppercased()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
