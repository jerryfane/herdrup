import SwiftUI

/// Fades the rows scrolled under the composer into the ground. ChatView draws it at its own
/// bottom edge, which is the top of the composer band, and only while rows lie under it.
struct ChatComposerFade: View {
    let ground: Color

    var body: some View {
        LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
            .frame(height: 48)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
