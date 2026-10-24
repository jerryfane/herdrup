import SwiftUI

struct ChatLatestButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .modifier(ClearCircle(reduceTransparency: reduceTransparency))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest message")
        .accessibilityIdentifier("chat-jump-latest")
    }

    private struct ClearCircle: ViewModifier {
        let reduceTransparency: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if reduceTransparency {
                content.background(Palette.surfaceRaised, in: Circle())
            } else if #available(iOS 26.0, *) {
                content.glassEffect(.clear.interactive(), in: Circle())
            } else {
                content.background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }
}
