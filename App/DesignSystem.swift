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
    static let surface = Color(hex: 0x1D2038)       // cards, fields, rows
    static let card = surface                       // a card IS a surface (alias, kept for call sites)
    static let surfaceRaised = Color(hex: 0x262A45) // active tab, pressed state, key panel
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
    /// Text and glyphs ON a coloured fill (Gram's violet bubble, its send button, the selected
    /// conversation row, an agent avatar's gradient): pure white (spec #FFFFFF).
    static let onAccent = Color.white
    /// Secondary text on the same fills (a selected row's preview and time): white at 82 %.
    static let onAccentDim = onAccent.opacity(0.82)

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

    static func glyph(forName name: String) -> String {
        AgentPresentation.initial(for: name)
    }

    static func gradient(forName name: String) -> LinearGradient {
        let (a, b): (UInt32, UInt32)
        switch AgentPresentation.colorIndex(for: name) {
        case 0: (a, b) = (0x8B79F6, 0x5B44C9)
        case 1: (a, b) = (0xCE58A4, 0xA32E77)
        case 2: (a, b) = (0xE8923C, 0xC5622A)
        default: (a, b) = (0x4C6EF5, 0x2E44C4)
        }
        return LinearGradient(colors: [Color(hex: a), Color(hex: b)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
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

private struct StatusMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether `TurningRing` and `PulsingDot` may move. False where they stay built but are
    /// not on screen: a kept-alive pane behind another tab or pane, a roster the pane covers.
    /// A repeating animation nobody can see still drives SwiftUI's display link every frame
    /// (#427: an idle Mac app at 66% CPU).
    var statusMotion: Bool {
        get { self[StatusMotionKey.self] }
        set { self[StatusMotionKey.self] = newValue }
    }
}

/// The "working" status shape — a thin broken ring, turning. Colour carries the
/// meaning (the working blue); the motion says "live" without claiming a duration.
/// It holds still while `statusMotion` is off.
struct TurningRing: View {
    var color: Color
    /// Sized like `PulsingDot.diameter`: the defaults are the inline badge size, so the
    /// agent-list call site is unchanged. The sign-in flow's "starting" composition asks
    /// for a larger ring (30/2) because it is the only thing on the screen, and the same
    /// ring inline (13/1.6) while a code is in flight.
    var diameter: CGFloat = 13
    var lineWidth: CGFloat = 1.6
    @Environment(\.statusMotion) private var statusMotion
    var body: some View {
        let ring = Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
        // Stopping means removing the motion: a repeatForever animation keeps running
        // after its value is set back without one. Each start is a new `Spinning`, fresh state.
        Group {
            if statusMotion {
                ring.modifier(Spinning())
            } else {
                ring
            }
        }
        #if DEBUG
        .modifier(StatusShapeID(id: "status-ring"))
        #endif
    }
}

private struct Spinning: ViewModifier {
    @State private var spin = false
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                StatusMotion.start(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
            #if DEBUG
            .modifier(StatusMotionTally())
            #endif
    }
}

/// The status badge on a Messages-style agent row's avatar (#352). Status is SHAPE +
/// colour, never colour alone — desaturate the screen and it still sorts: ! in a circle
/// waits, × in a rounded SQUARE stopped, a turning ring works. An unreachable remote
/// agent's status is a stale last-known value, so it shows a muted offline square (gone,
/// not live), never a live badge. Idle has no badge.
enum AgentAvatarBadge: Equatable {
    case waiting, stopped, unrecognised, working, offline, none

    init(_ group: AgentGroup) {
        switch group {
        case .needsYou: self = .waiting
        case .stopped: self = .stopped
        case .unrecognised: self = .unrecognised
        case .working: self = .working
        case .idle: self = .none
        }
    }
}

/// The round avatar of a Messages-style agent row: the name's colour and initial, with the
/// status as a 22 pt badge on its lower-right edge, ringed with the ground colour. The
/// owner's roster and a guest's shared-agent list draw the same avatar.
struct AgentAvatar: View {
    let name: String
    let badge: AgentAvatarBadge
    /// What VoiceOver reads for the badge: the status is colour + shape, so it is named.
    let badgeLabel: String
    var diameter: CGFloat = 52
    var glyphSize: CGFloat = 22

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(AgentIdentity.gradient(forName: name))
                .frame(width: diameter, height: diameter)
                .overlay(Text(AgentIdentity.glyph(forName: name))
                    .font(Typography.app(glyphSize, .bold)).foregroundStyle(.white))
            badgeView
                .accessibilityLabel(Text(badgeLabel))
                .offset(x: 4, y: 4)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .waiting: glyph("exclamationmark", Palette.waiting, square: false)
        case .unrecognised: glyph("questionmark", Palette.waiting, square: false)
        case .stopped: glyph("xmark", Palette.died, square: true)
        case .offline: glyph("wifi.slash", Palette.surfaceRaised, square: true, ink: Palette.textDim)
        case .working:
            TurningRing(color: Palette.working, diameter: 12, lineWidth: 2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.ground))
                .overlay(Circle().stroke(Palette.ground, lineWidth: 2.5))
        case .none:
            EmptyView()
        }
    }

    private func glyph(_ system: String, _ fill: Color, square: Bool, ink: Color = Palette.ground) -> some View {
        let shape = RoundedRectangle(cornerRadius: square ? 6 : 11)
        return Image(systemName: system)
            .font(.system(size: 10, weight: .heavy)).foregroundStyle(ink)
            .frame(width: 22, height: 22)
            .background(shape.fill(fill))
            .overlay(shape.stroke(Palette.ground, lineWidth: 2.5))
    }
}

