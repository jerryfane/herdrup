import SwiftUI
import UIKit

/// Footer action for the setup guides (`AccountsSetupView` / `FederationSetupView`): copies that guide as
/// a paste-ready instruction so the owner can hand it to any agent and have it PERFORM the setup and
/// report the steps back, instead of following the guide by hand.
///
/// Clipboard WRITE only (`UIPasteboard.general.string`, the same pattern as the "Copy diagnostics" /
/// install-command surfaces) — it never READS the pasteboard, so it does not trigger the App Store 2.1a
/// paste-permission prompt that a `UIPasteboard` read would.
struct CopyForAgentButton: View {
    let prompt: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: copy) {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    Text(copied ? "Copied — paste it to an agent" : "Copy these steps for an agent")
                        .font(Typography.app(16, .semibold))
                }
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.brand))
            }
            .buttonStyle(.plain)
            Text("Paste into any agent — it'll do it for you and tell you each step.")
                .font(Typography.app(12))
                .foregroundStyle(Palette.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        UIPasteboard.general.string = prompt
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
