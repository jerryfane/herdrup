import HerdrKit
import SwiftUI

enum ChatSearch {
    /// `text` with every match of `query` marked. The ranges cover whole characters
    /// (`TranscriptSearch`), so each maps onto the attributed string.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for range in TranscriptSearch.ranges(in: text, query: query) {
            if let start = AttributedString.Index(range.lowerBound, within: result),
               let end = AttributedString.Index(range.upperBound, within: result) {
                result[start..<end].backgroundColor = Color.yellow.opacity(0.35)
            }
        }
        return result
    }
}

private struct ChatSearchQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var chatSearchQuery: String {
        get { self[ChatSearchQueryKey.self] }
        set { self[ChatSearchQueryKey.self] = newValue }
    }
}

/// Where the selected search result is on screen, for the chat's reveal
/// (`ChatScrollPosition.reveal`): its rows report it, the chat reads it once laid out.
@MainActor
final class ChatSearchReveal {
    private var selectedID: String?
    private var selectedFrame: CGRect?

    func report(_ id: String, frame: CGRect) {
        selectedID = id
        selectedFrame = frame
    }

    /// The result's frame in window coordinates, once it has been laid out.
    func frame(of id: String) -> CGRect? {
        selectedID == id ? selectedFrame : nil
    }
}

private struct ChatSearchRevealKey: EnvironmentKey {
    static let defaultValue: ChatSearchReveal? = nil
}

extension EnvironmentValues {
    var chatSearchReveal: ChatSearchReveal? {
        get { self[ChatSearchRevealKey.self] }
        set { self[ChatSearchRevealKey.self] = newValue }
    }
}

struct ChatSearchResults: View {
    let hits: [TranscriptSearchHit]
    let query: String
    let selectedID: String?
    @Environment(\.chatTextScale) private var textScale
    @Environment(\.chatSearchReveal) private var reveal

    var body: some View {
        ForEach(hits) { hit in
            let result = Text(ChatSearch.highlighted(hit.excerpt, query: query))
                .font(Typography.app(13 * textScale))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == hit.id ? Palette.surfaceRaised : Color.clear)
                .accessibilityIdentifier("chat-search-result")
                .id("search:" + hit.id)
            // Only the selected result reports where it is: the others are never revealed.
            if selectedID == hit.id {
                result.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    reveal?.report(hit.id, frame: frame)
                }
            } else {
                result
            }
        }
    }
}
