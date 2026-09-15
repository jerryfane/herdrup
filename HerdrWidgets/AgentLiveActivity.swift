import SwiftUI
import WidgetKit
import ActivityKit

struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(
                hostLabel: context.attributes.hostLabel,
                state: context.state,
                isStale: context.isStale
            )
            .widgetURL(context.state.deepLinkURL)
            // NO TINT: passing nil leaves the system's own translucent background in
            // place, which is what makes the activity read as glass over the wallpaper.
            // The view paints its own blur + brand sheen on top of that (see
            // `LockScreenView.body`), so the surface stays herdrup-coloured without
            // going opaque.
            .activityBackgroundTint(nil)
            .activitySystemActionForegroundColor(WidgetPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                // THE REGION MAP IS THE SPEC'S, not a convenience: hero count on the
                // leading side, the named agent and what it is asking in the centre,
                // the fleet column trailing, the action along the bottom. Every size,
                // weight and token below is quoted from the design's spec rows, so a
                // deviation here is a bug rather than a preference.
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedHero(state: context.state, isStale: context.isStale)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ExpandedHeadline(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FleetTotals(hostLabel: context.attributes.hostLabel, state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedAction(state: context.state)
                }
            } compactLeading: {
                StatusMark(
                    status: context.state.status,
                    diameter: 10,
                    isUnconfirmed: context.state.markIsUnconfirmed,
                    isStale: context.isStale
                )
            } compactTrailing: {
                CompactCount(state: context.state)
            } minimal: {
                StatusMark(
                    status: context.state.status,
                    diameter: 14,
                    isUnconfirmed: context.state.markIsUnconfirmed,
                    isStale: context.isStale
                )
                .frame(width: 36, height: 36)
            }
            .widgetURL(context.state.deepLinkURL)
            .keylineTint(context.state.markColor)
        }
    }
}

private struct CompactCount: View {
    let state: AgentActivityAttributes.ContentState

    @ViewBuilder
    var body: some View {
        if state.needsYouCount > 0 {
            Text(state.needsYouCount.compactCount)
                .font(WidgetFont.plexSemiBold(13))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.waiting)
        } else if state.workingCount > 0 {
            Text(state.workingCount.compactCount)
                .font(WidgetFont.plexMedium(13))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.working)
        }
    }
}

/// LEADING · the hero. Spec: mark 10 pt + count in Plex Mono SemiBold 26 pt
/// monospacedDigit `waiting`, caption "need you" in Geist 12 pt `textDim`.
///
/// At ONE the number is dropped and the mark sits alone beside the name — one agent
/// does not need counting — and at zero the caption goes too, because a hero that
/// says "need you" over nothing is a lie the zero state exists to avoid.
private struct ExpandedHero: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                StatusMark(
                    status: state.status,
                    diameter: 10,
                    isUnconfirmed: state.markIsUnconfirmed,
                    isStale: isStale
                )
                if state.needsYouCount > 1 {
                    // `compactCount` so 100 waiting reads "99+" here and in the compact
                    // pill alike; it also bounds the corner at three glyphs.
                    Text(state.needsYouCount.compactCount)
                        .font(WidgetFont.plexSemiBold(26))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.waiting)
                }
            }
            if state.needsYouCount > 0 {
                Text("need you")
                    .font(WidgetFont.geist(12))
                    .foregroundStyle(WidgetPalette.textDim)
            }
        }
        .lineLimit(1)
    }
}

/// TRAILING · the fleet column. Spec: hostLabel, working count and total, all Plex
/// Mono 11 pt `textFaint`, right-aligned, one line each. The machine is secondary
/// detail by the brief's own decision, which is why it lives here and not in the hero.
private struct FleetTotals: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hostLabel)
            Text("\(state.workingCount) working")
            Text(state.totalCount == 1 ? "1 agent" : "\(state.totalCount) agents")
        }
        .font(WidgetFont.plex(11))
        .foregroundStyle(WidgetPalette.textFaint)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// CENTRE · what the card is about. Spec: headline Geist SemiBold 16 pt `text`,
