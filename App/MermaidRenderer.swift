import HerdrKit
import SwiftUI
import UIKit
import WebKit

/// Draws the Chat view's ```mermaid blocks (#523 item 1) with the bundled mermaid.min.js, in
/// ONE offscreen `WKWebView` shared by every diagram, and hands back a cached image.
///
/// Why images and one page rather than a live web view per diagram: each `WKWebView` is a
/// WebContent process, and live views report their height late, re-laying rows out under
/// the chat's tail-follow and older-page anchoring. An image has its size up front.
///
/// The page is first-party (the bundled library and `mermaid.html`), so it is NOT tied to the
/// reader's "JavaScript in HTML previews" switch, which is about received documents; guests
/// see diagrams too. The diagram SOURCE is untrusted (agent output), and it is contained by:
///   * mermaid's `securityLevel: 'strict'` (labels are text, the SVG is DOMPurify-sanitised,
///     click handlers are off);
///   * the page CSP (`mermaid.html`): no page script at all, so even an inline handler in
///     the SVG cannot run; mermaid and each render are injected by the app, which CSP
///     does not govern;
///   * `WebViewPolicy`'s network-block content rule list, FAIL CLOSED: no rule list, no page,
///     and the diagram falls back to its code;
///   * navigation locked after the first load, and a non-persistent data store.
///
/// Renders run one at a time (one page, one `#out`). Results are cached in memory and on
/// disk under `MermaidDiagram.cacheKey`, so scrolling back or reopening a chat never runs
/// mermaid again.
@MainActor
final class MermaidRenderer: NSObject {
    static let shared = MermaidRenderer()

    /// One rendered diagram: the image at the requested width and the screen scale, and
    /// the SVG for the full-screen viewer.
    final class Rendered: @unchecked Sendable {
        let key: String
        let image: UIImage
        let svg: String

        init(key: String, image: UIImage, svg: String) {
            self.key = key
            self.image = image
            self.svg = svg
        }
    }

    /// What to draw: the source, the column width it must fit, the chat text size (scales
    /// the drawing like the text around it) and the screen scale of the raster.
    struct Request: Equatable {
        let source: String
        let widthBucket: Int
        let textScale: CGFloat
        let displayScale: CGFloat

        @MainActor var key: String {
            MermaidDiagram.cacheKey(source: source,
                                    theme: "\(MermaidRenderer.theme)@\(textScale)x\(displayScale)",
                                    widthBucket: widthBucket)
        }
    }

    enum Failure: Error {
        /// The page could not be set up safely (no bundle file, no content rule list).
        case unavailable
        /// Mermaid rejected the source, or it drew nothing.
        case invalid
    }

    private let memory: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var webView: WKWebView?
    /// The tail of the one-at-a-time render queue.
    private var queue: Task<Void, Never>?
    private var renders = 0
    private var didStartInitialLoad = false
    private var loaded: CheckedContinuation<Void, Error>?

    /// A render already in memory, for drawing it in the same frame a row appears (no
    /// placeholder flash, so the row's height is right from the start).
    func cached(_ request: Request) -> Rendered? {
        memory.object(forKey: request.key as NSString)
    }

    func render(_ request: Request) async throws -> Rendered {
        let key = request.key
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let previous = queue
        let job = Task { () async throws -> Rendered in
            await previous?.value
            if let hit = memory.object(forKey: key as NSString) { return hit }
            if let stored = await Self.loadFromDisk(key: key, scale: request.displayScale) {
                remember(stored)
                return stored
            }
            let rendered = try await draw(request, key: key)
            remember(rendered)
            Self.saveToDisk(rendered)
            return rendered
        }
        queue = Task { _ = try? await job.value }
        return try await job.value
    }

    private func remember(_ rendered: Rendered) {
        let pixels = rendered.image.size.width * rendered.image.scale * rendered.image.size.height * rendered.image.scale
        memory.setObject(rendered, forKey: rendered.key as NSString, cost: Int(pixels) * 4)
    }

    // MARK: - Drawing

