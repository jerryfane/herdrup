import SwiftUI
import HerdrKit

/// In-app claude account sign-in (issue #173 follow-up), clean stepped flow — NO raw
/// terminal. It runs `claude auth login` (or setup-token) in a BACKGROUND pane pinned to
/// the account's config-home, scrapes the OAuth URL, and shows it as a tap-to-open card;
/// the user approves in the browser and pastes the code back. The command always clears
/// the global CLAUDE_CODE_OAUTH_TOKEN and pins CLAUDE_CONFIG_DIR (see `claudeLoginCommand`),
/// so credentials land in THIS account only.
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
    @State private var status: String = "Starting sign-in…"
    @State private var signedIn = false
    @State private var scrapeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if signedIn {
                        Label("Signed in to \(account.label)", systemImage: "checkmark.circle.fill")
                            .font(Typography.app(17, .semibold))
                            .foregroundStyle(.green)
                            .padding(.top, 24)
                    } else if let url = signInURL {
                        stepCard(number: "1", title: "Open the sign-in page") {
                            Button { openURL(url) } label: {
                                Label("Open sign-in page", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Text(url.absoluteString)
                                .font(Typography.machine(11)).foregroundStyle(Palette.textFaint)
                                .lineLimit(2).textSelection(.enabled)
                        }
                        stepCard(number: "2", title: "Paste the code you get back") {
                            TextField("Code or URL from the browser", text: $code, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Sign in") { Task { await sendCode() } }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(status).font(Typography.app(15)).foregroundStyle(Palette.textDim)
                        }
                        .padding(.top, 36)
                    }

                    if !signedIn {
                        Text(status).font(Typography.app(12)).foregroundStyle(Palette.textFaint)
                        Button(method == .oauth ? "Use a setup token instead" : "Use browser sign-in instead") {
                            method = method == .oauth ? .setupToken : .oauth
                            Task { await start() }
                        }
                        .font(Typography.app(13)).foregroundStyle(Palette.brand)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Sign in · \(account.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(signedIn ? "Done" : "Cancel") { finish() }
                }
            }
            .task { await start() }
        }
    }

    @ViewBuilder
    private func stepCard<Content: View>(
        number: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number)
                    .font(Typography.app(13, .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.brand))
                Text(title).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
    }

    private func start() async {
        guard let configDir = account.configDir,
              let cmd = claudeLoginCommand(kind: account.kind, configDir: configDir, method: method)
        else {
            status = "Sign-in isn't supported for \(account.kind) accounts yet."
            return
        }
        scrapeTask?.cancel()
        if let old = paneID { try? await client.closePane(paneID: old); paneID = nil }
        signInURL = nil
        signedIn = false
        code = ""
        status = "Starting sign-in…"
        do {
            let pane = try await client.splitPane(cwd: nil)
            paneID = pane
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendKeys(pane: pane, keys: ["Enter"])
            status = "Getting your sign-in link…"
            scrapeTask = Task { await scrapeLoop(pane: pane) }
        } catch {
            status = "Couldn't start sign-in: \(error)"
        }
    }

    private func scrapeLoop(pane: String) async {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for _ in 0..<150 {  // ~10 min at 4s
            if Task.isCancelled { return }
            if let read = try? await client.read(pane: pane, source: .recentUnwrapped, format: .text) {
                let text = read.text
                if signInURL == nil, let detector {
                    let range = NSRange(text.startIndex..., in: text)
                    if let url = detector.matches(in: text, range: range)
                        .compactMap({ $0.url })
                        .first(where: { $0.scheme == "https" }) {
                        signInURL = url
                        status = "Open the link, approve, then paste the code below."
                    }
                }
                if text.range(of: "logged in", options: .caseInsensitive) != nil
                    || text.range(of: "login successful", options: .caseInsensitive) != nil {
                    signedIn = true
                    status = "Signed in."
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
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
            status = "Submitting… hang on."
        } catch {
            status = "Couldn't send the code: \(error)"
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
