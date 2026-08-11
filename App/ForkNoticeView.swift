import SwiftUI

/// Shown once per connect when the daemon lacks the fork-only features
/// (`HerdrClient.probeFork()` == `.notFork`) — a base daemon, OR a jerryfane/herdr
/// build that predates gram (the probe can't tell them apart, so the copy says
/// "update or switch", not "you're not on the fork"). The daemon runs the terminals
/// fine; gram, push, and the live terminal are what's missing. Advisory, never a
/// lockout: "Continue anyway" always dismisses.
struct ForkNoticeView: View {
    var onDismiss: () -> Void

    /// (symbol, feature, one-line what-it-is) for each fork-only capability.
    private let missing: [(symbol: String, name: String, detail: String)] = [
        ("bubble.left.and.bubble.right", "Gram", "message your agents from here"),
        ("bell.badge", "Push notifications", "alerts when an agent needs you"),
        ("terminal", "The live terminal", "the real-time, scrollable view"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 22) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Palette.waiting)
                VStack(spacing: 8) {
                    Text("This daemon is missing the Herdr features")
                        .font(Typography.app(22, .bold))
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.center)
                    // Capability, not identity: the probe can't tell a base daemon from
                    // a jerryfane/herdr build that predates gram, so the copy must be
                    // true of BOTH — "update or switch", never "you're not on the fork".
                    Text("Your agents connect fine, but gram, push, and the live terminal need the jerryfane/herdr fork of the daemon:")
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    ForEach(missing, id: \.name) { row($0) }
                }
                Text("Switch to — or update — jerryfane/herdr to turn them on.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Text("Continue anyway")
                    .font(Typography.app(16, .semibold))
                    .foregroundStyle(Palette.ground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }

    private func row(_ item: (symbol: String, name: String, detail: String)) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.brand)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                Text(item.detail).font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
    }
}
