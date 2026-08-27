import SwiftUI
import UIKit    // UIPasteboard (tap the sign-in link to copy it)
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
    /// A code has been submitted and we are waiting on the harness. While true the input is
    /// replaced by a spinner — so it MUST be cleared on failure too, or a mistyped code
    /// leaves the user on a spinner with no way to retry.
    @State private var submitting = false
    /// The pane text as it stood when the last code was submitted.
    ///
    /// Failure is judged ONLY on output produced after this point. The pane buffer is
    /// cumulative, so a rejected first attempt leaves "invalid code" sitting in it forever
    /// — and a retry would then be failed instantly by the previous attempt's message, no
    /// matter how good the new code is.
    @State private var submitBaseline: String = ""
    /// Briefly shown after the link is copied, so the tap has a visible result.
    @State private var copied = false

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
                            // Tap the URL itself to copy it — for signing in on another
                            // device, or when the in-app browser hand-off is not wanted.
                            // Clipboard WRITE only (same as CopyForAgentButton); a
                            // programmatic READ is what drew the App Store 2.1a rejection.
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                copied = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    copied = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                    Text(copied ? "Copied" : url.absoluteString)
                                        .font(Typography.machine(11))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(copied ? Palette.done : Palette.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(copied ? "Sign-in link copied" : "Copy sign-in link"))
                        }
                        stepCard(number: "2", title: "Paste the code you get back") {
                            if submitting {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Signing you in…")
                                        .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            } else {
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
        submitting = false
        submitBaseline = ""
        copied = false
        code = ""
        status = "Starting sign-in…"
        do {
            let pane = try await client.splitPane(cwd: nil)
            paneID = pane
            try await client.sendText(pane: pane, text: cmd)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
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
                switch claudeLoginOutcome(from: text) {
                case .signedIn:
                    signedIn = true
                    submitting = false
                    status = "Signed in."
                    // Show the confirmation long enough to read as an outcome, then close
                    // and hand the user back to Accounts (refreshed by `finish`).
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if !Task.isCancelled { finish() }
                    return
                case .failed, .pending:
                    // Success is judged on the whole buffer; FAILURE only on what arrived
                    // after the submission (see `submitBaseline`).
                    if submitting, claudeLoginOutcome(from: outputSinceSubmit(text)) == .failed {
                        submitting = false
                        status = "That code didn't work — check it and try again."
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func sendCode() async {
        guard let pane = paneID else { return }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        // Freeze what the pane already said, so the previous attempt's rejection cannot
        // fail this one before it is even answered.
        submitBaseline = (try? await client.read(pane: pane, source: .recentUnwrapped, format: .text))?.text ?? ""
        submitting = true
        status = "Signing you in…"
        do {
            try await client.sendText(pane: pane, text: value)
            try await client.sendPaneKeys(pane: pane, keys: ["Enter"])
            armSubmitTimeout(for: value)
        } catch {
            // Never leave the spinner up on a send that did not happen.
            submitting = false
            status = "Couldn't send the code: \(error)"
        }
    }

    /// Bounds the wait that the spinner hides the input behind.
    ///
    /// Success and explicit failure both arrive via the scrape loop, but neither is
    /// guaranteed: the harness can print something we do not recognise, or nothing at all.
    /// Without this the input would never come back and the sign-in could not be retried —
    /// the spinner would simply be the last thing that ever happened. On expiry the typed
    /// code is restored rather than discarded, so a long token does not have to be pasted
    /// again.
    /// The pane output produced since the last submission. Falls back to the whole buffer
    /// when the baseline is no longer a prefix — the rolling window scrolled past it —
    /// which at worst costs one extra retry prompt rather than a stuck spinner.
    private func outputSinceSubmit(_ text: String) -> String {
        guard !submitBaseline.isEmpty else { return text }
        guard text.hasPrefix(submitBaseline) else { return text }
        return String(text.dropFirst(submitBaseline.count))
    }

    private func armSubmitTimeout(for submitted: String) {
        Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, submitting, !signedIn else { return }
            submitting = false
            if code.isEmpty { code = submitted }
            status = "No response yet — check the code and try again."
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
