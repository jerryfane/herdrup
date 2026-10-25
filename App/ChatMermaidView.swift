import HerdrKit
import SwiftUI

/// A ```mermaid block of a reply, drawn as a diagram (#523 item 1): a placeholder while
/// `MermaidRenderer` draws it, then the image fitted to the column (a tall diagram is capped
/// at about 1.2× the width; tap opens it full screen with pinch zoom). The header copies the
/// source or swaps the drawing for its code. If mermaid cannot draw it, the block is the
/// plain code block it was before, captioned "Diagram couldn't render".
///
/// Only CLOSED fences get here (`ChatMarkdown`), so a reply still streaming shows code
/// until its diagram is complete. Search still matches the source (it searches the reply
/// text, not this view).
struct ChatMermaidView: View {
    let source: String

    @Environment(\.chatTextScale) private var textScale
    @Environment(\.displayScale) private var displayScale
    @State private var receipt = CopiedCommandReceipt.shared
    @State private var rendered: MermaidRenderer.Rendered?
    @State private var failed = false
    @State private var showCode = false
    @State private var viewing = false
    @State private var width: CGFloat = 0

    private static let shape = RoundedRectangle(cornerRadius: 12)
    private static let inset: CGFloat = 10

    private var request: MermaidRenderer.Request? {
        let available = width - 2 * Self.inset
        guard available > 0 else { return nil }
        return MermaidRenderer.Request(source: source,
                                       widthBucket: MermaidDiagram.widthBucket(Double(available)),
                                       textScale: textScale, displayScale: displayScale)
    }

    /// The render for the current width if it is cached (so a row coming back on screen is
    /// drawn at its final height at once), else the last one this block had.
    private var shown: MermaidRenderer.Rendered? {
        request.flatMap { MermaidRenderer.shared.cached($0) } ?? rendered
    }

    var body: some View {
        Group {
            if failed && shown == nil {
                fallback
            } else {
                card
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: request) {
            guard let request else { return }
            if let hit = MermaidRenderer.shared.cached(request) {
                rendered = hit
                return
            }
            do {
                rendered = try await MermaidRenderer.shared.render(request)
                failed = false
            } catch {
                failed = true
            }
        }
        .fullScreenCover(isPresented: $viewing) { viewer }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-mermaid")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showCode {
                code
            } else {
                diagram
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
            }
        }
        .background(Palette.surface, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Palette.hairlineQuiet, lineWidth: 1))
    }

    private var header: some View {
        let copied = receipt.text == source
        return HStack(spacing: 14) {
            Text("Mermaid")
                .font(Typography.app(11.5))
                .foregroundStyle(Palette.textDim)
            Spacer(minLength: 0)
            Button { receipt.record(source) } label: {
                Text(copied ? "Copied" : "Copy source")
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(copied ? Palette.done : Palette.text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-mermaid-copy")
            Button { showCode.toggle() } label: {
                Text(showCode ? "Show diagram" : "Show code")
                    .font(Typography.app(12, .semibold))
                    .foregroundStyle(Palette.text)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-mermaid-toggle")
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 7)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var diagram: some View {
        if let shown {
            let size = fitted(shown.image.size)
            Button { viewing = true } label: {
                Image(uiImage: shown.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MermaidDiagram.accessibilityLabel(source))
            .accessibilityHint("Opens the diagram full screen")
            .accessibilityIdentifier("chat-mermaid-image")
        } else {
            ProgressView()
                .tint(Palette.textDim)
                .frame(maxWidth: .infinity)
                .frame(height: max(120, (width - 2 * Self.inset) * 0.5))
                .accessibilityLabel("Rendering diagram")
                .accessibilityIdentifier("chat-mermaid-placeholder")
        }
    }

    /// The image's size in the column (`MermaidDiagram.fitted`): the render was already drawn
    /// to fit, so this only shrinks it while a new width's render is on its way.
    private func fitted(_ natural: CGSize) -> CGSize {
        let fit = MermaidDiagram.fitted(width: natural.width, height: natural.height,
                                        maxWidth: max(1, width - 2 * Self.inset))
        return CGSize(width: fit.width, height: fit.height)
    }

    private var code: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(Typography.machine(13 * textScale))
                .foregroundStyle(Palette.text)
                .lineSpacing(3)
                .fixedSize()
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    /// Mermaid could not draw it: the code block, as before diagrams existed, and why.
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 4) {
            GramCodeBlock(code: source, language: "mermaid", textScale: textScale)
            Text("Diagram couldn't render")
                .font(Typography.app(12 * textScale))
                .foregroundStyle(Palette.textFaint)
                .accessibilityIdentifier("chat-mermaid-error")
        }
    }

    private var viewer: some View {
        NavigationStack {
            HtmlWebView(html: MermaidDiagram.viewerDocument(svg: shown?.svg ?? "",
                                                            background: MermaidRenderer.hex(Palette.ground)))
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("chat-mermaid-viewer")
                .navigationTitle("Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { viewing = false }
                            .accessibilityIdentifier("chat-mermaid-viewer-done")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(receipt.text == source ? "Copied" : "Copy source") { receipt.record(source) }
                    }
                }
        }
    }
}
