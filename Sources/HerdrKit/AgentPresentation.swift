import Foundation

/// Presentation of agent names and terminal activity, independent of the UI toolkit.
public enum AgentPresentation {
    public static func initial(for name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    /// FNV-1a: unlike Swift's Hasher this is stable across launches and devices.
    public static func colorIndex(for name: String) -> Int {
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        // Fold the high bits down so short, similarly spelled names don't all
        // depend on FNV's weakest two bits.
        return Int((hash ^ (hash >> 32)) % 4)
    }

    /// Remove leading CLI decoration only; preserve the activity's interior verbatim.
    public static func activity(_ title: String) -> String {
        var remainder = title[...]
        var sawPrompt = false
        while let start = remainder.firstIndex(where: { !$0.isWhitespace }) {
            let tokenEnd = remainder[start...].firstIndex(where: { $0.isWhitespace }) ?? remainder.endIndex
            let token = remainder[start..<tokenEnd]
            let isPrompt = token == "π"
            let isSpinner = !token.isEmpty && token.unicodeScalars.allSatisfy {
                (0x2800...0x28FF).contains($0.value) || "✳✶✻✽✢✱".unicodeScalars.contains($0)
            }
            // OMP's idle title is "π > activity". A literal leading > otherwise stays.
            guard isPrompt || isSpinner || (sawPrompt && token == ">") else {
                return String(remainder[start...])
            }
            sawPrompt = sawPrompt || isPrompt
            remainder = remainder[tokenEnd...]
        }
        return ""
    }
}
