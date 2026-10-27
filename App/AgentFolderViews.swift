import SwiftUI
import UIKit
import HerdrKit

// Agent folders and stars in the Agents list (herdrup#552, proposal B): the folder row, its
// picture, and the swipe-right actions on an agent row.

/// A folder as one row: its agents' initials, the name and agent count, the line that says who
/// needs you, and the amber (waiting) and red (stopped) counts. Drawn to the agent card's
/// metrics so the two sit together in the list and the iPad/Mac sidebar.
struct AgentFolderRow: View {
    let summary: AgentFolderSummary
    let sidebar: Bool
    let separator: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: 20, height: 1)
            AgentFolderPicture(names: summary.members.prefix(4).map(\.title), diameter: sidebar ? 44 : 52)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.folder.name)
                        .font(.system(size: (sidebar ? 16 : 17) * Typography.scale, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(summary.agentCountText)
                        .font(Typography.app(sidebar ? 14 : 15))
                        .foregroundStyle(Palette.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if summary.waitingCount > 0 {
                        countPill(summary.waitingCount, Palette.waiting)
                    }
                    if summary.stoppedCount > 0 {
                        countPill(summary.stoppedCount, Palette.died)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(summary.isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                Text(summary.summaryLine)
                    .font(.system(size: (sidebar ? 14 : 15) * Typography.scale))
                    .foregroundStyle(summary.waitingCount > 0 ? Palette.text : Palette.textDim)
                    .lineLimit(1)
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity)
            .frame(height: (sidebar ? 80 : 86) * max(1, Typography.scale), alignment: .center)
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(Palette.hairline).frame(height: 1 / displayScale)
                        .padding(.trailing, 16)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func countPill(_ count: Int, _ fill: Color) -> some View {
        Text("\(count)")
            .font(Typography.app(13, .bold))
            .monospacedDigit()
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(fill))
    }
}

/// The folder picture: up to four of its agents' initials in a round tile.
struct AgentFolderPicture: View {
    let names: [String]
    let diameter: CGFloat

    var body: some View {
        let cell = (diameter - 17) / 2
        let columns = [GridItem(.fixed(cell), spacing: 3), GridItem(.fixed(cell), spacing: 3)]
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(AgentIdentity.glyph(forName: name))
                    .font(.system(size: cell * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: cell, height: cell)
                    .background(Circle().fill(AgentIdentity.gradient(forName: name)))
            }
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(Palette.surfaceRaised))
        .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// One action behind an agent row, revealed by swiping right.
struct RowSwipeAction: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let identifier: String
    let action: () -> Void
    var id: String { identifier }
}

extension View {
    /// Swipe right to reveal `actions` at the row's leading edge (Mail's leading swipe). No
    /// actions, no swipe. The swipe itself is `swipes`' one pan on the list's scroll view; this
    /// row observes only its own `RowSwipeController.Box`, so a swipe redraws that row only.
    func leadingSwipeActions(_ actions: [RowSwipeAction], id: String,
                             in swipes: RowSwipeController) -> some View {
        modifier(LeadingSwipeActions(actions: actions, id: id, swipes: swipes))
    }
}

private struct LeadingSwipeActions: ViewModifier {
    let actions: [RowSwipeAction]
    let id: String
    let swipes: RowSwipeController

    private static let actionWidth: CGFloat = 76
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.actionWidth }

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            let box = swipes.box(id)
            let width = revealWidth
            let offset = min(max(0, (box.revealed ? width : 0) + box.drag), width + 24)
            // The actions sit behind the row, as tall as it, and show as it slides right.
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    if offset > 0 || box.revealed {
                        HStack(spacing: 0) {
                            ForEach(actions) { action in
                                Button {
                                    swipes.close(id)
                                    action.action()
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: action.systemImage)
                                            .font(.system(size: 17, weight: .semibold))
                                        Text(action.title)
                                            .font(Typography.app(12, .semibold))
                                    }
                                    .foregroundStyle(Palette.ground)
                                    .frame(width: Self.actionWidth)
                                    .frame(maxHeight: .infinity)
                                    .background(action.tint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(action.identifier)
                            }
                        }
                    }
                }
                .overlay {
                    // While open, a tap on the row closes the actions instead of opening it.
                    if box.revealed {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: offset)
                            .onTapGesture { swipes.close(id) }
                    }
                }
                .clipped()
                // Where the row is in the list's content, for the list's pan to find it. A
                // frame in content coordinates does not move while the list scrolls, so this
                // costs nothing per scroll frame, and the write invalidates no view.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(agentRosterContentSpace))
                } action: { frame in
                    swipes.place(id, frame: frame, revealWidth: width)
                }
                .onDisappear { swipes.remove(id) }
        }
    }
}

