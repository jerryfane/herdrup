import HerdrKit
import SwiftUI

/// An omp reply drawn as native SwiftUI, like the Claude and ChatGPT apps: no bubble, 16 pt
/// Geist on 23 pt lines, with paragraphs, lists, headings, inline code, fenced code and
/// tables. HerdrKit's `ChatMarkdown` splits the blocks; inline styling uses Foundation's
/// inline markdown so bold, italic, code and links stay inside one wrapping `Text`.
struct ChatMarkdownView: View {
    let markdown: String

    @Environment(\.chatTextScale) private var textScale
    private var blocks: [ChatMarkdownBlock] { ChatMarkdown.blocks(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(ChatInline.styled(text, size: 16 * textScale))
                .foregroundStyle(Palette.text)
                .lineSpacing(3 * textScale)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(ChatInline.styled(text, size: (level == 1 ? 23 : level == 2 ? 20 : 17) * textScale, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineSpacing(2)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(item, marker: ordered ? "\(start + index)." : "•")
                }
            }
            .padding(.top, 2)
        case .code(let language, let code):
            GramCodeBlock(code: code, language: language, textScale: textScale)
        case .diagram(_, let source):
            ChatMermaidView(source: source)
        case .table(let header, let rows):
            ChatMarkdownTable(header: header, rows: rows)
        case .quote(let text):
            Text(ChatInline.styled(text, size: 15.5 * textScale))
                .foregroundStyle(Palette.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.hairline).frame(width: 2)
                }
        case .rule:
            Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func listRow(_ item: ChatMarkdownListItem, marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if let checked = item.checked {
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .font(.system(size: 13 * textScale, weight: .medium))
                } else {
                    Text(marker).font(Typography.app(16 * textScale))
                }
            }
            .foregroundStyle(Palette.textDim)
            .frame(minWidth: 10, alignment: .leading)
            Text(ChatInline.styled(item.text, size: 16 * textScale))
                .foregroundStyle(Palette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.depth) * 18 + 20)
    }
}

/// Fit ordinary tables to the chat width; scroll only when readable columns cannot fit.
private struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    private let columns: Int
    @Environment(\.chatTextScale) private var textScale
    @State private var viewportWidth: CGFloat = 0

    init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
        columns = max(1, rows.reduce(header.count) { max($0, $1.count) })
    }

    var body: some View {
        let cellWidth = max(96 * textScale, floor(viewportWidth / CGFloat(columns)))
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(ChatInline.styled(column < header.count ? header[column] : "",
                                               size: 13 * textScale, weight: .semibold))
                            .foregroundStyle(Palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: cellWidth - 24, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                    }
                }
                .background(Palette.surface)
                ForEach(rows.indices, id: \.self) { index in
                    Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(column < rows[index].count ? rows[index][column] : "", width: cellWidth)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-markdown-table")
    }

    private func cell(_ value: String, width: CGFloat) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let numeric = (trimmed.first.map { $0.isNumber || "+-−$".contains($0) } ?? false)
            && trimmed.contains(where: \.isNumber)
        return Group {
            if numeric {
                Text(ChatInline.styled(trimmed, size: 13.5 * textScale)).monospacedDigit()
                    .foregroundColor(trimmed.hasPrefix("+") ? ChatStyle.ok : Palette.text)
            } else {
                Text(ChatInline.styled(value, size: 14.5 * textScale)).foregroundColor(Palette.text)
            }
        }
        .multilineTextAlignment(numeric ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width - 24, alignment: numeric ? .trailing : .leading)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

enum ChatInline {
    /// Inline markdown (bold, italic, `code`, links, strikethrough) as one attributed string
    /// in the app's fonts. Anything it cannot parse shows as the literal text.
    static func styled(_ markdown: String, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in styled.runs {
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                styled[run.range].font = Typography.machine(max(size - 2.5, 10))
                styled[run.range].backgroundColor = Palette.surface
                styled[run.range].foregroundColor = Palette.text
                continue
            }
            var font = Typography.app(size, intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) { font = font.italic() }
            styled[run.range].font = font
            if intent.contains(.strikethrough) { styled[run.range].strikethroughStyle = .single }
            if run.link != nil {
                styled[run.range].foregroundColor = Palette.working
            }
        }
        return styled
    }
}
