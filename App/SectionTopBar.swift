import SwiftUI

private struct SectionWindowControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sectionHasWindowControls: Bool {
        get { self[SectionWindowControlsKey.self] }
        set { self[SectionWindowControlsKey.self] = newValue }
    }
}

func sectionWindowHasControls(_ geometry: GeometryProxy) -> Bool {
    if #available(iOS 26.0, *) {
        return geometry.containerCornerInsets.topLeading.width > 0
    }
    return false
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
                content(leading: corners.topLeading.width, trailing: corners.topTrailing.width)
                    .frame(height: 44)
                    // Window controls already occupy the top row. Only full-screen
                    // sections need the usual breathing room above their capsule.
                    .offset(y: hostHasWindowControls || corners.topLeading.width > 0 ? 0 : 6)
            } else {
                content(leading: 0, trailing: 0)
                    .frame(height: 44).offset(y: 6)
            }
        }
        .frame(height: 50)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func content(leading: CGFloat, trailing: CGFloat) -> some View {
        SectionBarLayout(leadingInset: leading, trailingInset: trailing) {
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
            HStack(spacing: 0, content: self.leading)
                .padding(.horizontal, 2)
                .background(Capsule().fill(Palette.surfaceRaised))
        }
    }
}

/// Centre the title on the bar when it fits; on a narrow sidebar give controls
/// priority and move the title only far enough to prevent an overlap.
private struct SectionBarLayout: Layout {
    var leadingInset: CGFloat
    var trailingInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: 44)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let actions = subviews[1].sizeThatFits(.unspecified)
        let leading = subviews[2].sizeThatFits(.unspecified)
        let leadingWidth = leading.height > 0 ? leading.width : 0
        let titleLeading = leadingInset + (leadingWidth > 0 ? leadingWidth + 8 : 0)
        let available = max(0, bounds.width - titleLeading - trailingInset - actions.width - 8)
        let titleProposal = ProposedViewSize(width: available, height: bounds.height)
        let title = subviews[0].sizeThatFits(titleProposal)
        let titleX = max(titleLeading + title.width / 2,
                         min(bounds.width / 2, titleLeading + available - title.width / 2))
        subviews[0].place(at: CGPoint(x: bounds.minX + titleX, y: bounds.midY),
                          anchor: .center, proposal: titleProposal)
        subviews[1].place(at: CGPoint(x: bounds.maxX - trailingInset, y: bounds.midY),
                          anchor: .trailing, proposal: .unspecified)
        if leadingWidth > 0 {
            subviews[2].place(at: CGPoint(x: bounds.minX + leadingInset, y: bounds.midY),
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
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
