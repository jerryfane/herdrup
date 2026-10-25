import SwiftUI

/// The glass circle that returns a scrolled-back reader to the newest content, bottom-centre
/// over the chat or the terminal. Shown only while the reader is away from the tail. An
/// overlay, not a gesture: only the circle hit-tests, so touches elsewhere reach the content.
struct JumpToLatestButton: View {
    let label: String
    let identifier: String
    /// The regular glass, for dense, high-contrast terminal text that clear glass would pass
    /// through almost unchanged. Chat keeps the clear glass over its softer prose.
    var regularGlass = false
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .modifier(GlassCircle(regular: regularGlass, reduceTransparency: reduceTransparency))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private struct GlassCircle: ViewModifier {
        let regular: Bool
        let reduceTransparency: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if reduceTransparency {
                content.background(Palette.surfaceRaised, in: Circle())
            } else if #available(iOS 26.0, *) {
                content.glassEffect((regular ? Glass.regular : Glass.clear).interactive(), in: Circle())
            } else {
                content.background(regular ? Material.regularMaterial : Material.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }
}
