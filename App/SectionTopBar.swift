import SwiftUI

/// Where the iPad's inline window controls (●●●) sit, in global coordinates: the top-left
/// corner the window reserves for them. nil in full screen and on iPhone.
struct SectionWindowControls: Equatable {
    /// The reserved corner's top edge and height. The system draws the controls' pill
    /// half this height, centred in it (measured on iPadOS 26.5: a 43 pt corner holds a
    /// 21.5 pt pill whose top and bottom sit 10.75 pt inside).
    var top: CGFloat
    var height: CGFloat

    var centerY: CGFloat { top + height / 2 }
    var pillHeight: CGFloat { height / 2 }
}

private struct SectionWindowControlsKey: EnvironmentKey {
    static let defaultValue: SectionWindowControls? = nil
}

private struct SectionBackLeadsKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SectionBarRowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 44
}

extension EnvironmentValues {
    /// Set where the window's corner insets are still visible (NavigationSplitView
    /// consumes them before its sidebar sees any), so the bar inside can line up.
    var sectionWindowControls: SectionWindowControls? {
        get { self[SectionWindowControlsKey.self] }
        set { self[SectionWindowControlsKey.self] = newValue }
    }
    /// Set by `SectionTopBar` for its own content: whether Back belongs on the left.
    fileprivate(set) var sectionBackLeads: Bool {
        get { self[SectionBackLeadsKey.self] }
        set { self[SectionBackLeadsKey.self] = newValue }
    }
    /// Set by `SectionTopBar`: the height of its capsules. 44 normally; in an iPad window
    /// they match the window controls' pill.
    fileprivate(set) var sectionBarRowHeight: CGFloat {
        get { self[SectionBarRowHeightKey.self] }
        set { self[SectionBarRowHeightKey.self] = newValue }
    }
}

/// The window controls' corner as `geometry` sees it, nil when there is none.
func sectionWindowControls(_ geometry: GeometryProxy) -> SectionWindowControls? {
    if #available(iOS 26.0, *) {
        let corner = geometry.containerCornerInsets.topLeading
        guard corner.width > 0, corner.height > 0 else { return nil }
        return SectionWindowControls(top: geometry.frame(in: .global).minY, height: corner.height)
    }
    return nil
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
    @Environment(\.sectionWindowControls) private var hostWindowControls

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
                // The bar's own insets when it sits directly in the window; else what the
                // host passed down from outside the split view, but only for a bar that
                // starts on the controls' row (a sheet's bar further down does not).
                let barTop = geometry.frame(in: .global).minY
                let controls = sectionWindowControls(geometry)
                    ?? hostWindowControls.flatMap { barTop < $0.top + $0.height ? $0 : nil }
                let windowed = controls != nil
                // Mac keeps its window controls in their own row above the bar.
                let sharesRow = windowed && !ProcessInfo.processInfo.isiOSAppOnMac
                let row = DesignTokens.Size.topBarRow
                let rowHeight = sharesRow ? max(20, (controls?.pillHeight ?? row).rounded()) : row
                content(leading: corners.topLeading.width, trailing: corners.topTrailing.width,
                        windowed: windowed, rowHeight: rowHeight)
                    .frame(height: rowHeight)
                    // In an iPad window the capsules take the controls' pill height and
                    // centre, so their tops and bottoms line up and keep the same margin
                    // from the panel's edge. Full screen keeps the usual 6 pt above.
                    .offset(y: sharesRow
                        ? Self.rowOffset(centerY: controls!.centerY - geometry.frame(in: .global).minY,
                                         rowHeight: rowHeight)
                        : (windowed ? 0 : 6))
            } else {
                content(leading: 0, trailing: 0, windowed: false, rowHeight: DesignTokens.Size.topBarRow)
                    .frame(height: DesignTokens.Size.topBarRow).offset(y: 6)
            }
        }
        .frame(height: DesignTokens.Size.topBar)
        .padding(.horizontal, DesignTokens.Space.screenInset)
        .padding(.bottom, 8)
    }

    /// Offset that centres a `rowHeight` row on `centerY`, a point in the bar's own
    /// coordinates; never above the bar.
    static func rowOffset(centerY: CGFloat, rowHeight: CGFloat) -> CGFloat {
        max(0, centerY - rowHeight / 2)
    }

    private func content(leading: CGFloat, trailing: CGFloat, windowed: Bool, rowHeight: CGFloat) -> some View {
        let backLeads = UIDevice.current.userInterfaceIdiom != .pad
            || ProcessInfo.processInfo.isiOSAppOnMac
            || !windowed
        return SectionBarLayout(leadingInset: leading, trailingInset: trailing) {
            HStack(spacing: 0, content: self.leading)
                .padding(.horizontal, 2)
                .background(Capsule().fill(Palette.surfaceRaised))
            HStack(spacing: DesignTokens.Space.stackSmall) {
                Text(title)
                    .font(Typography.app(DesignTokens.Text.BarTitle.size, DesignTokens.Text.BarTitle.weight))
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

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .sectionBarSlot()
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// Sizes one control in a `SectionTopBar` capsule: 40 pt wide and as tall as the bar's
    /// row, which an iPad window shrinks to its controls' height. Apply it INSIDE a
    /// Button's label: that is what hit-tests.
    func sectionBarSlot() -> some View { modifier(SectionBarSlot()) }
}

/// Read here, where the control sits in the bar, not in the view that built it: the bar
/// sets the row height on its own content.
private struct SectionBarSlot: ViewModifier {
    @Environment(\.sectionBarRowHeight) private var rowHeight

    func body(content: Content) -> some View {
        content
            // A row shorter than 44 (an iPad window) gets slightly smaller glyphs, like
            // the controls beside it.
            .scaleEffect(rowHeight < 44 ? 13.0 / 15.0 : 1)
            .frame(width: 40, height: rowHeight)
            // A short row keeps a 44 pt tap target by growing it up and down only;
            // growing sideways would hand a neighbour's taps to this control.
            .contentShape(VerticalBand(extra: max(0, (44 - rowHeight) / 2)))
    }
}

private struct VerticalBand: Shape {
    let extra: CGFloat
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -extra)) }
}
