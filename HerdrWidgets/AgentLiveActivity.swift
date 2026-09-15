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

    /// STALE reads as the summary's own doubt wording — "N may need you" — because a
    /// name stated plainly is a claim the card cannot back. Nothing waiting and nothing
    /// working is the ZERO STATE, which says so in words rather than printing an
    /// agent's name under a hero that is not there.
    private var headline: String {
        if isStale, state.needsYouCount > 0 { return AgentActivitySummary.line(state) }
        return state.needsYouCount == 0 && state.workingCount == 0
            ? "Nothing needs you"
            : state.headline
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
/// keeps the herdrup hue while the wallpaper still moves behind it. Never used over an
/// opaque fill, which would throw away the blur and leave only the wash.
///
/// NO OUTER BORDER, per the spec's lock-screen row: the system owns the card's corners
/// and its tint, so a border drawn inside it is a second, wrong edge a few points in
/// from the real one.
private struct GlassSurface: View {
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WidgetPalette.glassWash)
            }
    }
}

private struct LockScreenView: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool
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
                            .foregroundStyle(state.markColor)
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
                GlassSurface(cornerRadius: 0)
            }
        }
    }

    /// Secondary and tertiary ink, picked for the surface actually behind them. On
    /// glass the wallpaper is unknown, so the lifted pair is the only one that stays
    /// legible over a bright one; on the Always-On backdrop the surface is the opaque
    /// navy these were tuned against, and the dimmer pair is correct there.
    private var dim: Color { isLuminanceReduced ? WidgetPalette.textDim : WidgetPalette.glassTextDim }
    private var faint: Color { isLuminanceReduced ? WidgetPalette.textFaint : WidgetPalette.glassTextFaint }

    /// The zero card says so in words. A name under a suppressed hero reads as though
    /// that agent wants something, which is the one thing this state must not imply.
    private var lockHeadline: String {
        state.needsYouCount == 0 && state.workingCount == 0 ? "Nothing needs you" : state.headline
    }

    @ViewBuilder
    private var lockHero: some View {
        if state.needsYouCount > 0 {
            VStack(alignment: .leading, spacing: -1) {
                HStack(alignment: .center, spacing: 7) {
                    StatusMark(
                        status: state.status,
                        diameter: 12,
                        isUnconfirmed: state.markIsUnconfirmed,
                        isStale: isStale
                    )
                    Text(verbatim: "\(state.needsYouCount)")
                        .font(WidgetFont.plexSemiBold(34))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.waiting)
                }
                Text("need you")
                    .font(WidgetFont.geist(13))
                    .foregroundStyle(dim)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            StatusMark(status: state.status, diameter: 12, isStale: isStale)
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

    @ViewBuilder
    var body: some View {
        switch status {
        case .needsYou:
            if isStale || isUnconfirmed {
                Circle()
                    .strokeBorder(WidgetPalette.waiting, lineWidth: max(1.5, diameter * 0.16))
                    .frame(width: diameter, height: diameter)
            } else {
                Circle()
                    .fill(WidgetPalette.waiting)
                    .frame(width: diameter, height: diameter)
            }
        case .working:
            Circle()
                .strokeBorder(WidgetPalette.working, lineWidth: max(1.5, diameter * 0.16))
                .frame(width: diameter, height: diameter)
        case .idle:
            Circle()
                .fill(WidgetPalette.textFaint)
                .frame(width: max(4, diameter * 0.42), height: max(4, diameter * 0.42))
                .frame(width: diameter, height: diameter)
        case .stopped:
            ZStack {
                Circle()
                    .strokeBorder(WidgetPalette.died, lineWidth: max(1.5, diameter * 0.15))
                Capsule()
                    .fill(WidgetPalette.died)
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
    /// The brand wash over the system blur. 0.70, because 0.80 did not read as glass on
    /// a real lock screen — the panel looked painted. Thinner than this and the small
    /// text loses: the surface sits over an UNKNOWN wallpaper, and modelling the worst
    /// case (a white one, through the material) puts the tertiary ink at 2.1:1 by 0.45.
    /// Every drop in this alpha has to be paid for in the inks below.
    static let glassWash = LinearGradient(
        colors: [Color(hex6: 0x1B1F3A).opacity(0.70), Color(hex6: 0x13162A).opacity(0.70)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// Secondary and tertiary text ON GLASS, lifted again to pay for the thinner wash.
    /// Over the worst-case bright wallpaper they measure 5.2:1 and 4.3:1 — the pair
    /// tuned for the opaque navy measures 1.5:1 and 1.0:1 there. Only glass paths use
    /// these; the Always-On panel is opaque and keeps `textDim` / `textFaint`.
    static let glassTextDim = Color(hex6: 0xDDE2F0)
    static let glassTextFaint = Color(hex6: 0xC9CFE2)
    static let ground = Color(hex6: 0x13162A)
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