/// question Plex Mono 12 pt `textDim` on one line, age Plex Mono 11 pt `textFaint`.
///
/// The question is the difference between noticing and deciding, which is why it
/// outranks the age and why the daemon truncates it at the source.
private struct ExpandedHeadline: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(WidgetFont.geistSemiBold(16))
                .foregroundStyle(WidgetPalette.text)
                .lineLimit(1)
            if let question = state.question, !question.isEmpty, !isStale {
                Text(question)
                    .font(WidgetFont.plex(12))
                    .foregroundStyle(WidgetPalette.textDim)
                    .lineLimit(1)
            }
            age
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// STALE reads as the summary's own doubt wording — "N may need you" — because the
    /// agent's name stated plainly is a claim the card cannot back once the roster is
    /// unconfirmed. That is the ONLY substitution made here.
    ///
    /// The design's zero card says "Nothing needs you", and that wording deliberately
    /// does NOT get synthesised in this file: the comment on `AgentActivityState` below
    /// records what happened last time a view rewrote the headline on
    /// `needsYouCount == 0` — an all-clear printed over a red stopped mark, and over the
    /// connect handshake. A quiet roster has to say so from `AgentList.activityContent`,
    /// where a test can execute the rule.
    private var headline: String {
        isStale && state.needsYouCount > 0 ? AgentActivitySummary.line(state) : state.headline
    }

    /// The age line: how long this has been waiting, how long the single working agent
    /// has been running, or — when the card is stale, where the spec puts the age in
    /// place of the question — when it was last heard from.
    @ViewBuilder
    private var age: some View {
        Group {
            if isStale {
                if let updatedAt = state.updatedAt {
                    HStack(spacing: 3) {
                        Text("last update")
                        Text(Date(timeIntervalSince1970: updatedAt), style: .relative)
                    }
                } else {
                    Text("no recent update")
                }
            } else if state.needsYouCount > 0, let since = state.blockedSince {
                HStack(spacing: 4) {
                    Text("waiting")
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .monospacedDigit()
                }
            } else if state.status == .working, state.workingCount == 1,
                      let since = state.workingSince {
                Text(Date(timeIntervalSince1970: since), style: .timer)
                    .monospacedDigit()
            }
        }
        .font(WidgetFont.plex(11))
        .foregroundStyle(WidgetPalette.textFaint)
        .lineLimit(1)
    }
}

/// BOTTOM · the one action, 44 pt, and only when there is something to act on.
///
/// The spec's primary is Approve, an `AppIntent` carrying the agent's own default
/// answer — and it is explicitly hidden when that answer is absent, when the card is
/// stale, or when nothing is blocked, because "a button that cannot answer honestly is
/// worse than no button". Nothing produces `defaultAnswer` yet: it is decoded in
/// `AgentActivityState` and written by nobody, so every card today takes the spec's own
/// fallback, `Open`, which deep-links to the agent. When the daemon starts sending an
/// answer this is where Approve goes, named after the agent so a mis-tap is visible.
private struct ExpandedAction: View {
    let state: AgentActivityAttributes.ContentState

    @ViewBuilder
    var body: some View {
        if state.needsYouCount > 0 {
            ActivityAction(title: openTitle, destination: state.deepLinkURL)
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }

    /// Named, like Approve would be: the button says which agent it lands on.
    private var openTitle: String {
        state.headline.isEmpty ? "Open herdrup" : "Open \(state.headline)"
    }
}

/// The glass surface: the system's own blur under a brand-tinted wash, so the panel
/// keeps the herdrup hue while the wallpaper still moves behind it. NO OUTER BORDER,
/// per the spec's lock-screen row — the system owns the card's corners and its tint.
private struct GlassSurface: View {
    var cornerRadius: CGFloat
    /// Overridable so the DEBUG gallery can render the same card at several alphas in
    /// one screenshot and the choice can be measured off real pixels instead of a model
    /// of the material, which turned out to be far off: the modelled worst case put the
    /// composited surface near #B0B0B0, the render puts it at #404251.
    var washAlpha: Double = WidgetPalette.glassWashAlpha

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetPalette.glassWash(alpha: washAlpha))
            }
    }
}