/// The swipe-right gesture of the Agents list's rows (herdrup#552): ONE horizontal
/// `UIPanGestureRecognizer` on the list's `UIScrollView`, like a table view's swipe, rather
/// than a gesture on every row.
///
/// A gesture on each row hung the app. With a `UIGestureRecognizerRepresentable` pan on every
/// agent row, the first vertical scroll of the folders list froze the main thread for good the
/// moment the finger lifted (CI run 40510969880: the screen recording stops at the synthesized
/// swipe's end, and every later UI query timed out). A SwiftUI `DragGesture` on the rows
/// instead never saw a swipe inside the ScrollView (run 40477652920). This pan is UIKit's
/// alone: SwiftUI's gesture graph never sees it, the scroll view's own pan runs beside it
/// untouched, and it begins only for a sideways swipe that starts on a row with actions.
///
/// Not observable itself: each row observes its own `Box`, so a swipe redraws one row.
@MainActor
final class RowSwipeController: NSObject, UIGestureRecognizerDelegate {
    /// One row's swipe: how far the finger has moved it, and whether its actions are open.
    @Observable @MainActor
    final class Box {
        var drag: CGFloat = 0
        var revealed = false
    }

    private struct Place {
        var frame: CGRect
        var revealWidth: CGFloat
    }

    private var boxes: [String: Box] = [:]
    private var places: [String: Place] = [:]
    private weak var scrollView: UIScrollView?
    private var pan: UIPanGestureRecognizer?
    /// The row under the pan in progress.
    private var swiping: String?

    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// The row's box, made on first use. A plain dictionary write: it invalidates nothing.
    func box(_ id: String) -> Box {
        if let box = boxes[id] { return box }
        let box = Box()
        boxes[id] = box
        return box
    }

    func place(_ id: String, frame: CGRect, revealWidth: CGFloat) {
        places[id] = Place(frame: frame, revealWidth: revealWidth)
    }

    func remove(_ id: String) {
        places[id] = nil
        boxes[id] = nil
        if swiping == id { swiping = nil }
    }

    func close(_ id: String) {
        guard let box = boxes[id], box.revealed || box.drag != 0 else { return }
        withAnimation(Self.spring) {
            box.revealed = false
            box.drag = 0
        }
    }

    /// Puts the pan on the list's scroll view; called from the list's display-link sample, so
    /// it costs a pointer comparison per frame once attached.
    func attach(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        scrollView.addGestureRecognizer(pan)
        self.pan = pan
        self.scrollView = scrollView
    }

    /// The row with actions at `point` (the list's content coordinates). Rows are full width,
    /// so only the height decides.
    private func row(at point: CGPoint) -> String? {
        places.first { $0.value.frame.minY <= point.y && point.y < $0.value.frame.maxY }?.key
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .began:
            guard let id = row(at: pan.location(in: pan.view)) else { return }
            // One row open at a time, like Mail.
            for (other, box) in boxes where other != id && (box.revealed || box.drag != 0) {
                withAnimation(Self.spring) {
                    box.revealed = false
                    box.drag = 0
                }
            }
            swiping = id
            box(id).drag = translation
        case .changed:
            guard let id = swiping else { return }
            box(id).drag = translation
        case .ended:
            guard let id = swiping, let width = places[id]?.revealWidth else { return }
            swiping = nil
            // Where a flick would carry the row, as SwiftUI's predictedEndTranslation does.
            let predicted = translation + pan.velocity(in: pan.view).x * 0.2
            let box = self.box(id)
            withAnimation(Self.spring) {
                box.revealed = (box.revealed ? width : 0) + predicted > width / 2
                box.drag = 0
            }
        case .cancelled, .failed:
            guard let id = swiping else { return }
            swiping = nil
            let box = self.box(id)
            withAnimation(Self.spring) { box.drag = 0 }
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Only a sideways swipe that starts on a row with actions; anything else stays the list's.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pan, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        return row(at: pan.location(in: view)) != nil
    }

    /// The scroll view's own pan is left exactly as it is.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scrollView?.panGestureRecognizer
    }
}
