import SwiftUI

private struct SectionWindowControlsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SectionBackLeadsKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SectionBarRowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 44
}

extension EnvironmentValues {
    var sectionHasWindowControls: Bool {
        get { self[SectionWindowControlsKey.self] }
        set { self[SectionWindowControlsKey.self] = newValue }
    }
    /// Set by `SectionTopBar` for its own content: whether Back belongs on the left.
    fileprivate(set) var sectionBackLeads: Bool {
        get { self[SectionBackLeadsKey.self] }
        set { self[SectionBackLeadsKey.self] = newValue }
    }
    /// Set by `SectionTopBar`: the height of its capsules. 44 normally; in an iPad window
    /// they share the row with the window controls and take that row's height.
    fileprivate(set) var sectionBarRowHeight: CGFloat {
        get { self[SectionBarRowHeightKey.self] }
        set { self[SectionBarRowHeightKey.self] = newValue }
    }
}

func sectionWindowHasControls(_ geometry: GeometryProxy) -> Bool {
    if #available(iOS 26.0, *) {
        return geometry.containerCornerInsets.topLeading.width > 0
    }
    return false
}

/// Where Back goes in a `SectionTopBar`. Put one in `leading` and one in `actions`;
/// the bar shows the one that fits the window: the left on iPhone, on Mac (whose window
/// controls have their own row) and on a full-screen iPad; the right-hand capsule on an
/// iPad window, whose controls take the top-left corner.
struct SectionBackSlot<Content: View>: View {
    enum Side { case leading, trailing }
    let side: Side
    @ViewBuilder var content: () -> Content
    @Environment(\.sectionBackLeads) private var backLeads

    init(_ side: Side, @ViewBuilder content: @escaping () -> Content) {
        self.side = side
        self.content = content
    }

    var body: some View {
        if backLeads == (side == .leading) { content() }
    }
}

/// Shared section chrome. Mac can place Back below its separate window-title row;
/// iPad keeps that corner clear for its inline system window controls.
struct SectionTopBar<Leading: View, Actions: View>: View {
    let title: String
    var count: Int = 0
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions
    @Environment(\.sectionHasWindowControls) private var hostHasWindowControls

    init(title: String, count: Int = 0,
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.count = count
        self.leading = leading
        self.actions = actions
    }

    var body: some View {
        GeometryReader { geometry in
            if #available(iOS 26.0, *) {
                let corners = geometry.containerCornerInsets
                let windowed = hostHasWindowControls || corners.topLeading.width > 0
                // Mac keeps its window controls in their own row above the bar.
                let sharesRow = windowed && !ProcessInfo.processInfo.isiOSAppOnMac
                let rowHeight = sharesRow ? Self.windowRowHeight(corners.topLeading.height) : 44
                content(leading: corners.topLeading.width, trailing: corners.topTrailing.width,
                        windowed: windowed, rowHeight: rowHeight)
                    .frame(height: rowHeight)
                    // In an iPad window the controls already sit on this row: line the
                    // capsules up with them, inside the window's top edge. Full screen
                    // keeps the usual breathing room above the capsule.
                    .offset(y: sharesRow ? Self.windowRowOffset(corners.topLeading.height) : (windowed ? 0 : 6))
            } else {
                content(leading: 0, trailing: 0, windowed: false, rowHeight: 44)
                    .frame(height: 44).offset(y: 6)
            }
        }
        .frame(height: 50)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The capsules' height in a window: the window controls' row minus a margin above
    /// and below, so a capsule never touches the window's top edge. 44 when unknown.
    static func windowRowHeight(_ controlsHeight: CGFloat) -> CGFloat {
        controlsHeight > 0 ? min(44, max(30, controlsHeight - 2 * windowRowInset)) : 44
    }

    static func windowRowOffset(_ controlsHeight: CGFloat) -> CGFloat {
        controlsHeight > 0 ? windowRowInset : 0
    }

    private static var windowRowInset: CGFloat { 6 }

    private func content(leading: CGFloat, trailing: CGFloat, windowed: Bool, rowHeight: CGFloat) -> some View {
        let backLeads = UIDevice.current.userInterfaceIdiom != .pad
            || ProcessInfo.processInfo.isiOSAppOnMac
            || !windowed
        return SectionBarLayout(leadingInset: leading, trailingInset: trailing) {
            HStack(spacing: 0, content: self.leading)
                .padding(.horizontal, 2)
                .background(Capsule().fill(Palette.surfaceRaised))
            HStack(spacing: 6) {
                Text(title)
                    .font(Typography.app(17, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if count > 0 {
                    Text("\(count)")
                        .font(Typography.machine(11, .semibold))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.waiting))
                        .accessibilityLabel("\(count) unread")
                }
            }
            HStack(spacing: 0, content: actions)
                .padding(.horizontal, 2)
                .background(Capsule().fill(Palette.surfaceRaised))
        }
        .environment(\.sectionBackLeads, backLeads)
        .environment(\.sectionBarRowHeight, rowHeight)
    }
}

/// Centre the title on the bar when it fits; on a narrow sidebar give controls
/// priority and move the title only far enough to prevent an overlap.
private struct SectionBarLayout: Layout {
    var leadingInset: CGFloat
    var trailingInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 44)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let actions = subviews[2].sizeThatFits(.unspecified)
        let leading = subviews[0].sizeThatFits(.unspecified)
        let leadingWidth = leading.height > 0 ? leading.width : 0
        let titleLeading = leadingInset + (leadingWidth > 0 ? leadingWidth + 8 : 0)
        let available = max(0, bounds.width - titleLeading - trailingInset - actions.width - 8)
        let titleProposal = ProposedViewSize(width: available, height: bounds.height)
        let title = subviews[1].sizeThatFits(titleProposal)
        let titleX = max(titleLeading + title.width / 2,
                         min(bounds.width / 2, titleLeading + available - title.width / 2))
        subviews[1].place(at: CGPoint(x: bounds.minX + titleX, y: bounds.midY),
                          anchor: .center, proposal: titleProposal)
        subviews[2].place(at: CGPoint(x: bounds.maxX - trailingInset, y: bounds.midY),
                          anchor: .trailing, proposal: .unspecified)
        if leadingWidth > 0 {
            subviews[0].place(at: CGPoint(x: bounds.minX + leadingInset, y: bounds.midY),
                              anchor: .leading, proposal: .unspecified)
        }
    }
}

struct SectionBarButton: View {
    let icon: String
    let label: String
    var identifier: String = ""
    var action: () -> Void
    @Environment(\.sectionBarRowHeight) private var rowHeight

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 40, height: rowHeight)
                // The capsule may shrink to the window controls' row; the tap target keeps
                // at least 44 pt.
                .contentShape(Rectangle().inset(by: -max(0, (44 - rowHeight) / 2)))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