private struct LockScreenView: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool
    /// DEBUG gallery only: renders the same card at a different wash so the alpha can
    /// be chosen from pixels. Production always takes the palette's value.
    var washAlpha: Double = WidgetPalette.glassWashAlpha
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                lockHero
                VStack(alignment: .leading, spacing: 3) {
                    Text(lockHeadline)
                        .font(WidgetFont.geistSemiBold(17))
                        .foregroundStyle(WidgetPalette.text)
                        .lineLimit(1)
                    if let question = state.question, !question.isEmpty, !isStale {
                        Text(question)
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(dim)
                            .lineLimit(1)
                    } else if state.needsYouCount > 0, !isStale {
                        Text(AgentActivitySummary.line(state))
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    // The fleet line and the age both go under Always-On: the spec drops
                    // them there, and the refresh rate cannot carry a timer anyway.
                    if !isLuminanceReduced {
                        lockDetail
                    }
                }
                Spacer(minLength: 0)
            }

            if state.needsYouCount > 0 {
                ActivityAction(
                    title: state.headline.isEmpty ? "Open herdrup" : "Open \(state.headline)",
                    destination: state.deepLinkURL
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // GLASS, not paint. With `activityBackgroundTint(nil)` the system leaves its own
        // translucent surface behind this view, so the wallpaper shows through the blur;
        // the wash keeps the herdrup hue and the sheen gives the pane an edge to catch.
        // Under Always-On (luminance reduced) the wash goes solid: a blurred wallpaper
        // at 1 Hz is both unreadable and wasteful, and the panel is meant to be dim.
        .background {
            if isLuminanceReduced {
                WidgetPalette.backdrop
            } else {
                GlassSurface(cornerRadius: 0, washAlpha: washAlpha)
            }
        }
    }

    /// Secondary and tertiary ink, picked for the surface actually behind them. On
    /// glass the wallpaper is unknown, so the lifted pair is the only one that stays
    /// legible over a bright one; on the Always-On backdrop the surface is the opaque
    /// navy these were tuned against, and the dimmer pair is correct there.
    private var dim: Color { isLuminanceReduced ? WidgetPalette.textDim : WidgetPalette.glassTextDim }
    private var faint: Color { isLuminanceReduced ? WidgetPalette.textFaint : WidgetPalette.glassTextFaint }
    /// The status hue for this surface: lifted on glass, the token itself on the
    /// opaque Always-On panel.
    private var accent: Color {
        isLuminanceReduced ? state.markColor : WidgetPalette.glassColor(state.status)
    }

    /// No headline override here either — see `ExpandedHeadline.headline`.
    private var lockHeadline: String { state.headline }

    @ViewBuilder
    private var lockHero: some View {
        if state.needsYouCount > 0 {
            VStack(alignment: .leading, spacing: -1) {
                HStack(alignment: .center, spacing: 7) {
                    StatusMark(
                        status: state.status,
                        diameter: 12,
                        isUnconfirmed: state.markIsUnconfirmed,
                        isStale: isStale,
                        onGlass: !isLuminanceReduced
                    )
                    Text(verbatim: "\(state.needsYouCount)")
                        .font(WidgetFont.plexSemiBold(34))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                Text("need you")
                    .font(WidgetFont.geist(13))
                    .foregroundStyle(dim)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            StatusMark(status: state.status, diameter: 12, isStale: isStale,
                       onGlass: !isLuminanceReduced)
                .frame(width: 34, height: 34)
        }
    }

    @ViewBuilder
    private var lockDetail: some View {
        if isStale {
            if let updatedAt = state.updatedAt {
                HStack(spacing: 3) {
                    Text("last update")
                    Text(Date(timeIntervalSince1970: updatedAt), style: .relative)
                    Text("· no update from \(hostLabel)")
                }
                .font(WidgetFont.plex(11))
                .foregroundStyle(faint)
                .lineLimit(1)
            } else {
                Text("No update from \(hostLabel)")
                    .font(WidgetFont.plex(11))
                    .foregroundStyle(faint)
                    .lineLimit(1)
            }
        } else {
            Text("\(hostLabel) · \(state.workingCount) working · \(state.totalCount) agents")
                .font(WidgetFont.plex(11))
                .foregroundStyle(faint)
                .lineLimit(1)
        }
    }
}

/// The spec's `Open` control: hairline outline, 44 pt, deep-linking to the agent it
/// names. Its sibling `Approve` — ink fill on a `ground` label, an `AppIntent` that
/// answers without opening the app — is deliberately absent: nothing writes
/// `AgentActivityState.defaultAnswer`, and the spec hides Approve exactly then.
private struct ActivityAction: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(WidgetFont.geistSemiBold(15))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(WidgetPalette.text)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(WidgetPalette.hairline, lineWidth: 1)
                }
        }
    }
}

