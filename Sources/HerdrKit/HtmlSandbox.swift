import Foundation

/// Wraps a received HTML / SVG / XHTML file so a preview renders it (styled) but
/// CANNOT run scripts. Without this, QuickLook renders such an attachment as live,
/// scriptable web content — so a hostile file from an agent could run JavaScript in
/// the preview. The content is placed in a **sandboxed** iframe (no `allow-scripts`)
/// which the browser renders statically: scripts, forms, popups, top-level
/// navigation, and same-origin access are all blocked. A purely passive resource
/// load (an `<img>` or CSS `url()`) can still beacon, but that is low-impact with no
/// script access — and no data the preview holds is reachable.
///
/// Lives in HerdrKit so the escaping/wrapping is unit-tested on Linux; the app only
/// decides which file types to route through it.
public enum HtmlSandbox {

    /// Wrap raw HTML/SVG source into a self-contained document whose sole body is a
    /// sandboxed iframe holding the (escaped) source. `title` names the preview tab.
    public static func wrap(_ rawHTML: String, title: String = "Preview") -> String {
        // Escape for the double-quoted `srcdoc` attribute value: `&` FIRST (so we
        // don't double-escape the entities we introduce), then `"`. `<`/`>` are
        // legal literally inside an attribute value and are the content the iframe
        // renders, so they are intentionally left alone. NUL is stripped.
        let inner =
            rawHTML
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let safeTitle =
            title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(safeTitle)</title>
            <style>html,body{margin:0;height:100%;background:#fff}
            iframe{border:0;width:100%;height:100vh;display:block}</style>
            </head><body>
            <iframe sandbox srcdoc="\(inner)"></iframe>
            </body></html>
            """
    }
}
