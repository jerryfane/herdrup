import SwiftUI
import HerdrKit

/// In-app claude account sign-in (issue #173 follow-up). Opens a pane pointed at the
/// account's config-home running `claude auth login` (or `setup-token`), shows its
/// live terminal, scrapes the OAuth URL for a one-tap "Open sign-in page", and lets
/// the user paste the code back. The command ALWAYS clears the global
/// CLAUDE_CODE_OAUTH_TOKEN and pins CLAUDE_CONFIG_DIR (see `claudeLoginCommand`), so
/// credentials land in THIS account only — never a global token.
struct AccountLoginSheet: View {
    let client: HerdrClient
    let account: CredentialAccount
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var method: ClaudeLoginMethod = .oauth
    @State private var paneID: String?
    @State private var signInURL: URL?
    @State private var code: String = ""
    @State private var phase: String = "Pick a method, then Start."
    @State private var running = false
    @State private var scrapeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Method", selection: $method) {
                    ForEach(ClaudeLoginMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(running)

                Group {
                    if let pane = paneID {
                        LiveTerminalView(client: client, paneID: pane)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Palette.surfaceRaised)
                            .overlay(Text("The sign-in terminal appears here.")
                                .font(Typography.app(13)).foregroundStyle(Palette.textFaint))
                    }
                }
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 1))

                if let url = signInURL {
                    Button { openURL(url) } label: {
                        Label("Open sign-in page", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    TextField("Paste the code / URL from the browser", text: $code, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Send") { Task { await sendCode() } }
                        .buttonStyle(.bordered)
                        .disabled(code.isEmpty || paneID == nil)
                }

                Text(phase).font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Sign in · \(account.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Restart" : "Start") { Task { await start() } }
                }
            }
        }
    }

    private func start() async {
        guard let configDir = account.configDir,
              let cmd = claudeLoginCommand(kind: account.kind, configDir: configDir, method: method)
        else {
            phase = "Sign-in isn't supported for \(account.kind) accounts yet."
            return
        }
        scrapeTask?.cancel()
        if let old = paneID { try? await client.closePane(paneID: old) }
        signInURL = nil
        running = true
        phase = "Starting sign-in…"
        do {
            let pane = try await client.splitPane(cwd: nil)
            paneID = pane
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendKeys(pane: pane, keys: ["Enter"])
            phase = "Waiting for the sign-in link…"
            scrapeTask = Task { await scrapeLoop(pane: pane) }
        } catch {
            phase = "Couldn't start sign-in: \(error)"
            running = false
        }
    }

    private func scrapeLoop(pane: String) async {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for _ in 0..<120 {  // ~10 min at 5s
            if Task.isCancelled { return }
            if let read = try? await client.read(pane: pane, source: .recentUnwrapped, format: .text) {
                let text = read.text
                if signInURL == nil, let detector {
                    let range = NSRange(text.startIndex..., in: text)
                    if let url = detector.matches(in: text, range: range)
                        .compactMap({ $0.url })
                        .first(where: { $0.scheme == "https" }) {
                        signInURL = url
                        phase = "Open the link, approve, then paste the code below."
                    }
                }
                if text.range(of: "logged in", options: .caseInsensitive) != nil
                    || text.range(of: "login successful", options: .caseInsensitive) != nil {
                    phase = "Signed in — you can close this."
                    running = false
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func sendCode() async {
        guard let pane = paneID else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try await client.sendText(pane: pane, text: value)
            try await client.sendKeys(pane: pane, keys: ["Enter"])
            code = ""
            phase = "Submitted — watch the terminal above."
        } catch {
            phase = "Couldn't send the code: \(error)"
        }
    }

    private func finish() {
        scrapeTask?.cancel()
        let pane = paneID
        onFinished()
        dismiss()
        Task { if let pane { try? await client.closePane(paneID: pane) } }
    }
}
