import XCTest
@testable import HerdrKit

final class AccountLoginTests: XCTestCase {
    // Every claude login/logout command MUST clear the global token and pin the
    // account's config-home — that is the whole point of the safety story.
    func testLoginCommandsClearTheGlobalTokenAndPinTheConfigHome() {
        let oauth = claudeLoginCommand(kind: "claude", configDir: "/root/.claude-2", method: .oauth)
        XCTAssertEqual(
            oauth,
            "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='/root/.claude-2' claude auth login --claudeai"
        )
        let token = claudeLoginCommand(kind: "claude", configDir: "/root/.claude-2", method: .setupToken)
        XCTAssertEqual(
            token,
            "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='/root/.claude-2' claude setup-token"
        )
        for cmd in [oauth, token].compactMap({ $0 }) {
            XCTAssertTrue(cmd.contains("-u CLAUDE_CODE_OAUTH_TOKEN"), "must clear the global token: \(cmd)")
            XCTAssertTrue(cmd.contains("CLAUDE_CONFIG_DIR="), "must pin the config-home: \(cmd)")
        }
    }

    func testLogoutAndStatusCommandsAreScopedToTheConfigHome() {
        XCTAssertEqual(
            claudeLogoutCommand(kind: "claude", configDir: "/root/.claude"),
            "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='/root/.claude' claude auth logout"
        )
        XCTAssertEqual(
            claudeAuthStatusCommand(kind: "claude", configDir: "/root/.claude"),
            "env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR='/root/.claude' claude auth status"
        )
    }

    func testNonClaudeKindsHaveNoCommandYet() {
        XCTAssertNil(claudeLoginCommand(kind: "codex", configDir: "/root/.codex", method: .oauth))
        XCTAssertNil(claudeLogoutCommand(kind: "kimi", configDir: "/root/.kimi-code"))
    }

    func testConfigHomeIsShellQuotedAgainstInjection() {
        let cmd = claudeLoginCommand(kind: "claude", configDir: "/root/it's here", method: .oauth)
        XCTAssertEqual(cmd?.contains("'/root/it'\\''s here'"), true, "single quotes must be escaped: \(cmd ?? "nil")")
    }
}
