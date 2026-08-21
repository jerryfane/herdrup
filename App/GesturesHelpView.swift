import SwiftUI

/// A first-run tutorial that teaches the app's gestures — the ones that aren't
/// obvious because they have no on-screen affordance (swipe between agents, edge
/// swipe back, double-tap to tail, press-and-hold to act). Shown once on first
/// launch (gated by `@AppStorage("hasSeenGesturesHelp")`) and re-openable any time
/// from the "Gestures" tab. Presented through the app's single `activeCover` sheet,
/// so it inherits the swipe-down-to-dismiss grabber like Settings and Gram.
struct GesturesHelpView: View {
    var onClose: () -> Void

    /// One taught gesture: the SF Symbol hinting the motion, what you do, and what
    /// it does. Kept in one list so the tutorial and the real behavior stay together.
    private struct Gesture: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }  // titles are unique + stable → stable ForEach identity
    }

    private static let gestures: [Gesture] = [
        .init(symbol: "hand.tap",
              title: "Tap an agent",
              detail: "Opens its live terminal."),
        .init(symbol: "arrow.left.and.right",
              title: "Swipe left or right",
              detail: "Moves to the next or previous agent's terminal."),
        .init(symbol: "chevron.backward",
              title: "Swipe in from the left edge",
              detail: "Goes back to the agents list."),
        .init(symbol: "arrow.down.to.line",
              title: "Double-tap the terminal",
              detail: "Jumps to the newest output."),
        .init(symbol: "arrow.up.and.down",
              title: "Drag up and down",
              detail: "Scrolls back through the terminal history."),
        .init(symbol: "hand.point.up.left",
              title: "Press and hold an agent",
              detail: "Stops it."),
        .init(symbol: "trash",
              title: "Press and hold a message in Gram",
              detail: "Deletes it, and its file, for good."),
        .init(symbol: "arrow.clockwise",
              title: "Pull down in Gram",
              detail: "Refreshes the messages."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.gestures) { row(for: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            footer
        }
        .background(Palette.ground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gestures")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("How to move around Herdr")
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.textFaint)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textDim)
                    .frame(width: 36, height: 36)
                    .background(Palette.surface)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func row(for gesture: Gesture) -> some View {
        HStack(spacing: 14) {
            Image(systemName: gesture.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.brand)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                Text(gesture.title)
                    .font(Typography.app(15, .semibold))
                    .foregroundStyle(Palette.text)
                Text(gesture.detail)
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
    }

    private var footer: some View {
        Button(action: onClose) {
            Text("Got it")
                .font(Typography.app(16, .semibold))
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                // Neutral, on-style: a raised surface with a hairline, not the stark
                // ink fill the design reserves for primary actions (Connect/Approve).
                // "Got it" is a dismiss, so it should recede into the dark palette.
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Palette.ground)
    }
}
