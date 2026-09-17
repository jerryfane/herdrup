import Combine
import GameController
import HerdrKit
import SwiftUI
import UIKit

/// Geometry shared by the Terminal and Gram composers, from the approved HTML.
enum ComposerStyle {
    static let fontSize: CGFloat = 16
    static var lineHeight: CGFloat { 24 * Typography.scale }
}

struct ComposerSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(11) // 10 points of content padding plus the HTML's one-point border.
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct ComposerActionIcon: View {
    let symbol: String
    var primary = false
    var busy = false

    var body: some View {
        ZStack {
            Circle().fill(primary ? Palette.text : Palette.surfaceRaised)
                .frame(width: 40, height: 40)
            if busy {
                ProgressView().tint(primary ? Palette.ground : Palette.textDim)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(primary ? Palette.ground : Palette.textDim)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}

enum ComposerAttachmentState {
    case ready
    case waiting
    case uploading(sent: Int, total: Int)
    case sending
    case sent
    case failed

    var progress: Double? {
        guard case let .uploading(sent, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(total)))
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    var isIndeterminate: Bool {
        switch self {
        case .sending: return true
        case .uploading(_, let total): return total <= 0
        default: return false
        }
    }

    func label(size: Int) -> String {
        let sizeLabel = GramFile.displaySize(of: UInt64(max(0, size)))
        switch self {
        case .ready: return "\(sizeLabel) · Ready"
        case .waiting: return "\(sizeLabel) · Waiting"
        case .uploading:
            guard let progress else { return "Uploading…" }
            return "\(Int((progress * 100).rounded()))% · \(sizeLabel)"
        case .sending: return "Sending…"
        case .sent: return "Sent · \(sizeLabel)"
        case .failed: return "Failed · tap send to retry"
        }
    }
}

struct ComposerAttachmentChip: View {
    let name: String
    let size: Int
    let isImage: Bool
    let state: ComposerAttachmentState
    let canRemove: Bool
    let onRemove: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var hoveringRemove = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if let progress = state.progress {
                    Circle().stroke(Palette.hairline, lineWidth: 2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Palette.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else if state.isIndeterminate {
                    ComposerProgressRing()
                }
                Image(systemName: state.isSent ? "checkmark" : state.isFailed ? "exclamationmark.circle" : isImage ? "photo" : "doc")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(state.isFailed ? Palette.died : state.isSent ? Palette.text : Palette.textDim)
            }
            .padding(2)
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Typography.app(12))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(height: 18 * Typography.scale, alignment: .leading)
                Text(state.label(size: size)).font(Typography.app(10))
                    .foregroundStyle(state.isFailed ? Palette.died : Palette.textDim)
                    .monospacedDigit().lineLimit(1)
                    .frame(height: 15 * Typography.scale, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(hoveringRemove && canRemove ? Palette.text : Palette.textDim)
                    .frame(width: 24, height: 24)
                    .background(hoveringRemove && canRemove ? Palette.surface : .clear, in: Circle())
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.25)
            .onHover { hoveringRemove = $0 }
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 9)
        .frame(width: sizeClass == .compact ? 218 : 228)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct ComposerProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: 0.23)
                .stroke(Palette.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 270 : -90))
                .animation(reduceMotion ? nil : .linear(duration: 1.3).repeatForever(autoreverses: false),
                           value: spinning)
        }
        .onAppear { spinning = true }
    }
}

/// Focus alone does not prove a software keyboard is on screen (notably on iPad).
@MainActor
final class ComposerKeyboard: ObservableObject {
    @Published private(set) var isVisible = false
    private var keyboardFrame = CGRect.zero
    private var observations: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                keyboardFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                updateVisibility()
            }.store(in: &observations)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.keyboardFrame = .zero
                self?.updateVisibility()
            }.store(in: &observations)
        center.publisher(for: .GCKeyboardDidConnect)
            .merge(with: center.publisher(for: .GCKeyboardDidDisconnect))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &observations)
    }

    private func updateVisibility() {
        isVisible = !ProcessInfo.processInfo.isiOSAppOnMac
            && GCKeyboard.coalesced == nil
            && !keyboardFrame.isEmpty
            && keyboardFrame.intersects(UIScreen.main.bounds)
    }
}