private struct StatusMark: View {
    let status: AgentActivityAttributes.Status
    var diameter: CGFloat = 10
    var isUnconfirmed = false
    var isStale = false
    /// The lock screen's glass needs the lifted tints; the island is drawn on black and
    /// the Always-On panel on the opaque navy, where the tokens themselves are right.
    var onGlass = false

    private var tint: Color {
        onGlass ? WidgetPalette.glassColor(status) : WidgetPalette.color(status)
    }

    @ViewBuilder
    var body: some View {
        switch status {
        case .needsYou:
            if isStale || isUnconfirmed {
                Circle()
                    .strokeBorder(tint, lineWidth: max(1.5, diameter * 0.16))
                    .frame(width: diameter, height: diameter)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: diameter, height: diameter)
            }
        case .working:
            Circle()
                .strokeBorder(tint, lineWidth: max(1.5, diameter * 0.16))
                .frame(width: diameter, height: diameter)
        case .idle:
            Circle()
                .fill(tint)
                .frame(width: max(4, diameter * 0.42), height: max(4, diameter * 0.42))
                .frame(width: diameter, height: diameter)
        case .stopped:
            ZStack {
                Circle()
                    .strokeBorder(tint, lineWidth: max(1.5, diameter * 0.15))
                Capsule()
                    .fill(tint)
                    .frame(width: diameter * 0.62, height: max(1.5, diameter * 0.14))
            }
            .frame(width: diameter, height: diameter)
        }
    }
}

private enum WidgetFont {
    static func geist(_ size: CGFloat) -> Font { .custom("Geist-Regular", fixedSize: size) }
    static func geistSemiBold(_ size: CGFloat) -> Font { .custom("Geist-SemiBold", fixedSize: size) }
    static func plex(_ size: CGFloat) -> Font { .custom("IBMPlexMono", fixedSize: size) }
    static func plexMedium(_ size: CGFloat) -> Font { .custom("IBMPlexMono-Medm", fixedSize: size) }
    static func plexSemiBold(_ size: CGFloat) -> Font { .custom("IBMPlexMono-SmBld", fixedSize: size) }
}

