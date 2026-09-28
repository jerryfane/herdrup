import Foundation

/// The prompt that hands an agent files posted to it through Gram: the typed text,
/// then how to download each attachment. ONE prompt for the whole batch: a single
/// attachment keeps its original wording; several are listed with one download
/// command each, because an agent that gets a prompt per file cannot see them as one
/// request.
public enum GramAttachmentPrompt {
    public struct Delivered: Sendable {
        public let name: String
        public let isImage: Bool
        public let messageID: String

        public init(name: String, isImage: Bool, messageID: String) {
            self.name = name
            self.isImage = isImage
            self.messageID = messageID
        }
    }

    public static func text(_ text: String, delivered: [Delivered]) -> String {
        func outputPath(_ item: Delivered) -> String {
            let rawExtension = URL(fileURLWithPath: item.name).pathExtension.lowercased()
            let fileExtension = rawExtension.filter { $0.isLetter || $0.isNumber }
            let stem = item.isImage ? "photo" : "file"
            return "/tmp/herdr-\(stem)-\(item.messageID)"
                + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        }
        let reference: String
        if delivered.count == 1, let only = delivered.first {
            let path = outputPath(only)
            let noun = only.isImage ? "Photo" : "File \(only.name)"
            reference = """
            [\(noun) attached via Herdr Gram message \(only.messageID). Download it with \
            `herdr gram get-file \(only.messageID) -o \(path)`, then inspect \(path).]
            """
        } else {
            let lines = delivered.map { item -> String in
                "`herdr gram get-file \(item.messageID) -o \(outputPath(item))`  (\(item.name))"
            }
            let paths = delivered.map(outputPath)
            reference = """
            [\(delivered.count) files attached via Herdr Gram. Download them with:
            \(lines.joined(separator: "\n"))
            then inspect \(paths.joined(separator: ", ")).]
            """
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? reference
            : "\(text)\n\n\(reference)"
    }
}
