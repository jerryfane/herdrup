import Foundation
import SwiftUI
import WidgetKit
import ActivityKit

/// Fleet status in the four Live Activity presentations. Space degrades in one
/// direction: action, detail, machine totals, headline, count, then status mark.
/// The mark uses shape as well as colour so its meaning survives Always-On.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(
                hostLabel: context.attributes.hostLabel,
                state: context.state,
                isStale: context.isStale,
                destination: ActivityDeepLink.url(for: context.state.agentID)
            )
            .activityBackgroundTint(WidgetPalette.ground)
            .activitySystemActionForegroundColor(WidgetPalette.text)
            .widgetURL(ActivityDeepLink.url(for: context.state.agentID))
        } dynamicIsland: { context in
            let destination = ActivityDeepLink.url(for: context.state.agentID)
            let staleAttention = context.isStale || context.state.isEntirelyUnconfirmed

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedHero(state: context.state, isStale: staleAttention)
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
                    if let destination {
                        OpenAgentLink(
                            destination: destination,
                            title: "Open \(context.state.headline)",
                            dimmed: false
                        )
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                StatusMark(status: context.state.status, diameter: 10, isStale: staleAttention)
            } compactTrailing: {
                CompactCount(state: context.state)
            } minimal: {
                StatusMark(status: context.state.status, diameter: 14, isStale: staleAttention)
            }
            .keylineTint(WidgetPalette.color(context.state.status))
            .widgetURL(destination)
        }
    }
}

private struct CompactCount: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if state.needsYouCount > 0 {
            Text(displayCount(state.needsYouCount))
                .font(WidgetType.machineSemibold(13))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.waiting)
        } else if state.workingCount > 0 {
            Text(displayCount(state.workingCount))
                .font(WidgetType.machineMedium(13))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.working)
        }
    }
}

private struct ExpandedHero: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.needsYouCount > 1 {
                Text(displayCount(state.needsYouCount))
                    .font(WidgetType.machineSemibold(26))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.waiting)
                Text(isStale ? "may need you" : "need you")
                    .font(WidgetType.app(12))
                    .foregroundStyle(WidgetPalette.textDim)
                    .lineLimit(1)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if state.needsYouCount <= 1 {
                    StatusMark(
                        status: state.status,
                        diameter: 10,
                        isStale: isStale || state.isEntirelyUnconfirmed
                    )
                }
                Text(state.headline)
                    .font(WidgetType.appSemibold(16))
                    .foregroundStyle(WidgetPalette.text)
                    .lineLimit(1)
            }
            ActivityDetail(state: state, isStale: isStale, fontSize: 11)
        }
    }
}

private struct FleetTotals: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hostLabel)
            if state.workingCount > 0 {
                Text("\(state.workingCount) working")
            }
            if state.totalCount > 0 {
                Text(state.totalCount == 1 ? "1 agent" : "\(state.totalCount) agents")
            }
        }
        .font(WidgetType.machine(11))
        .foregroundStyle(WidgetPalette.textFaint)
        .lineLimit(1)
    }
}

