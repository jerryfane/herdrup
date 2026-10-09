import SwiftUI
import UIKit

/// A command the reader is meant to run on their computer, shown on the phone so it can be
/// COPIED: the screen is a phone showing a command for a laptop, so copy-then-paste is the
/// whole point. Used by the first-run card, the pairing sheet, the fork notice and the
/// "herdr isn't running" screen, so every "run this" in the app looks and behaves the same.
///
/// Clipboard WRITE only (`UIPasteboard.general.string`), the same pattern as
/// `CopyForAgentButton`: a programmatic READ is what triggers the system paste prompt that
/// failed App Review under 2.1a.
struct CopyableCommand: View {
    let command: String
    /// Shared by every chip, so only the command that is actually on the clipboard says
    /// "Copied": copying a second command takes the receipt away from the first.
    @State private var receipt = CopiedCommandReceipt.shared

    var body: some View {
        let copied = receipt.text == command
        Button { receipt.record(command) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(command)
                    .font(Typography.machine(13)).foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Palette.done : Palette.textFaint)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairlineQuiet, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(copied ? "Copied" : "Copy command: \(command)"))
    }
}

/// The command most recently copied from a `CopyableCommand`, for a moment.
@MainActor @Observable
final class CopiedCommandReceipt {
    static let shared = CopiedCommandReceipt()
    private(set) var text: String?

    func record(_ command: String) {
        UIPasteboard.general.string = command
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        text = command
        // Revert the label rather than leaving a permanent "Copied", which would stop
        // telling the truth the moment the clipboard changed.
        #if DEBUG
        // UI-test/screenshot fixtures may spend several seconds synchronizing after the tap
        // before querying the new accessibility label. Keep the receipt visible in mock mode
        // without changing production UX timing.
        let nanoseconds: UInt64 = ScreenshotMock.mode == nil ? 1_600_000_000 : 10_000_000_000
        #else
        let nanoseconds: UInt64 = 1_600_000_000
        #endif
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            if text == command { text = nil }
        }
    }
}
