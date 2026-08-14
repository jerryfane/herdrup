import Foundation

/// Security policy for rendering a RECEIVED web document (HTML / SVG) in-app.
///
/// A gram attachment can be authored by anyone, so when we render one we disable
/// JavaScript (at the WebView config level) and block ALL network egress, so a
/// hostile file can neither execute script nor beacon its host's data out. The
/// network block is expressed as a WebKit content-rule-list: every network scheme
/// is blocked, while the inline document itself (loaded with no base URL, so it is
/// `about:blank`) and `data:` URIs (already inline in the file) are untouched, so
/// embedded images and styles still render.
///
/// Lives in HerdrKit so the rule list is unit-tested on Linux; the app compiles it
/// into a `WKContentRuleList` and attaches it to the viewer's WebView. This replaces
/// the old `HtmlSandbox` srcdoc-iframe wrapper, whose CSS/CSP combination rendered a
/// blank screen in QuickLook (issue #92).
public enum WebViewPolicy {

    /// A WebKit content-rule-list (JSON) that blocks every network scheme. Kept as
    /// per-scheme literal-prefix rules (not one big alternation) to stay well inside
    /// the content-blocker url-filter's supported syntax, and deliberately does NOT
    /// match `about:` (the inline document) or `data:` (inline assets) so the document
    /// and its embedded images/styles still load.
    public static let blockNetworkRuleListJSON = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftps?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^blob:"},"action":{"type":"block"}}
    ]
    """

    /// The network schemes the rule list is required to block, for tests + docs.
    public static let blockedSchemes = ["http", "https", "ws", "wss", "ftp", "ftps", "file", "blob"]

    /// Schemes that must remain loadable, or the viewer goes blank / loses inline
    /// assets: the inline document itself and `data:` URIs.
    public static let allowedInlineURLs = ["about:blank", "data:text/html,hi", "data:image/png;base64,AAAA"]
}