private struct LockScreenView: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool
    let destination: URL?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if state.needsYouCount > 1 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayCount(state.needsYouCount))
                            .font(WidgetType.machineSemibold(34))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.waiting)
                        Text(staleAttention ? "may need you" : "need you")
                            .font(WidgetType.app(13))
                            .foregroundStyle(WidgetPalette.textDim)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 64, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusMark(status: state.status, diameter: 12, isStale: staleAttention)
                        Text(state.headline)
                            .font(WidgetType.appSemibold(17))
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(1)
                    }
                    ActivityDetail(state: state, isStale: isStale, fontSize: 12)
                    if !isLuminanceReduced {
                        Text(fleetLine)
                            .font(WidgetType.machine(11))
                            .foregroundStyle(WidgetPalette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if let destination {
                OpenAgentLink(
                    destination: destination,
                    title: "Open \(state.headline)",
                    dimmed: isLuminanceReduced
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var staleAttention: Bool { isStale || state.isEntirelyUnconfirmed }

    private var fleetLine: String {
        var parts = [hostLabel]
        if state.workingCount > 0 { parts.append("\(state.workingCount) working") }
        if state.totalCount > 0 {
            parts.append(state.totalCount == 1 ? "1 agent" : "\(state.totalCount) agents")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ActivityDetail: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool
    let fontSize: CGFloat

    var body: some View {
        if isStale, state.needsYouCount > 0 {
            Text("Update delayed")
                .font(WidgetType.machine(fontSize))
                .foregroundStyle(WidgetPalette.textFaint)
                .lineLimit(1)
        } else if state.status == .needsYou, let since = state.blockedSince {
            HStack(spacing: 5) {
                Text(state.isEntirelyUnconfirmed ? "May need you" : "Waiting")
                ElapsedTimer(since: since, color: WidgetPalette.waiting, fontSize: fontSize)
            }
            .font(WidgetType.machine(fontSize))
            .foregroundStyle(WidgetPalette.textDim)
            .lineLimit(1)
        } else if state.status == .working, state.workingCount == 1,
                  let since = state.workingSince {
            HStack(spacing: 5) {
                Text("Working")
                ElapsedTimer(since: since, color: WidgetPalette.working, fontSize: fontSize)
            }
            .font(WidgetType.machine(fontSize))
            .foregroundStyle(WidgetPalette.textDim)
            .lineLimit(1)
        } else {
            Text(AgentActivitySummary.line(state))
                .font(WidgetType.machine(fontSize))
                .foregroundStyle(WidgetPalette.color(state.status))
                .lineLimit(1)
        }
    }
}

private struct OpenAgentLink: View {
    let destination: URL
    let title: String
    let dimmed: Bool

    var body: some View {
        Link(destination: destination) {
            Text(title)
                .font(WidgetType.appSemibold(14))
                .foregroundStyle(dimmed ? WidgetPalette.text : WidgetPalette.ground)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    if !dimmed {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(WidgetPalette.text)
                    }
                }
                .overlay {
                    if dimmed {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(WidgetPalette.textDim, lineWidth: 1)
                    }
                }
        }
    }
}

/// Shape is the primary channel: filled = needs you, ring = working, small dot =
/// idle, barred = stopped. A stale needs-you state becomes hollow.
private struct StatusMark: View {
    let status: AgentActivityAttributes.Status
    var diameter: CGFloat = 10
    var isStale = false

    var body: some View {
        ZStack {
            switch status {
            case .needsYou:
                if isStale {
                    Circle()
                        .strokeBorder(WidgetPalette.waiting, lineWidth: lineWidth)
                } else {
                    Circle().fill(WidgetPalette.waiting)
                }
            case .working:
                Circle()
                    .strokeBorder(WidgetPalette.working, lineWidth: lineWidth)
            case .idle:
                Circle()
                    .fill(WidgetPalette.idle)
                    .frame(width: diameter * 0.46, height: diameter * 0.46)
            case .stopped:
                Circle()
                    .strokeBorder(WidgetPalette.died, lineWidth: lineWidth)
                Capsule()
                    .fill(WidgetPalette.died)
                    .frame(width: diameter * 0.72, height: lineWidth)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(accessibilityLabel)
    }

    private var lineWidth: CGFloat { max(1.5, diameter * 0.18) }

    private var accessibilityLabel: String {
        if status == .needsYou, isStale { return "May need you" }
        return status.label
    }
}

private struct ElapsedTimer: View {
    let since: Double
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        Text(Date(timeIntervalSince1970: since), style: .timer)
            .font(WidgetType.machine(fontSize))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

private enum ActivityDeepLink {
    static func url(for agentID: String?) -> URL? {
        guard let agentID, !agentID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "herdrup"
        components.host = "agent"
        components.queryItems = [URLQueryItem(name: "pane", value: agentID)]
        return components.url
    }
}

private extension AgentActivityState {
    var isEntirelyUnconfirmed: Bool {
        needsYouCount > 0 && unconfirmedCount >= needsYouCount
    }
}

private func displayCount(_ count: Int) -> String {
    count >= 100 ? "99+" : "\(max(0, count))"
}

private enum WidgetType {
    static func app(_ size: CGFloat) -> Font {
        .custom("Geist-Regular", fixedSize: size)
    }

    static func appSemibold(_ size: CGFloat) -> Font {
        .custom("Geist-SemiBold", fixedSize: size)
    }

    static func machine(_ size: CGFloat) -> Font {
        .custom("IBMPlexMono", fixedSize: size)
    }

    static func machineMedium(_ size: CGFloat) -> Font {
        .custom("IBMPlexMono-Medm", fixedSize: size)
    }

    static func machineSemibold(_ size: CGFloat) -> Font {
        .custom("IBMPlexMono-SmBld", fixedSize: size)
    }
}

enum WidgetPalette {
    static let ground      = Color(hex6: 0x13162A)
    static let text        = Color(hex6: 0xEEF0F7)
    static let textDim     = Color(hex6: 0x99A0BC)
    static let textFaint   = Color(hex6: 0x666D91)
    static let waiting     = Color(hex6: 0xE9A63C)
    static let working     = Color(hex6: 0x5B9BE8)
    static let died        = Color(hex6: 0xE2584E)
    static let idle        = textFaint

    static func color(_ status: AgentActivityAttributes.Status) -> Color {
        switch status {
        case .needsYou: return waiting
        case .working:  return working
        case .stopped:  return died
        case .idle:     return idle
        }
    }
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
