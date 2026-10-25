import SwiftUI

struct ChatComposerFade: View {
    let ground: Color

    var body: some View {
        LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
            .frame(height: 48)
            .offset(y: -48)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
