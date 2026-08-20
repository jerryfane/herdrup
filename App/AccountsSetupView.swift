import SwiftUI

/// A short guide for adding another subscription (account) on the home box — what
/// the Accounts section in Settings links to when you tap "How to set up accounts".
/// Accounts are login folders on the box, not in the app; this teaches the four
/// steps that make a new subscription show up here and become swappable from an
/// agent's menu. Presented as a `.large` sheet, mirroring `FederationSetupView`
/// (same `onClose` contract, header, cards, footer).
struct AccountsSetupView: View {
    var onClose: () -> Void

    /// One setup step: the SF Symbol hinting the action, what you do, and why.
    private struct Step: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private static let steps: [Step] = [
        .init(symbol: "folder.badge.plus",
              title: "Make a folder for it",
              detail: "Each subscription lives in its own config-home folder on your box — e.g. ~/.codex-work or ~/.claude-2. One folder per account keeps their logins separate."),
        .init(symbol: "person.badge.key",
              title: "Log in pointed at that folder",
              detail: "Run the harness with its config-home env var set, then sign in (see the commands below). That writes the login into the folder, not your default one."),
        .init(symbol: "doc.badge.gearshape",
              title: "Register it in your config",
              detail: "Add an [[accounts]] block to ~/.config/herdr/config.toml with an id, kind, label, and config_dir (the folder path)."),
        .init(symbol: "arrow.clockwise",
              title: "Reload — no restart",
              detail: "Run herdr server reload-config on the home box. The account appears here, and each agent's menu lets you swap onto it."),
    ]

    /// The per-harness login commands step 2 describes, as a mono chip.
    private static let loginSnippet = """
    # Codex
    CODEX_HOME=~/.codex-work codex
    # Claude (then /login)
    CLAUDE_CONFIG_DIR=~/.claude-2 claude
    # Kimi
    KIMI_CODE_HOME=~/.kimi-work kimi
    """

    /// The [[accounts]] stanza step 3 describes.
    private static let configSnippet = """
    [[accounts]]
    id = "codex-work"
    kind = "codex"
    label = "Codex · work"
    config_dir = "/root/.codex-work"
    """

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.steps) { row(for: $0) }
                    monoCard(caption: "Log in pointed at the folder", body: Self.loginSnippet)
                    monoCard(caption: "~/.config/herdr/config.toml", body: Self.configSnippet)
                    monoCard(caption: "Then, on the home box", body: "herdr server reload-config")
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
                Text("Set up an account")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("Add another subscription on your box")
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

    private func row(for step: Step) -> some View {
        HStack(spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.brand)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(Typography.app(15, .semibold))
                    .foregroundStyle(Palette.text)
                Text(step.detail)
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

    /// A captioned mono chip (matches FederationSetupView's config/reload cards).
    private func monoCard(caption: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text(body)
                .font(Typography.machine(13))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surfaceRaised))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
    }

    private var footer: some View {
        Button(action: onClose) {
            Text("Got it")
                .font(Typography.app(15, .semibold))
                .foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Palette.ground)
    }
}
