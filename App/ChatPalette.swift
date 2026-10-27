import HerdrKit
import SwiftUI

/// The chat's colours from omp's theme (`theme.dark` in omp's config): headings and step
/// tool names in the accent, as omp's terminal draws its titles, and code blocks with
/// syntax colours on the theme's code background. Hex values, so a palette is a value a
/// cache can key on; the views read `Color`s from it, never their own literals.
struct ChatPalette: Hashable, Sendable {
    let heading: UInt32
    let toolTitle: UInt32
    let codeText: UInt32
    let codeBackground: UInt32
    let codeBorder: UInt32
    let keyword: UInt32
    let string: UInt32
    let comment: UInt32
    let function: UInt32
    let number: UInt32
    let type: UInt32
    let op: UInt32
    let inserted: UInt32
    let deleted: UInt32

    /// omp's dark-tokyo-night: the owner's theme.
    static let darkTokyoNight = ChatPalette(
        heading: 0xBB9AF7, toolTitle: 0xBB9AF7,
        codeText: 0xA9B1D6, codeBackground: 0x16161E, codeBorder: 0x363B54,
        keyword: 0xBB9AF7, string: 0x9ECE6A, comment: 0x51597D, function: 0x7AA2F7,
        number: 0xFF9E64, type: 0x0DB9D7, op: 0xA9B1D6,
        inserted: 0x9ECE6A, deleted: 0xF7768E)

    /// omp's light-tokyo-night, for when the app has a light appearance.
    static let lightTokyoNight = ChatPalette(
        heading: 0xB15C00, toolTitle: 0x3760BF,
        codeText: 0x6172B0, codeBackground: 0xE1E2E7, codeBorder: 0xB4B5B9,
        keyword: 0x7847BD, string: 0x587539, comment: 0x848CB5, function: 0x2E7DE9,
        number: 0xB15C00, type: 0x007197, op: 0x9854F1,
        inserted: 0x587539, deleted: 0xC64343)

    /// The app is dark-only today.
    static let current = darkTokyoNight

    func color(_ kind: CodeTokenKind) -> Color {
        switch kind {
        case .keyword: return Color(hex: keyword)
        case .string: return Color(hex: string)
        case .comment: return Color(hex: comment)
        case .function: return Color(hex: function)
        case .number: return Color(hex: number)
        case .type: return Color(hex: type)
        case .op: return Color(hex: op)
        case .inserted: return Color(hex: inserted)
        case .deleted: return Color(hex: deleted)
        }
    }
}

/// Highlighted code blocks, kept by content and language. Highlighting runs off the main
/// thread; a code block drawn again (scrolled back into the drawn window, or its row
/// redrawn) reads the cache and does not tokenize again. Bounded like `ChatMarkdownCache`.
@MainActor
enum ChatCodeHighlights {
    struct Key: Hashable, Sendable {
        let code: String
        let language: CodeLanguage
        let palette: ChatPalette
    }

    private static var cache = ChatMarkdownCache.BoundedCache<Key, AttributedString>(limit: 300)

    static func cached(_ key: Key) -> AttributedString? {
        cache.cached(key)
    }

    static func highlight(_ key: Key) async -> AttributedString {
        if let hit = cache.cached(key) { return hit }
        let result = await Task.detached(priority: .userInitiated) { Self.styled(key) }.value
        cache.store(result, for: key)
        return result
    }

    /// The code as one attributed string: each token run in its kind's colour, plain text
    /// left without a colour so the block's code-text colour shows.
    nonisolated static func styled(_ key: Key) -> AttributedString {
        var out = AttributedString()
        for span in CodeHighlighter.spans(key.code, in: key.language) {
            var run = AttributedString(span.text)
            if let kind = span.kind { run.foregroundColor = key.palette.color(kind) }
            out.append(run)
        }
        return out
    }
}
