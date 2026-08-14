import HerdrKit
import SwiftUI
import WebKit

/// Renders a RECEIVED HTML / SVG document safely in-app.
///
/// The document is loaded DIRECTLY into a `WKWebView` (no srcdoc iframe — that path
/// rendered a blank white screen in QuickLook, issue #92). Three protections make an
/// untrusted file safe to display:
///
///   * **JavaScript is disabled** (`allowsContentJavaScript = false`), so no script
///     in the file runs.
///   * **All network is blocked** via a `WKContentRuleList` compiled from
///     `WebViewPolicy.blockNetworkRuleListJSON`, so a passive subresource load
///     (`<img>`, `<link>`, CSS `url()`, `<object>`) cannot beacon out. `data:` URIs
///     and the inline document are untouched, so embedded images/styles still render.
///     If the rule cannot be installed the viewer FAILS CLOSED (shows a placeholder)
///     rather than rendering the untrusted document unprotected.
///   * **Navigation is frozen** to the initial document (see the coordinator): link
///     taps, `<form>` submits and `<meta http-equiv=refresh>` are all cancelled, so
///     the file cannot navigate or egress even by a route the content rule misses.
///
/// The webview keeps WKWebView's default OPAQUE white base: an unstyled document then
/// renders black-on-white (readable in both light and dark), and our reports, which
/// paint their own themed background, paint over it. (A transparent webview over the
/// dark system background rendered unstyled files black-on-black — the #92 symptom.)
struct HtmlWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // No script execution from the (untrusted) document. This is set on the config
        // BEFORE the WKWebView is created (the init-time copy captures it), and the
        // coordinator deliberately implements ONLY the 2-arg policy method — not the
        // `preferences:` variant, which would hand back a fresh WKWebpagePreferences and
        // silently re-enable JS. Do not add that overload without re-disabling JS there.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .always

        // The network block is a SECURITY boundary, so it must FAIL CLOSED: if the rule
        // store is unavailable or the rule fails to compile, show a safe placeholder
        // rather than the untrusted document. JavaScript being off does NOT stop a
        // PASSIVE subresource beacon (an `<img>`/CSS `url()` fires without script and
        // does not pass through the navigation delegate), so loading without the rule
        // would leak. The rule JSON is static and unit-tested, so this path should never
        // fire in practice — it just refuses to fail open if it somehow does.
        guard let store = WKContentRuleListStore.default() else {
            web.loadHTMLString(Self.blockedPlaceholderHTML, baseURL: nil)
            return web
        }
        store.compileContentRuleList(
            forIdentifier: "herdr.block-network",
            encodedContentRuleList: WebViewPolicy.blockNetworkRuleListJSON
        ) { [weak web] list, _ in
            guard let web else { return }
            guard let list else {
                web.loadHTMLString(Self.blockedPlaceholderHTML, baseURL: nil)
                return
            }
            web.configuration.userContentController.add(list)
            web.loadHTMLString(html, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// Shown instead of the document when the network-block rule cannot be installed —
    /// the fail-closed state (see makeUIView). Self-contained: no script, no network,
    /// theme-aware via CSS system colors.
    private static let blockedPlaceholderHTML = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      :root{color-scheme:light dark}
      body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
           font:16px -apple-system,system-ui,sans-serif;text-align:center;padding:24px;
           background:Canvas;color:CanvasText}
      p{max-width:22em;line-height:1.5;color:GrayText}
    </style>
    <p>This file couldn't be displayed safely, so it wasn't shown. You can still share it to open it in another app.</p>
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// True once the initial programmatic load has been allowed through.
        private var didStartInitialLoad = false

        /// Freeze the viewer on the document it was handed: allow ONLY the first load
        /// (our `loadHTMLString`, an `about:blank` main-frame navigation), and cancel
        /// every navigation after it — link taps (`.linkActivated`), form submits
        /// (`.formSubmitted`) and `<meta http-equiv=refresh>` (`.other`) alike. This
        /// closes the navigation-egress routes a content rule does not cover, and holds
        /// even in the fail-closed placeholder case.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if didStartInitialLoad {
                decisionHandler(.cancel)
            } else {
                didStartInitialLoad = true
                decisionHandler(.allow)
            }
        }
    }
}
