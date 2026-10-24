import SwiftUI

struct ChatSearchHit: Equatable, Identifiable {
    let rowID: String
    let offset: Int
    let excerpt: String
    var id: String { "\(rowID):\(offset)" }
}

enum ChatSearch {
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            matches.append(range)
            start = range.upperBound
        }
        return matches
    }

    static func hits(rowID: String, text: String, query: String) -> [ChatSearchHit] {
        ranges(in: text, query: query).map { range in
            let start = text.index(range.lowerBound, offsetBy: -48, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            return ChatSearchHit(rowID: rowID, offset: text.distance(from: text.startIndex, to: range.lowerBound),
                                 excerpt: String(text[start..<end]))
        }
    }

    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges(in: text, query: query) {
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
