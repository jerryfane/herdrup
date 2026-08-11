import Foundation

/// A small, dependency-free Markdown → styled-HTML converter for previewing
/// received `.md` files as formatted pages instead of raw source. It covers the
/// common subset agent- and human-written markdown uses: ATX headings, bold /
/// italic, inline and fenced code, unordered / ordered lists, GitHub tables,
/// blockquotes, horizontal rules, links, and paragraphs. Anything it doesn't
/// recognize falls through as escaped text, so output is always safe HTML.
///
/// It lives in HerdrKit (not the app) so the parsing — the part with real logic —
/// is unit-tested on Linux; the app only decides when to call it.
public enum Markdown {

    /// Convert markdown to a self-contained, theme-aware HTML document suitable for
    /// QuickLook. `title` names the browser/preview tab.
    public static func toStyledHTML(_ markdown: String, title: String = "Preview") -> String {
        document(title: escape(title), body: renderBlocks(markdown))
    }

    // MARK: - Block parsing

    private static func renderBlocks(_ markdown: String) -> String {
        // Normalize newlines; keep blank lines (they separate blocks).
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var html = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line — nothing to emit (blocks handle their own spacing).
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block: ``` ... ```
            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1  // consume the closing fence (or run off the end)
                html += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Horizontal rule: ---, ***, ___
            if isHorizontalRule(trimmed) {
                html += "<hr>\n"; i += 1; continue
            }

            // ATX heading: #..###### followed by a space
            if let heading = heading(trimmed) {
                html += heading + "\n"; i += 1; continue
            }

            // GitHub table: a header row then a |---|---| separator row.
            if trimmed.contains("|"), i + 1 < lines.count,
                isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces))
            {
                var rows: [String] = [line]
                i += 2  // header + separator
                rows.append(lines[i - 1])  // keep separator marker slot; rebuilt below
                var bodyRows: [String] = []
                while i < lines.count, lines[i].contains("|"),
                    !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    bodyRows.append(lines[i]); i += 1
                }
                html += renderTable(header: rows[0], bodyRows: bodyRows) + "\n"
                continue
            }

            // Blockquote: one or more lines starting with >
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()  // drop '>'
                    quote.append(q.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                html += "<blockquote>\(renderBlocks(quote.joined(separator: "\n")))</blockquote>\n"
                continue
            }

            // Unordered list: -, *, + markers
            if isUnorderedItem(trimmed) {
                var items: [String] = []
                while i < lines.count, isUnorderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(listItemText(lines[i].trimmingCharacters(in: .whitespaces), ordered: false))
                    i += 1
                }
                html += "<ul>\(items.map { "<li>\(inline($0))</li>" }.joined())</ul>\n"
                continue
            }

            // Ordered list: 1. 2. ...
            if isOrderedItem(trimmed) {
                var items: [String] = []
                while i < lines.count, isOrderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(listItemText(lines[i].trimmingCharacters(in: .whitespaces), ordered: true))
                    i += 1
                }
                html += "<ol>\(items.map { "<li>\(inline($0))</li>" }.joined())</ol>\n"
                continue
            }

            // Paragraph: gather consecutive "plain" lines until a blank or a block start.
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix(">") || isHorizontalRule(t)
                    || heading(t) != nil || isUnorderedItem(t) || isOrderedItem(t)
                {
                    break
                }
                para.append(t); i += 1
            }
            if !para.isEmpty {
                html += "<p>\(inline(para.joined(separator: " ")))</p>\n"
            }
        }
        return html
    }

    // MARK: - Block helpers

    private static func isHorizontalRule(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3
            && (compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" }
                || compact.allSatisfy { $0 == "_" })
    }

    private static func heading(_ s: String) -> String? {
        var level = 0
        var rest = Substring(s)
        while rest.first == "#" { level += 1; rest = rest.dropFirst() }
        guard level >= 1, level <= 6, rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return "<h\(level)>\(inline(text))</h\(level)>"
    }

    private static func isUnorderedItem(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func isOrderedItem(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: ".") else { return false }
        let num = s[s.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber) && s[s.index(after: dot)...].hasPrefix(" ")
    }

    private static func listItemText(_ s: String, ordered: Bool) -> String {
        if ordered, let dot = s.firstIndex(of: ".") {
            return String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return String(s.dropFirst(2))  // drop the marker + space
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("-"), s.contains("|") else { return false }
        return s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderTable(header: String, bodyRows: [String]) -> String {
        let head = tableCells(header).map { "<th>\(inline($0))</th>" }.joined()
        let body = bodyRows.map { row in
            "<tr>" + tableCells(row).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
    }

    // MARK: - Inline parsing

    /// Render inline markdown inside already-block-classified text: code spans,
    /// links, bold, italic. HTML is escaped first, so no user text becomes markup.
    static func inline(_ text: String) -> String {
        // 1) Pull out code spans so their contents are never treated as markup.
        var placeholders: [String] = []
        var working = ""
        let buffer = Array(text)
        var idx = 0
        while idx < buffer.count {
            if buffer[idx] == "`" {
                var j = idx + 1
                var code = ""
                while j < buffer.count, buffer[j] != "`" { code.append(buffer[j]); j += 1 }
                if j < buffer.count {  // closed span
                    let token = "\u{0000}CODE\(placeholders.count)\u{0000}"
                    placeholders.append("<code>\(escape(code))</code>")
                    working += token
                    idx = j + 1
                    continue
                }
            }
            working.append(buffer[idx]); idx += 1
        }

        // 2) Escape HTML on the remaining (non-code) text.
        var html = escape(working)

        // 3) Links, then bold, then italic (bold before italic so ** wins over *).
        html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { m in
            "<a href=\"\(m[2])\">\(m[1])</a>"
        }
        html = replace(html, #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, #"__([^_]+)__"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, #"(?<![\*\w])\*([^*]+)\*(?![\*\w])"#) { "<em>\($0[1])</em>" }
        html = replace(html, #"(?<![_\w])_([^_]+)_(?![_\w])"#) { "<em>\($0[1])</em>" }

        // 4) Restore code spans.
        for (n, replacement) in placeholders.enumerated() {
            html = html.replacingOccurrences(of: "\u{0000}CODE\(n)\u{0000}", with: replacement)
        }
        return html
    }

    private static func replace(
        _ input: String, _ pattern: String, _ transform: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Document shell

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: light dark;
          --ink:#1c2230; --muted:#5b647f; --line:#e6e9f2; --bg:#ffffff;
          --code-bg:#f4f6fb; --quote:#8891ad; --link:#2f6df6; }
        @media (prefers-color-scheme: dark) {
          :root { --ink:#e7ebf6; --muted:#9aa3c2; --line:#262c44; --bg:#0e1220;
            --code-bg:#171d31; --quote:#7883a6; --link:#7aa2ff; } }
        * { box-sizing:border-box; }
        body { margin:0; background:var(--bg); color:var(--ink);
          font:16px/1.6 -apple-system, system-ui, sans-serif;
          padding:24px 20px; -webkit-text-size-adjust:100%; }
        h1,h2,h3,h4,h5,h6 { line-height:1.25; margin:1.4em 0 .5em; font-weight:650; }
        h1 { font-size:1.7em; margin-top:.2em; } h2 { font-size:1.4em; }
        h3 { font-size:1.2em; } h4,h5,h6 { font-size:1.05em; }
        p { margin:.7em 0; } a { color:var(--link); text-decoration:none; }
        ul,ol { margin:.6em 0; padding-left:1.4em; } li { margin:.25em 0; }
        code { background:var(--code-bg); padding:.12em .4em; border-radius:5px;
          font:.88em ui-monospace, SFMono-Regular, Menlo, monospace; }
        pre { background:var(--code-bg); padding:14px 16px; border-radius:12px;
          overflow-x:auto; border:1px solid var(--line); }
        pre code { background:none; padding:0; font-size:.85em; }
        blockquote { margin:.8em 0; padding:.2em 0 .2em 14px; color:var(--muted);
          border-left:3px solid var(--quote); }
        hr { border:0; border-top:1px solid var(--line); margin:1.4em 0; }
        table { border-collapse:collapse; width:100%; margin:.9em 0; font-size:.95em;
          display:block; overflow-x:auto; }
        th,td { border:1px solid var(--line); padding:8px 11px; text-align:left; }
        th { background:var(--code-bg); font-weight:650; }
        </style></head>
        <body>
        \(body)</body></html>
        """
    }
}
