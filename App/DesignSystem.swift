import SwiftUI
import HerdrKit

// Design tokens for herdr mobile, taken from the Claude Design kit
// (herdr mobile.dc.html + DESIGN-BRIEF.md). The brief's rules are load-bearing:
// deep desaturated navy ground (never black); colour is MEANING, not decoration
// (amber = waiting on you, red = died, blue = working, green = done); monospace is
// the MACHINE voice, a proportional sans is the APP voice.
//
// Fonts: Geist (app voice) + IBM Plex Mono (machine voice) — the families the Claude
// Design is set in — are bundled under App/Fonts/ and registered via UIAppFonts.
// Typography addresses them by PostScript name, so call sites never touch Font directly.

enum Palette {
    // Named for the Claude Design token table (herdr mobile.dc.html). Each token is a
    // ROLE, not just a colour: the app floats on `ground`; the terminal is its own
    // darker `groundMachine`, one shade under; surfaces sit above the ground; rules
    // divide them. (The earlier build shifted these — app ground was the terminal's
    // near-black and every surface was one step off; this restores the spec.)
    static let ground = Color(hex: 0x13162A)        // app ground — deep desaturated indigo, NEVER black
    static let groundMachine = Color(hex: 0x0B0D1C) // terminal ONLY — its own ground, one shade under
    static let groundDeep = Color(hex: 0x0A0C18)    // behind everything (device edges / safe-area fill)
    static let surface = Color(hex: 0x1D2038)       // cards, fields, rows
    static let card = surface                       // a card IS a surface (alias, kept for call sites)
    static let surfaceRaised = Color(hex: 0x262A45) // active tab, pressed state, key panel
    static let cardRaised = surfaceRaised           // alias, kept for call sites
    static let hairline = Color(hex: 0x2E3358)      // rule — hairline around a surface
    static let hairlineQuiet = Color(hex: 0x232742) // rule-quiet — section rules and dividers

    // Text tiers (ink).
    static let text = Color(hex: 0xEEF0F7)          // ink — what matters; also the only fill on acting controls
    static let textDim = Color(hex: 0x99A0BC)       // ink-second — supporting text, terminal body
    static let textFaint = Color(hex: 0x666D91)     // ink-third — machine metadata, ages, folder names

    // The design has NO accent colour: acting controls (Connect, Approve) are filled
    // with `text` (ink). `brand` (violet) is retired per-screen in the layout slices;
    // kept here unchanged until those call sites migrate to the ink fill.
    static let brand = Color(hex: 0x7A6FF0)

    // Status = meaning. The ONLY palette that carries colour.
    static let waiting = Color(hex: 0xE9A63C)       // amber — an agent is asking you
    static let died = Color(hex: 0xE2584E)          // red — exited / crashed
    static let working = Color(hex: 0x5B9BE8)       // blue — running
    static let done = Color(hex: 0x5FB37F)          // green — finished
}

/// Type roles. The contrast encodes WHO is speaking (brief §6). Both families are
/// bundled (App/Fonts/) and addressed by PostScript name. Sizes are FIXED
/// (`fixedSize:`) — the prior build used `.system(size:)`, which does NOT scale with
/// Dynamic Type, and the layout relies on hard-coded frame heights (e.g. the reserved
/// subtitle line, the terminal keycaps) that would clip if type scaled. Keeping the
/// fixed contract avoids that regression; a Dynamic-Type pass is its own later audit.
/// A requested weight maps to the nearest of the four bundled cuts (400/500/600/700).
enum Typography {
    /// User text-size multiplier (1.0 = default). Set at the app root from the
    /// "Text size" setting; the three members below multiply their point size by
    /// it, so ALL app chrome scales together with no call-site changes. The
    /// terminal has its own font control and does not go through `Typography`.
    static var scale: CGFloat = 1

    /// App voice — Geist (screen titles, names, buttons, labels).
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(geistName(weight), fixedSize: size * scale)
    }
    /// Machine voice — IBM Plex Mono (terminal, pane ids, status words, counts, keys).
    static func machine(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(plexMonoName(weight), fixedSize: size * scale)
    }
    /// Uppercase micro-label for section headers (machine voice, semibold).
    /// Computed (not a `let`) so it also honors `scale`.
    static var microLabel: Font { .custom("IBMPlexMono-SmBld", fixedSize: 11 * scale) }

    // Nearest bundled cut → its exact PostScript name. IBM Plex Mono's are irregular
    // (Regular is bare "IBMPlexMono"; Medium/SemiBold are abbreviated "-Medm"/"-SmBld").
    private static func geistName(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "Geist-Medium"
        case .semibold: return "Geist-SemiBold"
        case .bold, .heavy, .black: return "Geist-Bold"
        default: return "Geist-Regular"
        }
    }
    private static func plexMonoName(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "IBMPlexMono-Medm"
        case .semibold: return "IBMPlexMono-SmBld"
        case .bold, .heavy, .black: return "IBMPlexMono-Bold"
        default: return "IBMPlexMono"
        }
    }
}

