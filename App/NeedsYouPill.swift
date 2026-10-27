import SwiftUI
import HerdrKit

/// Whether the agents list's waiting rows are out of sight (herdrup#551).
///
/// A reference the home view holds in `@State` WITHOUT observing it: the waiting section's
/// probe writes here, and only `NeedsYouPill` observes it. Crossing the line therefore
/// redraws the pill alone, never the list's rows (the #536 render-cost rule).
///
/// "Out of sight" is either of two things. The section is laid out but scrolled fully above
/// the list's top edge; or it is not laid out at all. The phone's list is a `LazyVStack`, and
/// a waiting section that arrives while the owner is scrolled far down is inserted above the
/// screen without ever being built, so it never reports a frame. The waiting rows always
/// sort first, so a section that is not on screen is above it.
final class NeedsYouSight: ObservableObject {
    @Published private(set) var waitingRowsOutOfSight = true
    private var laidOut = false
    private var scrolledAbove = false

    func update(laidOut: Bool) {
        self.laidOut = laidOut
        publish()
    }

    func update(scrolledAbove: Bool) {
        self.scrolledAbove = scrolledAbove
        publish()
    }

    private func publish() {
        let outOfSight = !laidOut || scrolledAbove
        guard outOfSight != waitingRowsOutOfSight else { return }
        waitingRowsOutOfSight = outOfSight
    }
}

/// The agents list's scroll view, as a coordinate space: a row's frame in it is measured from
/// the top of the visible list, just under the top bar.
let agentRosterScrollSpace = "agent-roster-scroll-space"

extension View {
    /// Reports to `sight` whether this view (the waiting section) is laid out and whether it
    /// has scrolled fully above the list's top. The geometry transform runs per scroll frame;
    /// its action only when the answer flips.
    func reportsWaitingRowsSight(to sight: NeedsYouSight) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .named(agentRosterScrollSpace)).maxY <= 0
        } action: { scrolledAbove in
            sight.update(scrolledAbove: scrolledAbove)
        }
        .onAppear { sight.update(laidOut: true) }
        .onDisappear { sight.update(laidOut: false) }
    }
}

/// The sticky "needs you" pill (proposal B): once the waiting rows are scrolled away, a small
/// pill drops in under the top bar with their avatars. With several waiting, tapping scrolls
/// back to the top; with exactly one, it names the agent and tapping opens it.
struct NeedsYouPill: View {
    @ObservedObject var sight: NeedsYouSight
    /// The agents that need you, in list order.
    let waiting: [AgentRow]
    let onScrollToTop: () -> Void
    let onOpen: (AgentRow) -> Void

    private static let avatarDiameter: CGFloat = 32
    private static let maxAvatars = 3
    private static let fill = Palette.surfaceRaised

    var body: some View {
        let shows = sight.waitingRowsOutOfSight && !waiting.isEmpty
        ZStack(alignment: .top) {
            if shows {
                pill
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shows)
    }

    private var pill: some View {
        Button {
            if waiting.count == 1, let only = waiting.first {
                onOpen(only)
            } else {
                onScrollToTop()
            }
        } label: {
            HStack(spacing: 10) {
                avatars
                label
                Image(systemName: waiting.count == 1 ? "chevron.right" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 44)
            .background(Capsule().fill(Self.fill.opacity(0.96)))
            .overlay(Capsule().strokeBorder(Palette.waiting.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("needs-you-pill")
    }

    private var avatars: some View {
        HStack(spacing: -10) {
            ForEach(waiting.prefix(Self.maxAvatars)) { row in
                AgentAvatarView(agent: row.info, name: row.title, size: Self.avatarDiameter)
                    .overlay(Circle().stroke(Self.fill, lineWidth: 2))
            }
            if waiting.count > Self.maxAvatars {
                Text("+\(waiting.count - Self.maxAvatars)")
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(Palette.text)
                    .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
                    .background(Circle().fill(Palette.surface))
                    .overlay(Circle().stroke(Self.fill, lineWidth: 2))
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if waiting.count == 1, let only = waiting.first {
            HStack(spacing: 6) {
                Text(only.title)
                    .font(Typography.app(15, .semibold))
                    .foregroundStyle(Palette.waiting)
                    .lineLimit(1)
                if let activity = only.info.activityText {
                    Text(activity)
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .leading)
                }
            }
        } else {
            Text(Self.countText(waiting.count))
                .font(Typography.app(15, .semibold))
                .foregroundStyle(Palette.waiting)
                .lineLimit(1)
        }
    }

    private var accessibilityText: String {
        if waiting.count == 1, let only = waiting.first { return "\(only.title) needs you" }
        return Self.countText(waiting.count)
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 agent needs you" : "\(count) agents need you"
    }
}
