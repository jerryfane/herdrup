import XCTest

@testable import HerdrKit

final class WebViewPolicyTests: XCTestCase {

    /// The rule list must be a JSON array of well-formed block rules; a malformed
    /// list fails to compile at runtime and the viewer would silently lose its
    /// network protection.
    func testRuleListIsValidJSONArrayOfBlockRules() throws {
        let data = Data(WebViewPolicy.blockNetworkRuleListJSON.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        let rules = try XCTUnwrap(obj as? [[String: Any]])
        XCTAssertFalse(rules.isEmpty, "rule list must not be empty")
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertNotNil(trigger["url-filter"] as? String, "each rule needs a url-filter")
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            XCTAssertEqual(action["type"] as? String, "block", "each rule must block")
        }
    }

    /// Every network scheme must be matched by some block rule, and the inline
    /// document + inline assets must NOT be — the exact split that keeps a hostile
    /// file from beaconing out while still letting the report render (issue #92: the
    /// old wrapper blocked its own content and painted blank).
    func testBlocksEveryNetworkSchemeAndAllowsInlineContent() throws {
        let filters = try urlFilters()

        let testURLs: [String: String] = [
            "http": "http://host/x", "https": "https://host/x",
            "ws": "ws://host/x", "wss": "wss://host/x",
            "ftp": "ftp://host/x", "ftps": "ftps://host/x",
            "file": "file:///etc/passwd", "blob": "blob:abcdef",
        ]
        for scheme in WebViewPolicy.blockedSchemes {
            let url = try XCTUnwrap(testURLs[scheme], "missing test URL for \(scheme)")
            XCTAssertTrue(
                filters.contains { Self.filterMatches($0, url) },
                "\(scheme) (\(url)) should be blocked")
        }
        for allowed in WebViewPolicy.allowedInlineURLs {
            XCTAssertFalse(
                filters.contains { Self.filterMatches($0, allowed) },
                "\(allowed) must not be blocked or the viewer goes blank")
        }
        // WebKit matches url-filters case-insensitively, so a hostile file cannot dodge
        // the rule by uppercasing the scheme.
        XCTAssertTrue(filters.contains { Self.filterMatches($0, "HTTP://Host/x") },
                      "uppercase http scheme must still be blocked")
        XCTAssertTrue(filters.contains { Self.filterMatches($0, "FILE:///etc/passwd") },
                      "uppercase file scheme must still be blocked")
    }

    private func urlFilters() throws -> [String] {
        let data = Data(WebViewPolicy.blockNetworkRuleListJSON.utf8)
        let rules = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]])
        return rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    }

    /// A content-blocker url-filter is a regex over the URL that WebKit matches
    /// CASE-INSENSITIVELY by default; NSRegularExpression with `.caseInsensitive`
    /// emulates whether a given URL would match a given filter.
    private static func filterMatches(_ pattern: String, _ url: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
