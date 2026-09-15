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
                // THE SPEC'S REGION MAP LOST ON DEVICE. It puts the hero leading, the
                // agent and its question in `.center` and a three-line fleet column
                // trailing; on a real island the corners are narrower than the design
                // assumed, so the centre was squeezed to a few characters and the
                // trailing column collapsed to a stack of ellipses — the owner's
                // screenshot of build 145 shows exactly that, a mark, a name and "…".
                //
                // So the sides carry ONE short thing each and the real content gets the
                // full-width bottom region, which is the arrangement the owner judged
                // better on their phone. Type sizes, weights and tokens stay the
                // spec's; only which region holds what has moved.
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedHero(state: context.state, isStale: context.isStale)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedHost(hostLabel: context.attributes.hostLabel)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBody(
                        hostLabel: context.attributes.hostLabel,
                        state: context.state,
                        isStale: context.isStale
                    )
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
                if state.needsYouCount > 1, !isStale {
                    // `compactCount` so 100 waiting reads "99+" here and in the compact
                    // pill alike; it also bounds the corner at three glyphs. Suppressed
                    // when stale, because the headline then reads "N may need you" and
                    // the count has no business being printed twice.
                    Text(state.needsYouCount.compactCount)
                        .font(WidgetFont.plexSemiBold(26))
                        .monospacedDigit()
                        .foregroundStyle(WidgetPalette.waiting)
                }
            }
            if state.needsYouCount > 0, !isStale {
                Text("need you")
                    .font(WidgetFont.geist(12))
                    .foregroundStyle(WidgetPalette.textDim)
            }
        }
        .lineLimit(1)
    }
}

/// TRAILING · WHICH MACHINE, one line. The spec's three-line fleet column does not fit
/// the real corner: on device it rendered as three ellipses. The counts move into the
/// bottom row, which has the width for them.
private struct ExpandedHost: View {
    let hostLabel: String

