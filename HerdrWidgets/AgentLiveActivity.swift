import SwiftUI
import WidgetKit
import ActivityKit

/// The agent-session Live Activity: a lock-screen banner and the Dynamic Island
/// presentations. It renders `AgentActivityAttributes` — a status dot coloured by
/// the session's highest-priority agent, that agent's name, and a one-line summary
/// ("2 need you" / "Working" / "Idle"). Colours mirror the app's status palette
/// (amber = needs you, blue = working, red = stopped, faint = idle); the widget
/// keeps its own copy because the app's DesignSystem is app-target only.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            // Lock screen / notification-banner presentation.
            LockScreenView(hostLabel: context.attributes.hostLabel, state: context.state)
                .activityBackgroundTint(WidgetPalette.ground)
                .activitySystemActionForegroundColor(WidgetPalette.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusDot(status: context.state.status)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.hostLabel)
                        .font(.caption2)
                        .foregroundStyle(WidgetPalette.textFaint)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.headline)
                            .font(.headline)
                            .foregroundStyle(WidgetPalette.text)
                            .lineLimit(1)
                        Text(summary(context.state))
                            .font(.caption)
                            .foregroundStyle(WidgetPalette.color(context.state.status))
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                StatusDot(status: context.state.status)
            } compactTrailing: {
                // Only the count that demands action gets the scarce compact slot.
                if context.state.needsYouCount > 0 {
                    Text("\(context.state.needsYouCount)")
                        .font(.caption2).bold()
                        .foregroundStyle(WidgetPalette.color(.needsYou))
                }
            } minimal: {
                StatusDot(status: context.state.status)
            }
            .keylineTint(WidgetPalette.color(context.state.status))
        }
    }

    /// One-line summary line: prefer the actionable count, else the status word.
    private func summary(_ s: AgentActivityAttributes.ContentState) -> String {
        if s.needsYouCount > 0 { return "\(s.needsYouCount) need you" }
        if s.workingCount > 0 { return "\(s.workingCount) working" }
        return s.status.label
    }
}

/// The lock-screen / banner layout: status dot, agent name + summary, host on the
/// right. Kept compact and legible on the dark banner tint.
private struct LockScreenView: View {
    let hostLabel: String
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: state.status, diameter: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline)
                    .font(.headline)
                    .foregroundStyle(WidgetPalette.text)
                    .lineLimit(1)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(WidgetPalette.color(state.status))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(hostLabel)
                    .font(.caption)
                    .foregroundStyle(WidgetPalette.textFaint)
                    .lineLimit(1)
                if state.totalCount > 0 {
                    Text(state.totalCount == 1 ? "1 agent" : "\(state.totalCount) agents")
                        .font(.caption2)
                        .foregroundStyle(WidgetPalette.textFaint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: String {
        if state.needsYouCount > 0 { return "\(state.needsYouCount) need you" }
        if state.workingCount > 0 { return "\(state.workingCount) working" }
        return state.status.label
    }
}

/// A filled status circle. A working agent gets a soft pulse so a glance at the
/// Dynamic Island / lock screen reads "something is running" without any text;
/// every other state stays a still circle (colour carries the meaning).
///
/// Best-effort: a Live Activity is rendered from system snapshots, not a live
/// run loop, so `.symbolEffect(.pulse)` — the supported iOS 17 route — may be
/// subtle or absent on some devices. It degrades to a static dot with no change
/// to the colour contract.
private struct StatusDot: View {
    let status: AgentActivityAttributes.Status
    var diameter: CGFloat = 10

    var body: some View {
        if status == .working {
            // An indeterminate circular spinner is a SYSTEM view; Live Activities are
            // far more likely to actually animate it on the lock screen / Dynamic Island
            // than a `.symbolEffect(.pulse)` (which the snapshot renderer left static).
            // Sized to sit in the same footprint as the dot.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(WidgetPalette.color(status))
                .frame(width: diameter, height: diameter)
        } else {
            Circle()
                .fill(WidgetPalette.color(status))
                .frame(width: diameter, height: diameter)
        }
    }
}

/// The widget's own copy of the app's status palette (DesignSystem is app-only).
/// Hex values match `Palette` in App/DesignSystem.swift.
enum WidgetPalette {
    static let ground     = Color(hex6: 0x13162A)
    static let text       = Color(hex6: 0xEEF0F7)
    static let textFaint  = Color(hex6: 0x666D91)
    static let waiting    = Color(hex6: 0xE9A63C) // amber — needs you
    static let working    = Color(hex6: 0x5B9BE8) // blue — running
    static let died       = Color(hex6: 0xE2584E) // red — stopped / exited
    static let idle       = textFaint

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
    /// Builds a colour from a 0xRRGGBB literal (sRGB), matching DesignSystem's helper.
    init(hex6: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex6 >> 16) & 0xFF) / 255,
            green: Double((hex6 >> 8) & 0xFF) / 255,
            blue:  Double(hex6 & 0xFF) / 255,
            opacity: 1
        )
    }
}
