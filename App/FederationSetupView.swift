import SwiftUI

/// A short guide for adding another machine to the herd — the setup the Federation
/// section in Settings links to when you tap "How to add a machine". Federation lets
/// your home box reach agents running on OTHER computers (over Tailscale / SSH) and
/// list them here beside the local ones. This teaches the four steps that make a new
/// machine's agents show up. Presented as a `.large` sheet with a swipe-down grabber,
/// mirroring `GesturesHelpView` (same `onClose` contract, header, footer).
struct FederationSetupView: View {
    var onClose: () -> Void

    /// One setup step: the SF Symbol hinting the action, what you do, and why.
    /// Kept in one list so the guide and the real procedure stay together.
    private struct Step: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }  // titles are unique + stable → stable ForEach identity
    }

    private static let steps: [Step] = [
        .init(symbol: "arrow.down.circle",
              title: "Install the herdr fork",
              detail: "On the machine, install the jerryfane/herdr fork; it has the api-bridge the home box connects through. Official herdr does not."),
        .init(symbol: "network",
              title: "Put it on your network",
              detail: "Join it to your Tailscale tailnet (or any address your home box can reach) and authorize your home box's SSH key."),
        .init(symbol: "doc.badge.gearshape",
              title: "Add it to your config",
              detail: "Add a peer to ~/.config/herdr/config.toml: an alias and ssh://user@host."),
        .init(symbol: "arrow.clockwise",
              title: "Reload, no restart",
              detail: "Run herdr server reload-config on the home box. The machine's agents appear here; no restart needed."),
    ]

    /// The config snippet the third step describes, shown as a mono chip.
    private static let configSnippet = """
    [[federation.peers]]
    alias = "mac-studio"
    endpoint = "ssh://user@mac-studio"
    """

    /// The whole guide as a paste-ready instruction for an agent — built from the SAME config snippet
    /// shown above so the on-screen steps and the copied text can never drift. Handed to
    /// `CopyForAgentButton`; the owner pastes it to an agent to have the machine added for them.
    static let agentPrompt = """
    Add another machine to my herd so its agents show up in the herdr app, and walk me through each step as you do it.

    1. Install the jerryfane/herdr fork on the machine — it has the api-bridge my home box connects through (official herdr does not).
    2. Put it on my network: join it to my Tailscale tailnet (or any address my home box can reach) and authorize my home box's SSH key on it.
    3. Add it as a peer in ~/.config/herdr/config.toml:
    \(Self.configSnippet)
    4. Apply it with no restart:
    herdr server reload-config

    First ask me the machine's alias and its ssh user@host (Tailscale IP or name), then carry it out and tell me the exact steps and commands you ran.
    """

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.steps) { row(for: $0) }
                    configCard
                    reloadCard
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
                Text("Add a machine")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("Connect another computer to the herd")
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

    /// The peer stanza to paste into config.toml — machine voice in a raised chip,
    /// the same mono-chip idiom the shortcuts / keycap surfaces use.
    private var configCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("~/.config/herdr/config.toml")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text(Self.configSnippet)
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

    /// The reload command — the one step that makes the new peer's agents appear,
    /// no restart. Same mono chip as the config snippet.
    private var reloadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Then, on the home box")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text("herdr server reload-config")
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
        VStack(spacing: 8) {
            CopyForAgentButton(prompt: Self.agentPrompt)
            // Send them to the fork's install instructions (step 1), reusing the one
            // shared install link the fork notice uses.
            InstallInstructionsLink()
            Button(action: onClose) {
                Text("Got it")
                    .font(Typography.app(15, .semibold))
                    .foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Palette.ground)
    }
}
