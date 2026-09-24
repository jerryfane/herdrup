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
              title: "Install Herdr",
              detail: "Install the jerryfane/herdr fork on the other machine and start its Herdr server."),
        .init(symbol: "network",
              title: "Connect over SSH",
              detail: "Join it to your Tailscale tailnet (or another reachable network), check its SSH host key, and authorize your home box's SSH public key."),
        .init(symbol: "desktopcomputer",
              title: "Save the machine",
              detail: "On your home box run the command below. It saves an SSH profile without granting continuous federation access."),
        .init(symbol: "point.3.connected.trianglepath.dotted",
              title: "Opt in explicitly",
              detail: "Tap Federate beside the saved machine here, or run herdr machine federate <label> on the home box. A remote identity change fails closed."),
    ]

    private static let addCommand = "herdr machine add --label mac-studio user@mac-studio"
    /// A paste-ready instruction for an agent; it matches the on-screen
    /// saved-machine and explicit federation steps.
    static let agentPrompt = """
    Add another machine to my Herdr federation so its agents show up in HerdrUp.

    1. Install the jerryfane/herdr fork on that machine and start its Herdr server.
    2. Connect it over Tailscale or another trusted network. Check its SSH host key and authorize my home box's SSH public key.
    3. On my home box, save a profile: \(Self.addCommand)
    4. After confirming the target, opt it in with `herdr machine federate mac-studio` (or the Federate button in HerdrUp Settings). Check `herdr machine status` for reachability.

    Ask me for the machine label and SSH user@host first. Explain that continuous federation gives the home box full SSH authority over that Herdr session; do not copy private keys.
    """


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairlineQuiet)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.steps) { row(for: $0) }
                    addCard
                    federateCard
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

    /// Command to save a machine without granting it continuous access.
    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the home box")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text(Self.addCommand)
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

    /// Federation stays opt-in after a profile has been saved.
    private var federateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Then, on the home box")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
            Text("herdr machine federate mac-studio")
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
