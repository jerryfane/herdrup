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
