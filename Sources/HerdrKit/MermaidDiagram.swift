import Foundation
import Crypto

/// The platform-free parts of the Chat view's mermaid diagrams (#523 item 1): how a render
/// is keyed in the image cache, what VoiceOver reads, and the document the full-screen
/// viewer shows. The rendering itself (an offscreen WKWebView) lives in the app.
public enum MermaidDiagram {
    /// Renders are cached per column-width step, so a column that moves by a few points
    /// (rotation, a sidebar, a Mac window resize) reuses its images instead of re-rendering.
    public static let widthStep = 40

    /// The render width for a column `width` points wide: rounded DOWN to a `widthStep`, so
    /// the image never overflows the column, and never under one step.
    public static func widthBucket(_ width: Double) -> Int {
        guard width.isFinite, width > 0 else { return widthStep }
        return max(widthStep, Int(width) / widthStep * widthStep)
    }

    /// A tall diagram is shown at most this many column widths high; the full-screen viewer
    /// has the rest.
    public static let tallCap = 1.2

    /// The size a diagram drawn `width` × `height` is shown at in a column `maxWidth` wide:
    /// never wider than the column, never more than `tallCap` columns high, aspect kept.
    /// It is also the size it is rasterised at, so a long diagram never becomes a huge image.
    public static func fitted(width: Double, height: Double, maxWidth: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0, maxWidth > 0 else { return (0, 0) }
        var fit = (width: min(width, maxWidth), height: 0.0)
        fit.height = fit.width * height / width
        let cap = maxWidth * tallCap
        if fit.height > cap {
            fit = (width: cap * width / height, height: cap)
        }
        return fit
    }

    /// The cache key of one render: sha256 of the theme, the width bucket and the source,
    /// so a palette or text-size change, a new width or an edited diagram never reuse a
    /// stale image. Hex, safe as a file name.
    public static func cacheKey(source: String, theme: String, widthBucket: Int) -> String {
        let input = "\(theme)\n\(widthBucket)\n\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What VoiceOver reads for a rendered diagram: "Mermaid diagram" plus its first line
    /// (the diagram type and direction, e.g. `graph TD`), which is all an image can say.
    public static func accessibilityLabel(_ source: String) -> String {
        let first = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first.map { "Mermaid diagram, \($0)" } ?? "Mermaid diagram"
    }

    /// The full-screen viewer's document: the rendered SVG, fitted to the screen width and
    /// pinch-zoomable, under a CSP that allows no script and no loads. The viewer also runs
    /// with JavaScript off and the network block (`HtmlWebView`), and mermaid already
    /// sanitised the SVG (`securityLevel: 'strict'`); any `<script>` element is dropped
    /// here too, so the document is inert on its own.
    public static func viewerDocument(svg: String, background: String) -> String {
        let inert = svg.replacingOccurrences(
            of: "<script\\b[\\s\\S]*?(</script\\s*>|$)",
            with: "",
            options: [.regularExpression, .caseInsensitive])
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=10, user-scalable=yes">
        <style>
        html, body { margin: 0; padding: 0; background: \(background); }
        body { padding: 16px; box-sizing: border-box; }
        svg { display: block; width: 100% !important; max-width: none !important; height: auto; }
        </style>
        </head>
        <body>\(inert)</body>
        </html>
        """
    }
}
