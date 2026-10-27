import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The platform-free half of the Chat view's ```svg blocks: which fences are an SVG, and the
/// inert, themed document the app rasterises (through the mermaid renderer's page) and shows
/// full screen.
///
/// The SVG is agent-written, so it is parsed and written out again rather than passed
/// through: anything that can run or load is dropped, not escaped. The app then draws it as
/// an `<img>` (an SVG image runs no script and loads nothing) on a page with the network
/// blocked, so this is one of three layers, and the one CI can test.
public enum SVGDiagram {
    /// Larger sources stay code: the parse runs on the main actor the first time a row shows.
    public static let maxBytes = 256 * 1024
    public static let maxElements = 10_000
    /// A side longer than this (in SVG user units) is not a diagram anyone can read.
    public static let maxSide = 16_384.0
    /// The size an SVG with neither a usable `width`/`height` nor a `viewBox` is drawn at,
    /// as browsers do.
    static let defaultSize = (width: 300.0, height: 150.0)

    /// A cleaned SVG and the size it draws at, in its own user units.
    public struct Sanitized: Equatable, Sendable {
        public let svg: String
        public let width: Double
        public let height: Double
    }

    /// Whether an ```xml fence holds an SVG document: an `<svg>` root, after any prolog,
    /// comment or doctype. Cheap on purpose; `sanitize` decides whether it really is one.
    public static func looksLikeSVG(_ source: String) -> Bool {
        var rest = Substring(source).drop(while: \.isWhitespace)
        while true {
            let end: Range<Substring.Index>?
            if rest.hasPrefix("<?") {
                end = rest.range(of: "?>")
            } else if rest.hasPrefix("<!--") {
                end = rest.range(of: "-->")
            } else if rest.hasPrefix("<!") {
                end = rest.range(of: ">")
            } else {
                break
            }
            guard let end else { return false }
            rest = rest[end.upperBound...].drop(while: \.isWhitespace)
        }
        guard rest.hasPrefix("<svg"), let next = rest.dropFirst(4).first,
              next.isWhitespace || next == ">" || next == "/" else { return false }
        return source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</svg>")
    }

