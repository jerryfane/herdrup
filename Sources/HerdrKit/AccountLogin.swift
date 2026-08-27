import Foundation

/// How to authenticate a claude account from the app.
public enum ClaudeLoginMethod: String, CaseIterable, Sendable {
    /// `claude auth login` — the browser OAuth flow; saves per-account credentials
    /// in the account's config-home. The safe, default path.
    case oauth
    /// `claude setup-token` — mints a LONG-LIVED token. Kept per-account by the
    /// config-home; must never be exported globally (a global CLAUDE_CODE_OAUTH_TOKEN
    /// is exactly what overrode account routing and broke the fleet — see the
    /// account-routing incident). Offered, but OAuth is preferred.
    case setupToken

    public var title: String {
        switch self {
        case .oauth: return "Sign in (browser)"
        case .setupToken: return "Setup token"
        }
    }
}

/// Single-quote a path for a POSIX shell so a config-home with spaces/quotes can't
/// break the command or inject.
func shellQuoteSingle(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The command to LOG IN a claude account, typed into a pane. It ALWAYS clears the
/// global `CLAUDE_CODE_OAUTH_TOKEN` and points `CLAUDE_CONFIG_DIR` at the account's
/// own config-home, so credentials land in THAT account and a stray global token can
/// never decide the identity (the routing bug this whole safety story exists for).
/// `nil` for a non-claude kind (codex/kimi login is a follow-up) so the UI can hide it.
public func claudeLoginCommand(kind: String, configDir: String, method: ClaudeLoginMethod) -> String? {
    guard kind == "claude" else { return nil }
    let base = "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=\(shellQuoteSingle(configDir)) claude"
    switch method {
    case .oauth: return "\(base) auth login --claudeai"
    case .setupToken: return "\(base) setup-token"
    }
}

/// The command to LOG OUT a claude account (deletes its `.credentials.json`), typed
/// into a pane pointed at the account's config-home. `nil` for a non-claude kind.
public func claudeLogoutCommand(kind: String, configDir: String) -> String? {
    guard kind == "claude" else { return nil }
    return "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=\(shellQuoteSingle(configDir)) claude auth logout"
}

/// The sanitized status check for a claude account — the authoritative "is it logged
/// in?" probe (token cleared, config-home pinned). Used to detect login completion.
public func claudeAuthStatusCommand(kind: String, configDir: String) -> String? {
    guard kind == "claude" else { return nil }
    return "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=\(shellQuoteSingle(configDir)) claude auth status"
}

/// What the sign-in pane's output says about the attempt so far.
public enum ClaudeLoginOutcome: Equatable, Sendable {
    /// The harness reported a completed sign-in.
    case signedIn
    /// The harness rejected what was submitted — retry, do not keep waiting.
    case failed
    /// Nothing conclusive yet.
    case pending
}

/// Classifies the sign-in pane's recent output.
///
/// This exists because the UI hides the input box while it waits. Waiting on a success
/// signal alone would strand the user on a spinner the moment a code is mistyped, so a
/// FAILURE signal is a first-class outcome that hands the input back.
///
/// Matching is deliberately narrow. The pane carries the whole terminal tail, including a
/// shell prompt and whatever the user typed, so loose matching on a bare word like "error"
/// would end the flow on unrelated noise — which is worse than waiting, because it discards
/// a sign-in that was actually working. Success is checked FIRST: output that reports a
/// completed login while also containing an earlier failed attempt is a success.
public func claudeLoginOutcome(from text: String) -> ClaudeLoginOutcome {
    let haystack = text.lowercased()
    let success = [
        "logged in",
        "login successful",
        "successfully logged in",
        "authentication successful",
    ]
    if success.contains(where: haystack.contains) { return .signedIn }
    let failure = [
        "invalid code",
        "invalid token",
        "authentication failed",
        "login failed",
        // Qualified on purpose: a bare "expired" also matches benign copy like
        // "your token expires in 30 days", which would hand the input back mid-flight
        // on a sign-in that was working.
        "code expired",
        "token expired",
        "session expired",
        "try again",
    ]
    if failure.contains(where: haystack.contains) { return .failed }
    return .pending
}

/// Whether an account's identity going from `baseline` to `current` confirms a sign-in.
///
/// The sheet cannot read success off the terminal: `claude auth login --claudeai` is an
/// interactive TUI, so the phrases it used to match never appear and real sign-ins were
/// reported as failures. The daemon reads each account's identity out of its config-home
/// instead, and a logged-out config-home reports none — so ABSENT -> PRESENT is the
/// signal.
///
/// A re-sign-in to an account that already has an identity is deliberately NOT
/// confirmable this way: the same email is simply rewritten, so there is nothing to
/// observe. Returning false there means the sheet says it could not confirm — which is
/// honest — rather than claiming a success it never saw.
public func signInConfirmed(baseline: String?, current: String?) -> Bool {
    guard let current, !current.isEmpty else { return false }
    guard let baseline, !baseline.isEmpty else { return true }
    return baseline != current
}