private enum WidgetPalette {
    /// How much navy sits over the system blur. MEASURED, not modelled: the DEBUG
    /// gallery renders the card at several alphas over a bright and a dark backdrop,
    /// and the composited surface is read off the screenshot. Over a WHITE wallpaper
    /// the surface comes out #404251 at 0.70, #555763 at 0.55, #6B6C75 at 0.40.
    ///
    /// 0.55 is the thinnest that keeps the text at WCAG AA there — tertiary 4.6:1,
    /// primary 6.3:1 — and 0.70, which is what shipped, reads as paint rather than
    /// glass. The status marks do not survive 0.55 in their opaque tokens, which is
    /// what `glassColor` is for.
    static let glassWashAlpha: Double = 0.55

    static func glassWash(alpha: Double) -> LinearGradient {
        LinearGradient(
            colors: [Color(hex6: 0x1B1F3A).opacity(alpha), Color(hex6: 0x13162A).opacity(alpha)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    /// Secondary and tertiary text ON GLASS. Against the surface the render actually
    /// produces they measure 7.7:1 and 6.4:1 over a bright wallpaper — the earlier
    /// figures in this comment came from a model of the material that put the surface
    /// four times lighter than it is.
    static let glassTextDim = Color(hex6: 0xDDE2F0)
    static let glassTextFaint = Color(hex6: 0xC9CFE2)
    static let ground = Color(hex6: 0x13162A)
    /// The status colours ON GLASS. Same hues — colour still carries meaning — lifted
    /// until each clears 3:1 against the measured 0.55 surface over a white wallpaper,
    /// where the opaque tokens fall to 2.5:1 (working) and 2.0:1 (died). The mark is
    /// the one graphic the whole card rests on; it does not get to be marginal.
    static let glassWaiting = Color(hex6: 0xF2B85C)
    static let glassWorking = Color(hex6: 0x8FC3F5)
    static let glassDied = Color(hex6: 0xF59A92)

    static func glassColor(_ status: AgentActivityAttributes.Status) -> Color {
        switch status {
        case .needsYou: return glassWaiting
        case .working: return glassWorking
        case .idle: return glassTextFaint
        case .stopped: return glassDied
        }
    }
    /// A top-leading lift on the ground colour. Two stops, eight points apart in
    /// lightness: enough to read as depth on the lock screen, not enough to fight the
    /// status marks, which are the only saturated things on the surface.
    static let backdrop = LinearGradient(
        colors: [Color(hex6: 0x1B1F3A), Color(hex6: 0x13162A)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let hairline = Color(hex6: 0x2E3358)
    static let text = Color(hex6: 0xEEF0F7)
    static let textDim = Color(hex6: 0x99A0BC)
    static let textFaint = Color(hex6: 0x666D91)
    static let waiting = Color(hex6: 0xE9A63C)
    static let died = Color(hex6: 0xE2584E)
    static let working = Color(hex6: 0x5B9BE8)

    static func color(_ status: AgentActivityAttributes.Status) -> Color {
        switch status {
        case .needsYou: return waiting
        case .working: return working
        case .idle: return textFaint
        case .stopped: return died
        }
    }
}

private extension AgentActivityState {
    // `markIsUnconfirmed` lives in `Shared/AgentActivityState.swift`, not here: it decides
    // whether the mark renders hollow, and a rule in this target cannot be executed by any
    // test.

    var markColor: Color { WidgetPalette.color(status) }

    // NO HEADLINE OVERRIDE LIVES HERE. A private rule in this target once rewrote the
    // headline to "Nothing needs you" whenever needsYouCount == 0, which put that all-clear
    // above a RED stopped mark (the agent had died), discarded the agent's name on a working
    // roster, and answered the connect handshake — "Connecting…", nothing known yet — with a
    // confident all-clear. No test target can see this file, so CI could not catch any of it.
    // The headline is the lead agent's own name, decided in HerdrKit's
    // `AgentList.activityContent` where a test executes it; a quiet roster is expressed by
    // `AgentActivitySummary.line`, which is pinned in `Shared/`.

    var deepLinkURL: URL { AgentActivityDeepLink.url(agentID: agentID) }
}

private extension Int {
    var compactCount: String { self >= 100 ? "99+" : String(self) }
}

private extension Color {
    init(hex6: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex6 >> 16) & 0xFF) / 255,
            green: Double((hex6 >> 8) & 0xFF) / 255,
            blue: Double(hex6 & 0xFF) / 255,
            opacity: 1
        )
    }
}

#if DEBUG
/// EVERY PREVIOUS ROUND OF THIS LAYOUT WAS JUDGED BY ARITHMETIC. XCUITest cannot see a
/// Live Activity, so the lock-screen card and the expanded island shipped unlooked-at
/// three times, and twice came back wrong from the owner's phone.
///
/// This gallery renders the SAME views the widget renders — same file, same private
/// types — inside the app, over the two backdrops that decide legibility: a bright
/// wallpaper and a dark one. It is not the system's own composition (the island's mask
/// and the banner's container belong to iOS), so it proves type, colour, spacing and
/// contrast, NOT the outer geometry.
///
/// Reached only through `ScreenshotMock.widgets`; the shipping app has no path to it.
struct WidgetGallery: View {
    /// Four states worth looking at, chosen from the design's own state matrix.
    private static let cases: [(String, AgentActivityState)] = [
        ("needsYou · many", AgentActivityState(
            headline: "api-refactor", status: .needsYou, needsYouCount: 23,
            workingCount: 7, totalCount: 31, workingSince: nil,
            blockedSince: Date().addingTimeInterval(-252).timeIntervalSince1970,
            question: "Run migration on prod db?", agentID: "a1")),
        ("needsYou · one", AgentActivityState(
            headline: "docs-sweep", status: .needsYou, needsYouCount: 1,
            workingCount: 2, totalCount: 9, workingSince: nil,
            blockedSince: Date().addingTimeInterval(-41).timeIntervalSince1970,
            question: "Overwrite README?", agentID: "a2")),
        ("working only", AgentActivityState(
            headline: "index-rebuild", status: .working, needsYouCount: 0,
            workingCount: 1, totalCount: 12,
            workingSince: Date().addingTimeInterval(-903).timeIntervalSince1970,
            agentID: "a3")),
        ("stopped", AgentActivityState(
            headline: "flaky-e2e", status: .stopped, needsYouCount: 0,
            workingCount: 0, totalCount: 5, workingSince: nil, agentID: "a4")),
    ]

    /// A bright wallpaper is the worst case for the glass, a dark one the common case.
    private static let backdrops: [(String, LinearGradient)] = [
        ("bright", LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)],
                                  startPoint: .top, endPoint: .bottom)),
        ("dark", LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                                startPoint: .top, endPoint: .bottom)),
    ]

    /// The alphas under consideration. The owner rejected the shipped surface as
    /// "not glass"; these are rendered side by side over the same wallpapers so the
    /// thinnest one that still carries the tertiary ink can be MEASURED off the
    /// screenshot rather than argued from a model.
    private static let alphas: [Double] = [0.70, 0.55, 0.40, 0.25]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(Self.backdrops.enumerated()), id: \.offset) { _, backdrop in
                    ForEach(Array(Self.alphas.enumerated()), id: \.offset) { _, alpha in
                        card(Self.cases[0], backdrop: backdrop, alpha: alpha)
                    }
                    ForEach(Array(Self.cases.enumerated()), id: \.offset) { _, item in
                        card(item, backdrop: backdrop, alpha: WidgetPalette.glassWashAlpha)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .accessibilityIdentifier("widget-gallery")
    }

    private func card(
        _ item: (String, AgentActivityState),
        backdrop: (String, LinearGradient),
        alpha: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(item.0) · \(backdrop.0) · wash \(Int(alpha * 100))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            LockScreenView(hostLabel: "tower", state: item.1, isStale: false, washAlpha: alpha)
                .frame(width: 353)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background {
                    backdrop.1
                        .frame(width: 373)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
        }
    }
}
#endif
