import SwiftUI
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
    /// actions, no gesture. The drag state lives in the row's own view, so a swipe redraws
    /// that row only.
    func leadingSwipeActions(_ actions: [RowSwipeAction]) -> some View {
        modifier(LeadingSwipeActions(actions: actions))
    }
}

private struct LeadingSwipeActions: ViewModifier {
    let actions: [RowSwipeAction]
    @State private var revealed = false
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.86)))
    private var drag: CGFloat = 0

    private static let actionWidth: CGFloat = 76
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.actionWidth }

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            let offset = min(max(0, (revealed ? revealWidth : 0) + drag), revealWidth + 24)
            // The actions sit behind the row, as tall as it, and show as it slides right.
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    if offset > 0 || revealed {
                        HStack(spacing: 0) {
                            ForEach(actions) { action in
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { revealed = false }
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
                    if revealed {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: offset)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { revealed = false }
                            }
                    }
                }
                .clipped()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .updating($drag) { value, state, _ in
                            guard Self.isHorizontal(value) else { return }
                            state = value.translation.width
                        }
                        .onEnded { value in
                            guard Self.isHorizontal(value) else { return }
                            let end = (revealed ? revealWidth : 0) + value.predictedEndTranslation.width
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                revealed = end > revealWidth / 2
                            }
                        }
                )
        }
    }

    private static func isHorizontal(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height) * 1.5
    }
}
