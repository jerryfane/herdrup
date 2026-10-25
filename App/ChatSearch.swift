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

struct ChatSearchResults: View {
    let hits: [TranscriptSearchHit]
    let query: String
    let selectedID: String?
    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        ForEach(hits) { hit in
            Text(ChatSearch.highlighted(hit.excerpt, query: query))
                .font(Typography.app(13 * textScale))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == hit.id ? Palette.surfaceRaised : Color.clear)
                .accessibilityIdentifier("chat-search-result")
                .id("search:" + hit.id)
        }
    }
}
