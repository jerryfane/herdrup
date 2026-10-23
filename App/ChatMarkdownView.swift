import HerdrKit
import SwiftUI

/// An omp reply drawn as native SwiftUI, like the Claude and ChatGPT apps: no bubble, 16 pt
/// Geist on 23 pt lines, with paragraphs, lists, headings, inline code, fenced code and
/// tables. HerdrKit's `ChatMarkdown` splits the blocks; inline styling uses Foundation's
/// inline markdown so bold, italic, code and links stay inside one wrapping `Text`.
struct ChatMarkdownView: View {
    let markdown: String

    private var blocks: [ChatMarkdownBlock] { ChatMarkdown.blocks(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(ChatInline.styled(text, size: 16))
                .foregroundStyle(Palette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(ChatInline.styled(text, size: level <= 1 ? 19 : level == 2 ? 17.5 : 16, weight: .semibold))
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
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Typography.machine(13))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(3)
                    .fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairlineQuiet, lineWidth: 1))
        case .table(let header, let rows):
            ChatMarkdownTable(header: header, rows: rows)
        case .quote(let text):
            Text(ChatInline.styled(text, size: 15.5))
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
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Text(marker).font(Typography.app(16))
                }
            }
            .foregroundStyle(Palette.textDim)
            .frame(minWidth: 10, alignment: .leading)
            Text(ChatInline.styled(item.text, size: 16))
                .foregroundStyle(Palette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.depth) * 18 + 20)
    }
}

/// A GitHub table: a hairline card with a raised header row, as the mockup draws Q5's bench.
private struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(ChatInline.styled(cell, size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textDim)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Palette.surface)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellText(cell)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    /// Figures read better in the mono face, and a signed gain in green, as in the mockup.
    private func cellText(_ cell: String) -> Text {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let numeric = trimmed.first.map { $0.isNumber || "+-−$".contains($0) } ?? false
            && trimmed.contains(where: \.isNumber)
        if numeric {
            let gain = trimmed.hasPrefix("+")
            return Text(trimmed).font(Typography.machine(13.5))
                .foregroundColor(gain ? ChatStyle.ok : Palette.text)
        }
        return Text(ChatInline.styled(cell, size: 14.5)).foregroundColor(Palette.text)
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
