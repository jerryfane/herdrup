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
            // Match the card's bottom stop at the system-owned edges.
            .activityBackgroundTint(WidgetPalette.cardBottom)
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
                Text(state.markIsUnconfirmed ? "may need you" : "need you")
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
            if state.needsYouCount > 0 || state.status == .stopped || isStale {
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

    private var headline: String {
        state.presentationHeadline(isStale: isStale)
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

private struct LockScreenView: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        // Design: count, mark + headline + detail, app icon; one full-width action.
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                lockHero
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        StatusMark(
                            status: state.status,
                            diameter: 12,
                            isUnconfirmed: state.markIsUnconfirmed,
                            isStale: isStale
                        )
                        Text(lockHeadline)
                            .font(WidgetFont.geistSemiBold(17))
                            .foregroundStyle(primaryInk)
                            .lineLimit(1)
                    }
                    if let question = state.question, !question.isEmpty, !isStale {
                        Text(question)
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    } else if state.needsYouCount > 0, !isStale {
                        // INK, not the status hue: a 13pt text run on a surface whose
                        // brightness we do not control. The hue keeps its meaning in
                        // the mark beside it, which is a shape as well as a colour.
                        Text(AgentActivitySummary.line(state))
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                    }
                    // The fleet line and the age both go under Always-On: the spec drops
                    // them there, and the refresh rate cannot carry a timer anyway.
                    if !isLuminanceReduced {
                        lockDetail
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                // SIZED FOR THIS SLOT, AND THAT IS THE WHOLE POINT. Build 148 shipped
                // `AppLogo` here when that asset was the 1024x1024 app icon, and the
                // device drew a flat grey square: a Live Activity refuses to render an
                // asset whose resolution exceeds its presentation, silently, with no
                // build error. The in-app gallery receipt CANNOT catch it — those views
                // render in-process where no such limit applies, which is exactly why
                // 148 passed CI and failed on the Lock Screen. So this slot gets its own
                // 26pt asset at 1x/2x/3x (26/52/78 px) and `AppLogo` stays the app's
                // 64pt header mark. Resize the view, resize the asset with it.
                Image("AppLogoSmall")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            }

            if state.needsYouCount > 0 || state.status == .stopped || isStale {
                ActivityAction(
                    title: state.headline.isEmpty ? "Open herdrup" : "Open \(state.headline)",
                    destination: state.deepLinkURL
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The owner chose an opaque vertical gradient after viewing the system surface.
        .background(WidgetPalette.cardGradient)
    }

    // Fixed ink on the owned gradient, independent of wallpaper.
    private var primaryInk: AnyShapeStyle { AnyShapeStyle(WidgetPalette.text) }
    private var secondaryInk: AnyShapeStyle { AnyShapeStyle(WidgetPalette.textDim) }
    private var tertiaryInk: AnyShapeStyle { AnyShapeStyle(WidgetPalette.textFaint) }
    /// The hero number takes the status hue again. It went system-ink while the card
    /// sat on the system's surface, where amber measured 1.4:1 over a white wallpaper;
    /// on our own gradient it measures 7.7:1 at the lightest stop, so the design's
    /// amber hero comes back.
    private var heroInk: AnyShapeStyle { AnyShapeStyle(state.markColor) }

    private var lockHeadline: String {
        state.presentationHeadline(isStale: isStale)
    }

    /// HERO: the number and its caption, nothing else. The mark moved to the centre
    /// column where the spec puts it, so at a count of one — where the matrix drops the
    /// digit and makes the agent's name the hero — this column renders nothing at all
    /// rather than a stray dot.
    @ViewBuilder
    private var lockHero: some View {
        if state.needsYouCount > 1, !isStale {
            VStack(alignment: .leading, spacing: -1) {
                Text(verbatim: "\(state.needsYouCount)")
                    .font(WidgetFont.plexSemiBold(34))
                    .monospacedDigit()
                    .foregroundStyle(heroInk)
                Text(state.markIsUnconfirmed ? "may need you" : "need you")
                    .font(WidgetFont.geist(13))
                    .foregroundStyle(secondaryInk)
            }
            .fixedSize(horizontal: true, vertical: false)
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
                .foregroundStyle(tertiaryInk)
                .lineLimit(1)
            } else {
                Text("No update from \(hostLabel)")
                    .font(WidgetFont.plex(11))
                    .foregroundStyle(tertiaryInk)
                    .lineLimit(1)
            }
        } else {
            Text("\(hostLabel) · \(state.workingCount) working · \(state.totalCount) agents")
                .font(WidgetFont.plex(11))
                .foregroundStyle(tertiaryInk)
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

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(WidgetFont.geistSemiBold(15))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(WidgetPalette.text)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        // `textFaint` measures 3.5:1 against the gradient's foot, the
                        // dimmest token that still reads as an edge there. The old
                        // `hairline` measured 1.5:1 and is gone from this file.
                        .strokeBorder(WidgetPalette.textFaint, lineWidth: 1)
                }
        }
        .accessibilityIdentifier("live-activity-open")
    }
}


private struct StatusMark: View {
    let status: AgentActivityAttributes.Status
    var diameter: CGFloat = 10
    var isUnconfirmed = false
    var isStale = false

    private var tint: Color { WidgetPalette.color(status) }

    /// No disc behind the mark any more: every surface this renders on — the island's
    /// black, the lock card's gradient, the Always-On panel — is one this file paints,
    /// and the hue measures 4.9:1 or better against all three. The disc existed only
    /// while the card sat on the system's surface over an unknown wallpaper.
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
    static let ground = Color(hex6: 0x13162A)
    // Keep the original top and lighten the formerly near-black bottom.
    static let cardBottom = Color(hex6: 0x171B30)
    static let cardGradient = LinearGradient(
        colors: [Color(hex6: 0x1B1F3A), cardBottom],
        startPoint: .top,
        endPoint: .bottom
    )
    static let text = Color(hex6: 0xEEF0F7)
    /// Lift the small island text above the lock-screen token for contrast on black.
    static let islandTextFaint = Color(hex6: 0x767DA3)
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
    /// The design's state matrix, including unknown prompts and an all-clear roster.
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
        ("idle", AgentActivityState(
            headline: "docs-sweep", status: .idle, needsYouCount: 0,
            workingCount: 0, totalCount: 31, workingSince: nil, agentID: "a6")),
        ("working · many", AgentActivityState(
            headline: "index-rebuild", status: .working, needsYouCount: 0,
            workingCount: 7, totalCount: 31, workingSince: nil, agentID: "a8")),
        ("needsYou · unconfirmed", AgentActivityState(
            headline: "remote-build", status: .needsYou, needsYouCount: 3,
            unconfirmedCount: 3, workingCount: 0, totalCount: 3, workingSince: nil,
            agentID: "a7")),
    ]

    /// Both wallpapers exercise the same opaque card. System clipping remains a stand-in.
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

    /// Render the production card at the design's phone width.
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

                StatusMark(
                    status: item.1.status,
                    diameter: 14,
                    isUnconfirmed: item.1.markIsUnconfirmed
                )
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black))
            }
        }
    }
}
#endif
