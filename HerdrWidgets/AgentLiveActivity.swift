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
            .activityBackgroundTint(WidgetPalette.ground)
            .activitySystemActionForegroundColor(WidgetPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
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
                    if context.state.needsYouCount > 0 {
                        ActivityAction(
                            title: "Open",
                            destination: context.state.deepLinkURL,
                            tint: context.state.markColor,
                            outlined: context.isStale
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                    }
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

private struct ExpandedHero: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if state.needsYouCount > 0 {
                HStack(spacing: 7) {
                    StatusMark(
                        status: state.status,
                        diameter: 10,
                        isUnconfirmed: state.markIsUnconfirmed,
                        isStale: isStale
                    )
                    if state.needsYouCount > 1 {
                        Text(verbatim: "\(state.needsYouCount)")
                            .font(WidgetFont.plexSemiBold(26))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.waiting)
                    }
                }
                Text("need you")
                    .font(WidgetFont.geist(12))
                    .foregroundStyle(WidgetPalette.textDim)
            } else {
                StatusMark(status: state.status, diameter: 10, isStale: isStale)
            }
        }
    }
}

private struct ExpandedHeadline: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.headline)
                .font(WidgetFont.geistSemiBold(16))
                .foregroundStyle(WidgetPalette.text)
                .lineLimit(1)
            if let question = state.question, !question.isEmpty, !isStale {
                Text(question)
                    .font(WidgetFont.plex(12))
                    .foregroundStyle(WidgetPalette.textDim)
                    .lineLimit(1)
            }
            if isStale {
                Text("Not updated recently")
                    .font(WidgetFont.plex(11))
                    .foregroundStyle(WidgetPalette.textFaint)
                    .lineLimit(1)
            } else if state.needsYouCount > 0, let since = state.blockedSince {
                HStack(spacing: 4) {
                    Text("waiting")
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .monospacedDigit()
                }
                .font(WidgetFont.plex(11))
                .foregroundStyle(WidgetPalette.textFaint)
                .lineLimit(1)
            } else if state.status == .working, let since = state.workingSince {
                Text(Date(timeIntervalSince1970: since), style: .timer)
                    .font(WidgetFont.plex(11))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.textFaint)
                    .lineLimit(1)
            }
        }
    }
}

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
                    Text(state.headline)
                        .font(WidgetFont.geistSemiBold(18))
                        .foregroundStyle(WidgetPalette.text)
                        .lineLimit(1)
                    if let question = state.question, !question.isEmpty, !isStale {
                        Text(question)
                            .font(WidgetFont.plex(15))
                            .foregroundStyle(WidgetPalette.textDim)
                            .lineLimit(1)
                    } else if state.needsYouCount > 0, !isStale {
                        Text(AgentActivitySummary.line(state))
                            .font(WidgetFont.plex(13))
                            .foregroundStyle(state.markColor)
                            .lineLimit(1)
                    }
                    if !isLuminanceReduced {
                        lockDetail
                    }
                }
                Spacer(minLength: 0)
            }

            if state.needsYouCount > 0 {
                ActivityAction(
                    title: "Open Herdrup",
                    destination: state.deepLinkURL,
                    tint: state.markColor,
                    outlined: isStale || isLuminanceReduced
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
                    .foregroundStyle(WidgetPalette.textDim)
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
                .foregroundStyle(WidgetPalette.textFaint)
                .lineLimit(1)
            } else {
                Text("No update from \(hostLabel)")
                    .font(WidgetFont.plex(11))
                    .foregroundStyle(WidgetPalette.textFaint)
                    .lineLimit(1)
            }
        } else {
            Text("\(hostLabel) · \(state.workingCount) working · \(state.totalCount) agents")
                .font(WidgetFont.plex(13))
                .foregroundStyle(WidgetPalette.textFaint)
                .lineLimit(1)
        }
    }
}

private struct ActivityAction: View {
    let title: String
    let destination: URL
    let tint: Color
    let outlined: Bool

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(WidgetFont.geistSemiBold(15))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(outlined ? WidgetPalette.text : WidgetPalette.ground)
                .background(outlined ? Color.clear : tint)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(WidgetPalette.hairline, lineWidth: 1)
                    }
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
    static let ground = Color(hex6: 0x13162A)
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
