import SwiftUI

/// Detects URLs in a plain string and returns an `AttributedString` with them as tappable link
/// runs, styled with a tint + underline. SwiftUI's `Text` does NOT auto-link a plain `String`, so
/// Gram message bodies run through this to make links clickable (a tap opens the URL via the
/// `openURL` environment). Bare URLs, `https://…`, and `www.…` are all detected by NSDataDetector.
func linkified(_ text: String, tint: Color = Palette.brand) -> AttributedString {
    let ns = NSMutableAttributedString(string: text)
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        detector.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let url = match.url else { return }
            ns.addAttribute(.link, value: url, range: match.range)
        }
    }
    var attributed = AttributedString(ns)
    // Tint the detected link runs so they read as links; the `.link` attribute makes the tap open
    // the URL regardless. Non-URL text keeps whatever the surrounding Text sets.
    for run in attributed.runs where run.link != nil {
        attributed[run.range].foregroundColor = tint
    }
    return attributed
}