/// The VISUAL half of the status story. The CLASSIFICATION — which agent belongs
/// in which section, fail-closed, stopped-from-liveness, unknowns surfaced — is
/// HerdrKit's `AgentGroup` (Sources/HerdrKit/AgentList.swift), which is unit
/// tested on Linux. This is only the colour + heading each group renders as, so
/// the meaning and its picture cannot drift out of one file.
///
/// Colour = meaning (brief): amber = wants a look (blocked OR uninterpretable),
/// red = the pane is gone, blue = working, faint = idle. `.unrecognised` is amber
/// on purpose — "this build cannot read it" is nearer to needs-attention than to
/// nothing-to-do, the same reasoning that sorts it high.
extension AgentGroup {
    var color: Color {
        switch self {
        case .needsYou: return Palette.waiting
        case .stopped: return Palette.died
        case .unrecognised: return Palette.waiting
        case .working: return Palette.working
        case .idle: return Palette.textFaint
        }
    }

    /// Uppercase micro-label heading, from the model's own label.
    var sectionTitle: String { label.uppercased() }
}

/// A subtle gradient carrying agent identity — the one place colour is allowed to
/// be decorative (brief §5, from the Termius reference). Keyed by agent kind.
enum AgentIdentity {
    static func gradient(for agent: String?) -> LinearGradient {
        let (a, b): (UInt32, UInt32)
        switch (agent ?? "").lowercased() {
        case let s where s.contains("claude"): (a, b) = (0xCE58A4, 0xA32E77)  // magenta
        case let s where s.contains("codex"):  (a, b) = (0xE8923C, 0xC5622A)  // orange
        case let s where s.contains("gemini"): (a, b) = (0x4C6EF5, 0x2E44C4)  // indigo (kept off the working blue)
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
        // U+2731 HEAVY ASTERISK, NOT U+2733: the eight-spoked asterisk has an
        // emoji-presentation variant that iOS renders as a green emoji, ignoring
        // the white foreground. U+2731 has no emoji form, so it stays white.
        case let s where s.contains("claude"): return "\u{2731}"   // ✱
        case let s where s.contains("codex"):  return "C"
        case let s where s.contains("gemini"): return "\u{2726}"   // ✦ four-pointed star
        default:
            // First letter, but never an empty tile: an empty or whitespace kind
            // falls back to "?" like a nil one. (Two kinds sharing a first letter
            // still differ by gradient colour; a blank tile differs from nothing.)
            let first = String((agent ?? "").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            return first.isEmpty ? "?" : first
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

/// The "working" status shape — a thin broken ring, turning. Colour carries the
/// meaning (the working blue); the motion says "live" without claiming a duration.
struct TurningRing: View {
    var color: Color
    /// Sized like `PulsingDot.diameter`: the defaults are the inline badge size, so the
    /// agent-list call site is unchanged. The sign-in flow's "starting" composition asks
    /// for a larger ring (30/2) because it is the only thing on the screen, and the same
    /// ring inline (13/1.6) while a code is in flight.
    var diameter: CGFloat = 13
    var lineWidth: CGFloat = 1.6
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// A filled status dot that softly pulses while `active` (i.e. working) and
/// holds perfectly still otherwise. Reuses TurningRing's onAppear +
/// repeatForever idiom; a fading scale reads "alive" without implying a
/// duration. Colour still carries the meaning — only the working state moves.
struct PulsingDot: View {
    var color: Color
    var active: Bool
    var diameter: CGFloat = 7
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(active && pulse ? 0.4 : 1)
            .scaleEffect(active && pulse ? 1.35 : 1)
            .onAppear { if active { startPulsing() } }
            .onChange(of: active) { _, isActive in
                // Snap back to solid when it stops working, restart when it resumes.
                pulse = false
                if isActive { startPulsing() }
            }
    }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
