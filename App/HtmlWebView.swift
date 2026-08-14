import HerdrKit
import SwiftUI
import WebKit

/// Renders a RECEIVED HTML / SVG document safely in-app.
///
/// The document is loaded DIRECTLY into a `WKWebView` (no srcdoc iframe — that path
/// rendered a blank white screen in QuickLook, issue #92). Two protections make an
/// untrusted file safe to display:
///
///   * **JavaScript is disabled** (`allowsContentJavaScript = false`), so no script
///     in the file runs.
///   * **All network is blocked** via a `WKContentRuleList` compiled from
///     `WebViewPolicy.blockNetworkRuleListJSON`, so an `<img>`, `<link>`, `<object>`
///     or form cannot beacon the document's contents out. `data:` URIs and the inline
///     document are untouched, so embedded images/styles still render.
///
/// Link taps are also cancelled (see the coordinator) so the viewer cannot navigate
/// away from the file it was handed.
struct HtmlWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // No script execution from the (untrusted) document.
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        // Transparent so the document's own background (our reports set one, including a
        // dark-mode variant) shows through; systemBackground is only the load flash.
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .always

        // Compile the block-all-network rule, then load. If the store is somehow
        // unavailable we still load (JavaScript is already off, the primary defence) —
        // never leave the viewer blank waiting on a rule that will never compile.
        guard let store = WKContentRuleListStore.default() else {
            web.loadHTMLString(html, baseURL: nil)
            return web
        }
        store.compileContentRuleList(
            forIdentifier: "herdr.block-network",
            encodedContentRuleList: WebViewPolicy.blockNetworkRuleListJSON
        ) { [weak web] list, _ in
            guard let web else { return }
            if let list {
                web.configuration.userContentController.add(list)
            }
            web.loadHTMLString(html, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Allow the initial programmatic load, but cancel any user-initiated
        /// navigation (a tapped link) so the viewer stays on the handed-over document.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
