import SwiftUI

/// SwiftUI caps the requested detent to the available presentation area. Long content
/// remains scrollable; measuring the content rather than the viewport also handles expansion.
struct ChatContentSheet<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        NavigationStack {
            ScrollView {
                content()
                    .padding(16)
                    .frame(maxWidth: ChatStyle.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .background(Palette.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("chat-note-done")
                }
            }
        }
        .presentationDetents([.height(contentHeight + 64), .large])
        .presentationDragIndicator(.visible)
    }
}
