import SwiftUI
import UIKit
import HerdrKit

/// Whether the agents list's waiting rows are out of sight (herdrup#551).
///
/// A reference the home view holds in `@State` WITHOUT observing it; only `NeedsYouPill`
/// observes it, so crossing the line redraws the pill alone, never the list's rows (the #536
/// render-cost rule).
///
/// NOTHING HERE PUBLISHES FROM INSIDE A SWIFTUI UPDATE. The first version flipped this from
/// the waiting section's `onAppear` / `onDisappear` / scroll-space `onGeometryChange` actions,
/// which run inside SwiftUI's graph update. A session switch (which tears the home down and
/// mounts a new one) then hung the main thread for good: the screen froze, and every UI test
/// query timed out. Now the section only records where its bottom is in the list's content
/// (a plain stored value: writing it invalidates nothing), and the roster's display-link
/// sample of the real `UIScrollView` (`ScrollActivityObserver.onSample`, outside any
/// SwiftUI transaction) compares that with the scroll offset and publishes a flip.
@MainActor
final class NeedsYouSight: ObservableObject {
    @Published private(set) var waitingRowsOutOfSight = false
    /// The waiting section's bottom edge in the list's content coordinates; nil until it has
    /// been laid out. The waiting rows sort first, so a section the lazy list has not built
    /// keeps its last bottom, which is where it still is.
    ///
    /// Nil while the list is scrolled down means the section was inserted above the screen
    /// and the lazy list never built it (an agent started waiting while the owner was further
    /// down): it is out of sight, the case herdrup#551 exists for.
    var waitingRowsBottom: CGFloat?
    private weak var scrollView: UIScrollView?

    /// Called from the roster's display-link sample, once per frame while the list is visible.
    func sample(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
        let outOfSight: Bool
        let scrolledDown = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if let bottom = waitingRowsBottom {
            outOfSight = scrolledDown >= bottom
        } else {
            outOfSight = scrolledDown > 1
        }
        guard outOfSight != waitingRowsOutOfSight else { return }
        waitingRowsOutOfSight = outOfSight
    }

    /// Scrolls the list back to its top, where the waiting rows are.
    func scrollToTop() {
        guard let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                                    animated: true)
    }
}

/// The agents list's scroll CONTENT, as a coordinate space: a frame in it does not move when
/// the list scrolls, so measuring in it costs nothing per scroll frame.
let agentRosterContentSpace = "agent-roster-content-space"

extension View {
    /// Records this view's (the waiting section's) bottom edge in the list's content in
    /// `sight`. The write is to a plain property, so it cannot invalidate any view.
    func reportsWaitingRowsBottom(to sight: NeedsYouSight) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(agentRosterContentSpace)).maxY
        } action: { bottom in
            sight.waitingRowsBottom = bottom
        }
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