    /// What VoiceOver reads for a drawn SVG: its `<title>` when it has one.
    public static func accessibilityLabel(_ source: String) -> String {
        guard let open = source.range(of: "<title>"),
              let close = source.range(of: "</title>", range: open.upperBound..<source.endIndex) else {
            return "SVG image"
        }
        let title = source[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title.contains("<") ? "SVG image" : "SVG image, \(title)"
    }

    /// `source` as an inert SVG document, or nil when it is not one well-formed `<svg>`
    /// root (or is over the size caps): the caller then shows the code.
    ///
    /// - Dropped with everything inside them: `script`, `foreignObject` (HTML inside the
    ///   SVG), embedded documents and media, animation elements (they can set `href`), and
    ///   any prefixed (non-SVG) element.
    /// - Dropped attributes: every `on…` handler, `xml:base`, and any `href`/`xlink:href`
    ///   that is not a reference inside the document (`#id`) or an inline raster image.
    /// - CSS (`style` attributes, `<style>` text, `url(…)` values): `@import` is removed and
    ///   every `url()` that is not `#id` becomes `none`, so nothing is fetched.
    /// - `variables` (names without the leading `--`) define the CSS custom properties an
    ///   agent's SVG expects from its host page, e.g. `var(--fg)`: once in a `:root` rule for
    ///   CSS, and substituted into presentation attributes (`fill="var(--fg)"`), which do not
    ///   resolve `var()` everywhere.
    /// - The root gets the SVG namespace, a `viewBox` and a numeric `width`/`height`, so it
    ///   draws at a known size as an image and scales in the full-screen viewer.
    public static func sanitize(_ source: String, variables: [String: String] = [:]) -> Sanitized? {
        guard !source.isEmpty, source.utf8.count <= maxBytes else { return nil }
        let writer = Writer(variables: variables)
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = writer
        guard parser.parse(), !writer.failed, writer.closedRoot, let size = writer.size else { return nil }
        return Sanitized(svg: writer.output, width: size.width, height: size.height)
    }

    // MARK: - Rules

    /// Elements dropped with their whole subtree (compared lowercased).
    static let droppedElements: Set<String> = [
        "script", "foreignobject", "iframe", "object", "embed", "audio", "video", "canvas",
        "set", "animate", "animatemotion", "animatetransform", "animatecolor", "discard",
        "handler", "listener",
    ]

    static func isAllowedReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return true }
        let lower = trimmed.lowercased()
        return ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif", "data:image/webp"]
            .contains { lower.hasPrefix($0 + ";") || lower.hasPrefix($0 + ",") }
    }

    private static let importRule = try! NSRegularExpression(
        pattern: "@import[^;]*(;|$)", options: [.caseInsensitive])
    /// A `url(...)` whose target is not `#id` (quoted or not).
    private static let externalURL = try! NSRegularExpression(
        pattern: "url\\(\\s*(?!['\"]?\\s*#)[^)]*\\)", options: [.caseInsensitive])
    private static let variable = try! NSRegularExpression(
        pattern: "var\\(\\s*--([A-Za-z0-9_-]+)\\s*(?:,\\s*([^()]*?))?\\s*\\)")

    /// CSS with nothing that loads: no `@import`, no `url()` outside the document.
    static func cleanCSS(_ css: String) -> String {
        var text = css
        for (regex, replacement) in [(importRule, ""), (externalURL, "none")] {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text
    }

    /// `var(--name)` / `var(--name, fallback)` replaced by the theme's value (or the
    /// fallback); an unknown variable with no fallback is left for CSS to resolve.
    static func substitute(_ value: String, variables: [String: String]) -> String {
        guard value.contains("var(") else { return value }
        var result = ""
        var last = value.startIndex
        for match in variable.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value), let name = Range(match.range(at: 1), in: value) else { continue }
            let fallback = Range(match.range(at: 2), in: value).map { String(value[$0]) }
            guard let replacement = variables[String(value[name])] ?? fallback else { continue }
            result += value[last..<whole.lowerBound]
            result += replacement
            last = whole.upperBound
        }
        return result + value[last...]
    }

    /// A length in user units: a plain number or `px`. Percentages and other units say
    /// nothing about the drawing's own size.
    static func length(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.lowercased().hasSuffix("px") { text.removeLast(2) }
        guard let number = Double(text), number.isFinite, number > 0 else { return nil }
        return number
    }

    static func viewBox(_ value: String?) -> (width: Double, height: Double)? {
        guard let value else { return nil }
        let numbers = value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2].isFinite, numbers[3].isFinite,
              numbers[2] > 0, numbers[3] > 0 else { return nil }
        return (numbers[2], numbers[3])
    }

    static func escapeText(_ text: String) -> String {
        guard text.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" }) else { return text }
        return text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }

    // MARK: - Writer

    /// Writes the cleaned document while the parser reads the source.
    private final class Writer: NSObject, XMLParserDelegate {
        let variables: [String: String]
        var output = ""
        var failed = false
        var closedRoot = false
        var size: (width: Double, height: Double)?
        private var depth = 0
        /// Depth at which a dropped element opened; everything below it is skipped.
        private var skipping: Int?
        private var elements = 0
        private var inStyle = false
        private var styleText = ""

        init(variables: [String: String]) {
            self.variables = variables
        }

        private func fail(_ parser: XMLParser) {
            failed = true
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            elements += 1
            guard !failed, elements <= SVGDiagram.maxElements, output.utf8.count <= 4 * SVGDiagram.maxBytes else {
                return fail(parser)
            }
            if depth == 1 {
                guard elementName == "svg", !closedRoot else { return fail(parser) }
            }
            guard skipping == nil else { return }
            let lower = elementName.lowercased()
            if SVGDiagram.droppedElements.contains(lower) || elementName.contains(":") {
                skipping = depth
                return
            }

            var attributes: [String: String] = [:]
            for (name, value) in attributeDict {
                let key = name.lowercased()
                if key.hasPrefix("on") || key == "xml:base" { continue }
                if key == "href" || key.hasSuffix(":href") {
                    if SVGDiagram.isAllowedReference(value) { attributes[name] = value }
                    continue
                }
                if key == "style" {
                    attributes[name] = SVGDiagram.cleanCSS(value)
                    continue
                }
                var cleaned = value
                if cleaned.range(of: "url(", options: .caseInsensitive) != nil { cleaned = SVGDiagram.cleanCSS(cleaned) }
                attributes[name] = SVGDiagram.substitute(cleaned, variables: variables)
            }

            if depth == 1 { root(&attributes, original: attributeDict) }
            // Sorted: a dictionary's order changes between launches.
            output += "<" + elementName
            for name in attributes.keys.sorted() {
                output += " \(name)=\"\(SVGDiagram.escapeAttribute(attributes[name]!))\""
            }
            output += ">"
            if depth == 1, !variables.isEmpty {
                let rules = variables.keys.sorted().map { "--\($0):\(variables[$0]!)" }.joined(separator: ";")
                output += "<style>:root{\(SVGDiagram.escapeText(rules))}</style>"
            }
            if lower == "style" {
                inStyle = true
                styleText = ""
            }
        }

        /// The root's namespace and size, decided from the source's own attributes.
        private func root(_ attributes: inout [String: String], original: [String: String]) {
            let box = SVGDiagram.viewBox(original["viewBox"])
            var width = SVGDiagram.length(original["width"])
            var height = SVGDiagram.length(original["height"])
            switch (width, height, box) {
            case (nil, nil, let box?):
                width = box.width
                height = box.height
            case (let w?, nil, let box?):
                height = w * box.height / box.width
            case (nil, let h?, let box?):
                width = h * box.width / box.height
            case (let w?, nil, nil):
                height = w * SVGDiagram.defaultSize.height / SVGDiagram.defaultSize.width
            case (nil, let h?, nil):
                width = h * SVGDiagram.defaultSize.width / SVGDiagram.defaultSize.height
            case (nil, nil, nil):
                width = SVGDiagram.defaultSize.width
                height = SVGDiagram.defaultSize.height
            default:
                break
            }
            guard let width, let height, width <= SVGDiagram.maxSide, height <= SVGDiagram.maxSide else {
                failed = true
                return
            }
            size = (width, height)
            attributes["xmlns"] = "http://www.w3.org/2000/svg"
            attributes["width"] = Self.number(width)
            attributes["height"] = Self.number(height)
            if box == nil { attributes["viewBox"] = "0 0 \(Self.number(width)) \(Self.number(height))" }
        }

        private static func number(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(value)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            defer { depth -= 1 }
            if let skip = skipping {
                if depth == skip { skipping = nil }
                return
            }
            if inStyle, elementName.lowercased() == "style" {
                output += SVGDiagram.escapeText(SVGDiagram.cleanCSS(styleText))
                inStyle = false
            }
            output += "</\(elementName)>"
            if depth == 1 {
                // The xlink prefix may be used without being declared by an agent that
                // wrote only the default namespace; declare it so the image parses.
                if output.contains(" xlink:"), !output.contains("xmlns:xlink=") {
                    output = output.replacingOccurrences(
                        of: "<svg ", with: "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\" ",
                        options: .anchored)
                }
                closedRoot = true
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failed = true
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string, parser)
        }

        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            append(whitespaceString, parser)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self), parser)
        }

        /// Text inside the root. Entity expansion can make it far longer than the source,
        /// so the output cap is checked here too.
        private func append(_ text: String, _ parser: XMLParser) {
            guard !failed, depth >= 1, skipping == nil, !closedRoot else { return }
            if inStyle {
                styleText += text
            } else {
                output += SVGDiagram.escapeText(text)
            }
            if output.utf8.count + styleText.utf8.count > 4 * SVGDiagram.maxBytes { fail(parser) }
        }
    }
}
