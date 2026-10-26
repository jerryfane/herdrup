import HerdrKit
import SwiftUI
import UIKit

/// A chat message's text as a reader sees it, for its Copy and Select Text (item 5 of
/// #523). SwiftUI's `.textSelection` on iOS copies one whole `Text` and never a range, and
/// a reply is many `Text`s (a block each), so the menu copies the message and the sheet
/// shows it in one `UITextView`, which has real selection handles and mouse drag-select.
enum ChatMessageText {
    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible)

    /// A rendered-markdown message (a reply or a thought) with its markdown syntax gone and
    /// its blocks kept as lines: headings and table headers strongly emphasised, list
    /// markers as drawn, code as code, table cells tab-separated. Inline bold, italic,
    /// code and links stay as presentation intents and links.
    static func readable(_ markdown: String) -> AttributedString {
        var out = AttributedString()
        for block in ChatMarkdown.blocks(markdown) {
            if !out.characters.isEmpty { out += AttributedString("\n\n") }
            switch block {
            case .paragraph(let text), .quote(let text):
                out += inline(text)
            case .heading(_, let text):
                out += strong(inline(text))
            case .list(let ordered, let start, let items):
                for (index, item) in items.enumerated() {
                    if index > 0 { out += AttributedString("\n") }
                    let marker = item.checked.map { $0 ? "☑ " : "☐ " } ?? (ordered ? "\(start + index). " : "• ")
                    out += AttributedString(String(repeating: "    ", count: item.depth) + marker)
                    out += inline(item.text)
                }
            case .code(_, let code), .diagram(_, let code):
                var text = AttributedString(code)
                text.inlinePresentationIntent = .code
                out += text
            case .table(let header, let rows):
                out += strong(row(header))
                for cells in rows {
                    out += AttributedString("\n")
                    out += row(cells)
                }
            case .rule:
                out += AttributedString("———")
            }
        }
        return out
    }

    /// What Copy puts on the clipboard for a rendered-markdown message.
    static func plain(_ markdown: String) -> String {
        String(readable(markdown).characters)
    }

    /// The text in the chat's fonts and colours, for the Select Text sheet: Geist at `size`
    /// (semibold where strongly emphasised), IBM Plex Mono for code, links in the chat's
    /// link colour.
    static func attributed(_ text: AttributedString, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3 * size / 16
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, intent: intent),
                .foregroundColor: UIColor(Palette.text),
                .paragraphStyle: paragraph
            ]
            if intent.contains(.code) { attributes[.backgroundColor] = UIColor(Palette.surface) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: inlineOptions)) ?? AttributedString(markdown)
    }

    private static func row(_ cells: [String]) -> AttributedString {
        var out = AttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 { out += AttributedString("\t") }
            out += inline(cell.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    private static func strong(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
        }
        return text
    }

    private static func font(size: CGFloat, intent: InlinePresentationIntent) -> UIFont {
        if intent.contains(.code) {
            let codeSize = max(size - 2.5, 10)
            return UIFont(name: "IBMPlexMono", size: codeSize) ?? .monospacedSystemFont(ofSize: codeSize, weight: .regular)
        }
        let name = intent.contains(.stronglyEmphasized) ? "Geist-SemiBold" : "Geist-Regular"
        let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
        if intent.contains(.emphasized), let italic = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: italic, size: size)
        }
        return font
    }
}

/// The chat's clipboard: a WRITE only. A programmatic read raises the system paste prompt,
/// which failed App Review under 2.1a (see `CopyForAgentButton`), so nothing here reads it.
@MainActor
enum ChatClipboard {
    static func write(_ text: String) {
        UIPasteboard.general.string = text
        #if DEBUG
        ChatCopyRecord.shared.text = text
        #endif
    }
}

/// A message whose text the Select Text sheet shows.
struct ChatSelectableText: Identifiable {
    let id = UUID()
    let text: AttributedString
}

/// Select Text: the message in one read-only `UITextView`, in the chat's font and colours,
/// so a range can be selected with handles (or by mouse drag on a Mac), then copied, looked
/// up or shared from the system's own edit menu.
struct ChatSelectTextSheet: View {
    let text: AttributedString
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        NavigationStack {
            ChatSelectableTextView(text: ChatMessageText.attributed(text, size: 16 * textScale * Typography.scale))
                .frame(maxWidth: ChatStyle.columnWidth)
                .frame(maxWidth: .infinity)
                .background(Palette.ground.ignoresSafeArea())
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("chat-select-text-done")
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("chat-select-text-sheet")
    }
}

private struct ChatSelectableTextView: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = .link
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.working)]
        view.tintColor = UIColor(Palette.working)
        view.alwaysBounceVertical = true
        view.accessibilityIdentifier = "chat-select-text"
        view.attributedText = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !view.attributedText.isEqual(to: text) { view.attributedText = text }
    }
}

#if DEBUG
/// For the UI tests: the text chat's Copy last wrote, kept here as it is written so a test
/// can check the clipboard's content without anything reading the clipboard.
@MainActor @Observable
final class ChatCopyRecord {
    static let shared = ChatCopyRecord()
    var text: String?
}

/// The `chat-copy-probe`: `{"copied": <text>}` (JSON, so newlines survive the label), or
/// `none` before any copy. Its own view, so a copy redraws the probe alone.
struct ChatCopyProbe: View {
    @State private var record = ChatCopyRecord.shared

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityIdentifier("chat-copy-probe")
            .accessibilityLabel(label)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
    }

    private var label: String {
        guard let text = record.text,
              let data = try? JSONSerialization.data(withJSONObject: ["copied": text]) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