    private func draw(_ request: Request, key: String) async throws -> Rendered {
        let web = try await page()
        renders += 1
        let result = try await web.callAsyncJavaScript(
            Self.renderFunction,
            arguments: ["id": "herdr-mermaid-\(renders)", "source": request.source,
                        "textScale": Double(request.textScale)],
            contentWorld: .page)
        guard let drawn = result as? [String: Any],
              let svg = drawn["svg"] as? String,
              let natural = (drawn["width"] as? NSNumber)?.doubleValue,
              let naturalHeight = (drawn["height"] as? NSNumber)?.doubleValue else { throw Failure.invalid }
        // Rasterise at the size the chat shows it (a tall diagram capped), not its full
        // length: the image stays small; the viewer zooms the SVG.
        let fit = MermaidDiagram.fitted(width: natural, height: naturalHeight,
                                        maxWidth: Double(request.widthBucket))
        guard fit.width >= 1, fit.height >= 1 else { throw Failure.invalid }
        let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        _ = try await web.callAsyncJavaScript(
            "const el = document.querySelector('#out svg'); el.style.width = width + 'px'; el.style.height = height + 'px'; return true;",
            arguments: ["width": Double(size.width), "height": Double(size.height)],
            contentWorld: .page)
        // The page must cover the drawing for the snapshot to include all of it.
        if web.frame.width < size.width || web.frame.height < size.height {
            web.frame = CGRect(x: 0, y: 0, width: max(web.frame.width, size.width),
                               height: max(web.frame.height, size.height))
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.snapshotWidth = NSNumber(value: Double(size.width))
        // The page is never in a window, so there are no screen updates to wait for:
        // WebKit paints the page straight into the snapshot (its software path).
        config.afterScreenUpdates = false
        let snapshot = try await web.takeSnapshot(configuration: config)
        guard let cgImage = snapshot.cgImage, cgImage.width > 0 else { throw Failure.invalid }
        // The scale is the page's device scale (the screen's); the disk copy is reloaded at
        // the request's, which is the same screen.
        let image = UIImage(cgImage: cgImage, scale: CGFloat(cgImage.width) / size.width, orientation: .up)
        return Rendered(key: key, image: image, svg: svg)
    }

    /// The shared page, set up on first use: bundled html, network block, mermaid, theme.
    private func page() async throws -> WKWebView {
        if let webView { return webView }
        guard let htmlURL = Bundle.main.url(forResource: "mermaid", withExtension: "html"),
              let scriptURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let store = WKContentRuleListStore.default() else { throw Failure.unavailable }
        // The network block is a security boundary: without it there is no page (fail closed).
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "herdr.block-network",
                encodedContentRuleList: WebViewPolicy.blockNetworkRuleListJSON
            ) { list, _ in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: Failure.unavailable)
                }
            }
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(rules)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        web.isOpaque = true
        web.backgroundColor = UIColor(Palette.surface)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = self
        didStartInitialLoad = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        // A program, not a function body: the bundle declares its globals with `var`. The
        // trailing `true` keeps the completion value serialisable (the last statement
        // assigns the mermaid object).
        _ = try await web.evaluateJavaScript(script + "\n;true")
        _ = try await web.callAsyncJavaScript(
            "document.body.style.background = background; mermaid.initialize(config); return true;",
            arguments: ["config": Self.configuration, "background": Self.hex(Palette.surface)],
            contentWorld: .page)
        webView = web
        return web
    }

    /// Renders `source` into `#out` and returns the SVG and its natural size times the chat
    /// text scale (`draw` then fits it to the column).
    private static let renderFunction = """
    const out = document.getElementById('out');
    out.replaceChildren();
    try {
      const { svg } = await mermaid.render(id, source);
      out.innerHTML = svg;
      const el = out.querySelector('svg');
      if (!el) return null;
      const box = el.viewBox && el.viewBox.baseVal;
      const rect = el.getBoundingClientRect();
      const w = box && box.width > 0 ? box.width : rect.width;
      const h = box && box.height > 0 ? box.height : rect.height;
      if (!(w > 0 && h > 0)) return null;
      el.removeAttribute('width');
      el.removeAttribute('height');
      el.style.maxWidth = 'none';
      return { svg, width: w * textScale, height: h * textScale };
    } finally {
      const stray = document.getElementById('d' + id);
      if (stray) stray.remove();
    }
    """

    /// Mermaid's dark `base` theme in the app's palette (`Palette`), labels as SVG text
    /// (`htmlLabels: false`, no foreignObject) and nothing that runs on load.
    private static var configuration: [String: Any] {
        [
            "startOnLoad": false,
            "securityLevel": "strict",
            "suppressErrorRendering": true,
            "htmlLabels": false,
            "flowchart": ["htmlLabels": false],
            "theme": "base",
            "fontFamily": "-apple-system, 'Helvetica Neue', sans-serif",
            "themeVariables": themeVariables,
        ]
    }

    private static var themeVariables: [String: Any] {
        let surface = hex(Palette.surface), raised = hex(Palette.surfaceRaised)
        let ground = hex(Palette.ground), text = hex(Palette.text), dim = hex(Palette.textDim)
        let hairline = hex(Palette.hairline), brand = hex(Palette.brand), faint = hex(Palette.textFaint)
        return [
            "darkMode": true,
            "fontSize": "14px",
            "background": surface,
            "primaryColor": raised,
            "primaryTextColor": text,
            "primaryBorderColor": brand,
            "secondaryColor": ground,
            "secondaryTextColor": text,
            "secondaryBorderColor": hairline,
            "tertiaryColor": ground,
            "tertiaryTextColor": text,
            "tertiaryBorderColor": hairline,
            "mainBkg": raised,
            "nodeBorder": brand,
            "nodeTextColor": text,
            "textColor": text,
            "titleColor": text,
            "lineColor": dim,
            "clusterBkg": ground,
            "clusterBorder": hairline,
            "edgeLabelBackground": surface,
            "noteBkgColor": hairline,
            "noteTextColor": text,
            "noteBorderColor": faint,
            "actorBkg": raised,
            "actorBorder": brand,
            "actorTextColor": text,
            "actorLineColor": dim,
            "signalColor": dim,
            "signalTextColor": text,
            "labelBoxBkgColor": raised,
            "labelBoxBorderColor": hairline,
            "labelTextColor": text,
            "loopTextColor": text,
        ]
    }

    /// The bundled mermaid.min.js (App/Resources/Mermaid/README.md). Part of every cache key,
    /// so a new library version draws afresh instead of showing images the old one made.
    private static let libraryVersion = "11.17.2"

    /// Part of every cache key: a palette or library change re-renders instead of reusing
    /// old images.
    private static let theme: String = {
        let values = themeVariables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return "mermaid-\(libraryVersion);base;" + values.joined(separator: ";")
    }()

    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    // MARK: - Disk cache

    private nonisolated static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mermaid", isDirectory: true)
    }

    private static func loadFromDisk(key: String, scale: CGFloat) async -> Rendered? {
        let stored = await Task.detached(priority: .userInitiated) { () -> (Data, String)? in
            guard let directory = Self.directory,
                  let png = try? Data(contentsOf: directory.appendingPathComponent("\(key).png")),
                  let svg = try? String(contentsOf: directory.appendingPathComponent("\(key).svg"), encoding: .utf8)
            else { return nil }
            return (png, svg)
        }.value
        guard let stored, let image = UIImage(data: stored.0, scale: scale) else { return nil }
        return Rendered(key: key, image: image, svg: stored.1)
    }

    private static func saveToDisk(_ rendered: Rendered) {
        guard let png = rendered.image.pngData() else { return }
        let key = rendered.key, svg = rendered.svg
        Task.detached(priority: .utility) {
            guard let directory = Self.directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // SVG first: a PNG is only read back together with its SVG.
            try? Data(svg.utf8).write(to: directory.appendingPathComponent("\(key).svg"), options: .atomic)
            try? png.write(to: directory.appendingPathComponent("\(key).png"), options: .atomic)
        }
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    /// Allow exactly the first navigation (our `loadHTMLString`) and cancel every one after
    /// it, as `HtmlWebView` does: nothing a diagram draws can take the page anywhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if didStartInitialLoad {
            decisionHandler(.cancel)
        } else {
            didStartInitialLoad = true
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    /// The WebContent process died (memory pressure): drop the page; the next render
    /// builds a fresh one.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { self.webView = nil }
        loaded?.resume(throwing: Failure.unavailable)
        loaded = nil
    }
}