/// A filled status dot that softly pulses while `active` (i.e. working) and
/// holds perfectly still otherwise. Reuses TurningRing's onAppear +
/// repeatForever idiom; a fading scale reads "alive" without implying a
/// duration. Colour still carries the meaning — only the working state moves.
/// Like `TurningRing`, it holds still while `statusMotion` is off.
struct PulsingDot: View {
    var color: Color
    var active: Bool
    var diameter: CGFloat = 7
    @Environment(\.statusMotion) private var statusMotion
    var body: some View {
        let dot = Circle().fill(color).frame(width: diameter, height: diameter)
        // Removed rather than reset when it stops, as in `TurningRing`; solid again at once.
        Group {
            if active && statusMotion {
                dot.modifier(Pulsing())
            } else {
                dot
            }
        }
        #if DEBUG
        .modifier(StatusShapeID(id: "status-dot"))
        #endif
    }
}

private struct Pulsing: ViewModifier {
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.4 : 1)
            .scaleEffect(pulse ? 1.35 : 1)
            .onAppear {
                StatusMotion.start(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
            #if DEBUG
            .modifier(StatusMotionTally())
            #endif
    }
}

private enum StatusMotion {
    /// Starts a status shape's repeating animation once the update that showed it is over.
    /// Started inside that update, the one coming back with a tab switch (Agents → Gram →
    /// Agents) never ran: the ring sat still (build 203).
    static func start(_ animation: Animation, _ change: @escaping () -> Void) {
        DispatchQueue.main.async { withAnimation(animation, change) }
    }
}

#if DEBUG
/// For the UI tests: how many `TurningRing`s and `PulsingDot`s are moving right now (their
/// `Spinning`/`Pulsing` motion is in the view tree), so a test can hold a screen to
/// "nothing hidden animates" (`status-motion`). Whether a shown shape really moves, the
/// tests see on screen.
@MainActor
enum StatusMotionCount {
    fileprivate(set) static var count = 0
}

private struct StatusMotionTally: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { StatusMotionCount.count += 1 }
            .onDisappear { StatusMotionCount.count -= 1 }
    }
}

/// For the UI tests, in the screenshot mock only: the status shape as an element of its own,
/// so a test can photograph it and see whether it moves. The label is left to the call site.
private struct StatusShapeID: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        if ScreenshotMock.mode != nil {
            content.accessibilityElement().accessibilityIdentifier(id)
        } else {
            content
        }
    }
}

/// The `status-motion` probe: `StatusMotionCount.count` as its label, polled. Its own view and
/// state, so the poll re-renders this probe alone.
struct StatusMotionProbe: View {
    @State private var count = 0

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("status-motion")
            .accessibilityLabel("\(count)")
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    if StatusMotionCount.count != count { count = StatusMotionCount.count }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
    }
}
#endif

extension Binding {
    /// A `Bool` binding that is true while the wrapped optional holds a value, and clears it
    /// when set to false: the `isPresented:` of an alert or dialog driven by optional state.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