    var body: some View {
        Text(hostLabel)
            .font(WidgetFont.plex(11))
            .foregroundStyle(WidgetPalette.islandTextFaint)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// BOTTOM · what the card is about, across the island's full width: the agent, what it
/// is asking, how long it has been waiting, how much of the fleet is busy, and the one
/// action. Type stays the spec's — headline Geist SemiBold 16 pt `text`, question Plex
/// Mono 12 pt `textDim`, the faint line Plex Mono 11 pt — only the region changed.
private struct ExpandedBody: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if state.needsYouCount > 0 {
                ActivityAction(
                    title: state.headline.isEmpty ? "Open herdrup" : "Open \(state.headline)",
                    destination: state.deepLinkURL
                )
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var content: some View {
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

    /// The faint line: the timer that matters in this state, then the fleet counts. The
    /// counts live here rather than in a trailing column because the real corner cannot
    /// hold three lines — on device it rendered them as three ellipses.
    @ViewBuilder
    private var age: some View {
        HStack(spacing: 4) {
            if isStale {
                if let updatedAt = state.updatedAt {
                    Text("last update")
                    Text(Date(timeIntervalSince1970: updatedAt), style: .relative)
                } else {
                    Text("no recent update")
                }
            } else {
                if state.needsYouCount > 0, let since = state.blockedSince {
                    Text("waiting")
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .monospacedDigit()
                    Text("·")
                } else if state.status == .working, state.workingCount == 1,
                          let since = state.workingSince {
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .monospacedDigit()
                    Text("·")
                }
                Text("\(state.workingCount) working · \(state.totalCount) agents")
            }
        }
        .font(WidgetFont.plex(11))
        .foregroundStyle(WidgetPalette.islandTextFaint)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

#if DEBUG
/// The gallery's STAND-IN for the system's own Live Activity surface. The real one is
/// composited by iOS behind the card and is the thing that shows the wallpaper; a
/// material drawn inside the card cannot see it (measured on device, builds 144 and
/// 145). Here, in-app, a material DOES sample what is behind it, which is why this is
/// only a stand-in and lives under DEBUG beside the gallery that uses it.
private struct SystemSurfaceStandIn: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}
#endif

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
                        // INK, not the status tint. This is a 13pt TEXT run, and the
                        // glass tints are lifted only to the 3:1 graphic bar that the
                        // mark needs — #F2B85C measures 3.78:1 on the glass, under the
                        // 4.5:1 small-text bar. The hue still carries meaning two
                        // inches away, in the mark and the hero number.
                        Text(AgentActivitySummary.line(state))
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(dim)
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
                    destination: state.deepLinkURL,
                    onGlass: !isLuminanceReduced
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // NO BACKGROUND AT ALL, which is the only way this card is translucent.
        //
        // MEASURED ON DEVICE, twice: a material painted INSIDE a Live Activity does not
        // sample the wallpaper. The system composites its own surface behind this view,
        // so an in-view `.ultraThinMaterial` blurs THAT, and any wash over it simply
        // darkens the panel — build 144 at 0.80 read as paint, and build 145 at 0.55
        // came back darker still. The in-app gallery disagreed because there the
        // material really does sample the wallpaper behind it; that is the one thing
        // the gallery cannot stand in for.
        //
        // With `activityBackgroundTint(nil)` and nothing drawn here, the background IS
        // the system's own translucent material — the thing that actually shows the
        // wallpaper, and the thing every first-party activity uses.
        //
        // Always-On keeps the opaque backdrop: a translucent panel at 1 Hz is both
        // unreadable and wasteful, and that panel is meant to be dim.
        .background {
            if isLuminanceReduced { WidgetPalette.backdrop }
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

    /// STALE takes the summary's own doubt wording, the same substitution the island
    /// makes and the only one either surface makes. No other headline rewriting lives
    /// here — see `ExpandedHeadline.headline` for what that cost last time.
    private var lockHeadline: String {
        isStale && state.needsYouCount > 0 ? AgentActivitySummary.line(state) : state.headline
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
                        isStale: isStale,
                        onGlass: !isLuminanceReduced
                    )
                    // ONE waiting agent is not counted — the spec's state matrix puts
                    // the agent's name in the hero slot at that count, on the lock
                    // screen as well as in the island, so the digit is suppressed on
                    // both rather than printed on one.
                    if state.needsYouCount > 1, !isStale {
                        Text(verbatim: "\(state.needsYouCount)")
                            .font(WidgetFont.plexSemiBold(34))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
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

/// The spec's `Open` control: a hairline-weight outline, 44 pt, deep-linking to the
/// agent it names. Its sibling `Approve` — ink fill on a `ground` label, an `AppIntent` that
/// answers without opening the app — is deliberately absent: nothing writes
/// `AgentActivityState.defaultAnswer`, and the spec hides Approve exactly then.
private struct ActivityAction: View {
    let title: String
    let destination: URL
    /// The outline has to be visible on the surface it sits on. The old `hairline`
    /// token served neither — measured, 1.7:1 against the glass and 1.5:1 against the
    /// opaque Always-On navy it was assumed to be for — so it is gone from this file
    /// entirely. Glass takes the glass ink (4.7:1 at the card's lightest spot);
    /// Always-On takes `textFaint` (3.5:1), the dimmest token that still reads as an
    /// edge there.
    var onGlass = false

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(WidgetFont.geistSemiBold(15))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(WidgetPalette.text)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            onGlass ? WidgetPalette.glassTextFaint : WidgetPalette.textFaint,
                            lineWidth: 1
                        )
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
    /// Secondary and tertiary text ON GLASS, measured at the card's WORST spot — the
    /// lightest solid surface any shipped card produces over a true white wallpaper,
    /// #595B67, rather than its middle. The previous pair measured 4.40:1 there, under
    /// the AA small-text bar; this pair measures 5.60:1 and 4.69:1, with the primary at
    /// 5.92:1 and the lifted status marks at 3.78 / 3.62 / 3.18.
    ///
    /// The tiers sit close together on glass by nature: the surface is light enough that
    /// there is little room below white. Size and weight — 16 / 12 / 11 pt — carry the
    /// rest of the hierarchy, as they do in the opaque palette.
    static let glassTextDim = Color(hex6: 0xE6EAF5)
    static let glassTextFaint = Color(hex6: 0xD2D7E8)
    /// Tertiary text ON THE ISLAND, whose background is true black. `textFaint`
    /// measures 4.16:1 there — under the small-text bar at the 11 pt this tier is
    /// always set in — so the island gets its own step, at 5.2:1. It stays dimmer than
    /// `textDim` (8.1:1 on black), which is what keeps the three tiers apart.
    static let islandTextFaint = Color(hex6: 0x767DA3)
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
/// This gallery renders the SAME view types the widget renders — same file, same
/// private types — over the two backdrops that decide legibility, plus the STALE card
/// and the ALWAYS-ON card, which `.environment(\.isLuminanceReduced, true)` reaches
/// without a real dimmed screen.
///
/// WHAT IT DOES NOT PROVE: the system's own composition. The island's expanded regions
/// are laid out here by hand inside a black container at roughly the island's width —
/// so the types, colours and spacing inside each region are real, and the geometry
/// around them is an approximation, because `DynamicIslandExpandedRegion` cannot be
/// hosted outside ActivityKit. The banner's container and corner radius are likewise
/// the system's, not this view's.
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
        ("needsYou · no question", AgentActivityState(
            headline: "prod-deploy", status: .needsYou, needsYouCount: 4,
            workingCount: 3, totalCount: 18, workingSince: nil,
            blockedSince: Date().addingTimeInterval(-120).timeIntervalSince1970,
            agentID: "a5")),
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
    /// The bright one is TRUE WHITE at its top stop, not 0.96 — an earlier version
    /// measured at sRGB 245 and the figures were quoted as "over white", which flattered
    /// the tertiary tier by a little under 5%.
    private static let backdrops: [(String, LinearGradient)] = [
        ("bright", LinearGradient(colors: [Color(white: 1.0), Color(white: 0.82)],
                                  startPoint: .top, endPoint: .bottom)),
        ("dark", LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                                startPoint: .top, endPoint: .bottom)),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(Array(Self.backdrops.enumerated()), id: \.offset) { _, backdrop in
                    ForEach(Array(Self.cases.enumerated()), id: \.offset) { _, item in
                        card(item, backdrop: backdrop)
                    }
                    card(("needsYou · stale", Self.cases[0].1), backdrop: backdrop, isStale: true)
                    card(("needsYou · always-on", Self.cases[0].1), backdrop: backdrop, dimmed: true)
                }
                ForEach(Array(Self.cases.enumerated()), id: \.offset) { _, item in
                    island(item, isStale: false)
                }
                island(("needsYou · stale", Self.cases[0].1), isStale: true)
                ForEach(Array(Self.cases.enumerated()), id: \.offset) { _, item in
                    pills(item)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
        .accessibilityIdentifier("widget-gallery")
    }

    /// The lock-screen card over a wallpaper, with the system's translucent surface
    /// STOOD IN FOR behind it — the card itself now draws no background of its own,
    /// which is what makes it translucent on device.
    private func card(
        _ item: (String, AgentActivityState),
        backdrop: (String, LinearGradient),
        isStale: Bool = false,
        dimmed: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(item.0) · \(backdrop.0)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            LockScreenView(hostLabel: "tower", state: item.1, isStale: isStale)
                .environment(\.isLuminanceReduced, dimmed)
                .frame(width: 353)
                .background { if !dimmed { SystemSurfaceStandIn() } }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .background {
                    backdrop.1
                        .frame(width: 373)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
        }
    }

    /// The expanded island's regions, laid out by hand because ActivityKit owns the
    /// real container. The corners are framed NARROW on purpose — 84 pt, tighter than
    /// the device — so a layout that only survives a generous mock fails here first.
    /// That is the failure build 145 shipped: a trailing column that became ellipses.
    private func island(_ item: (String, AgentActivityState), isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("island · \(item.0)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    ExpandedHero(state: item.1, isStale: isStale)
                        .padding(.leading, 4)
                        .frame(width: 84, alignment: .leading)
                    Spacer(minLength: 0)
                    ExpandedHost(hostLabel: "hetzner-ts")
                        .padding(.trailing, 4)
                        .frame(width: 84, alignment: .trailing)
                }
                ExpandedBody(hostLabel: "hetzner-ts", state: item.1, isStale: isStale)
            }
            .padding(12)
            .frame(width: 353)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        }
    }

    /// The COMPACT pill and the MINIMAL circle, the two presentations that survive when
    /// the island is not expanded.
    private func pills(_ item: (String, AgentActivityState)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("compact + minimal · \(item.0)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    StatusMark(
                        status: item.1.status,
                        diameter: 10,
                        isUnconfirmed: item.1.markIsUnconfirmed
                    )
                    CompactCount(state: item.1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black))

                StatusMark(status: item.1.status, diameter: 14)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black))
            }
        }
    }
}
#endif
