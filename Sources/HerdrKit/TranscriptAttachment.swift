import Foundation

public struct TranscriptAttachment: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isImage: Bool
    public let messageID: String?

    public init(id: String, name: String, isImage: Bool, messageID: String?) {
        self.id = id
        self.name = name
        self.isImage = isImage
        self.messageID = messageID
    }
}

extension GramAttachmentPrompt {
    public struct Parsed: Sendable, Equatable {
        public let caption: String
        public let files: [TranscriptAttachment]
    }

    /// Recognize only a complete envelope produced by our formatter. No command is
    /// executed, and any unrecognized or edited envelope stays ordinary message text.
    public static func parse(_ prompt: String) -> Parsed? {
        guard prompt.hasSuffix(".]") else { return nil }
        let caption: String
        let reference: Substring
        if let boundary = prompt.range(of: "\n\n[", options: .backwards) {
            caption = String(prompt[..<boundary.lowerBound])
            reference = prompt[prompt.index(before: boundary.upperBound)...]
        } else {
            guard prompt.first == "[" else { return nil }
            caption = ""
            reference = prompt[...]
        }

        var delivered: [Delivered] = []
        if reference.hasPrefix("[Photo attached via Herdr Gram message ") || reference.hasPrefix("[File ") {
            guard let marker = reference.range(of: " attached via Herdr Gram message "),
                  let commandStart = reference.range(of: ". Download it with `"),
                  let commandEnd = reference[commandStart.upperBound...].firstIndex(of: "`"),
                  let command = parseCommand(reference[commandStart.upperBound..<commandEnd]) else { return nil }
            let statedID = reference[marker.upperBound..<commandStart.lowerBound]
            guard statedID == command.id else { return nil }
            let noun = reference[reference.index(after: reference.startIndex)..<marker.lowerBound]
            let name: String
            if noun == "Photo", command.isImage {
                let ext = URL(fileURLWithPath: String(command.path)).pathExtension
                name = ext.isEmpty ? "Photo" : "Photo.\(ext)"
            } else if noun.hasPrefix("File "), !command.isImage {
                name = String(noun.dropFirst(5))
            } else {
                return nil
            }
            guard validName(name) else { return nil }
            delivered.append(Delivered(name: name, isImage: command.isImage, messageID: String(command.id)))
        } else {
            let lines = reference.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 4,
                  let header = lines.first,
                  let countEnd = header.firstIndex(of: " "),
                  let count = Int(header[header.index(after: header.startIndex)..<countEnd]),
                  count > 1, count == lines.count - 2,
                  header == "[\(count) files attached via Herdr Gram. Download them with:" else { return nil }
            delivered.reserveCapacity(count)
            for line in lines.dropFirst().dropLast() {
                guard line.first == "`", line.last == ")",
                      let separator = line.range(of: "`  ("),
                      let command = parseCommand(line[line.index(after: line.startIndex)..<separator.lowerBound]) else { return nil }
                let name = String(line[separator.upperBound..<line.index(before: line.endIndex)])
                guard validName(name) else { return nil }
                delivered.append(Delivered(name: name, isImage: command.isImage, messageID: String(command.id)))
            }
        }

        // This also verifies every output path, closing instruction, declared count,
        // extension and separator; arbitrary text that resembles a shell command is not hidden.
        guard Set(delivered.map(\.messageID)).count == delivered.count,
              text(caption, delivered: delivered) == prompt else { return nil }
        return Parsed(caption: caption, files: delivered.map {
            TranscriptAttachment(id: $0.messageID, name: $0.name, isImage: $0.isImage, messageID: $0.messageID)
        })
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func parseCommand(_ command: Substring) -> (id: Substring, path: Substring, isImage: Bool)? {
        let prefix = "herdr gram get-file "
        guard command.hasPrefix(prefix), let separator = command.range(of: " -o ") else { return nil }
        let id = command[command.index(command.startIndex, offsetBy: prefix.count)..<separator.lowerBound]
        guard id.hasPrefix("gram-"), id.count > 5, id.utf8.allSatisfy({ byte in
            byte == 45 || byte == 95 || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }) else { return nil }
        let path = command[separator.upperBound...]
        if path.hasPrefix("/tmp/herdr-photo-\(id)") { return (id, path, true) }
        if path.hasPrefix("/tmp/herdr-file-\(id)") { return (id, path, false) }
        return nil
    }
}
