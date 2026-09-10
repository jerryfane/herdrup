import CoreTransferable
import Foundation
import HerdrKit
import UniformTypeIdentifiers
import UIKit

/// One terminal-composer attachment. Bytes stay in app-owned temporary storage
/// until Gram finalizes them; `localPath` then prevents a prompt retry from
/// uploading or posting the same file twice.
struct TerminalAttachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let mime: String
    let url: URL
    let dir: URL
    let size: Int
    var uploadID: String?
    var gramMessageID: String?
    var localPath: String?

    init(
        id: UUID = UUID(), name: String, mime: String, staged: StagedAttachment,
        uploadID: String? = nil, gramMessageID: String? = nil, localPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mime = mime
        self.url = staged.url
        self.dir = staged.dir
        self.size = staged.size
        self.uploadID = uploadID
        self.gramMessageID = gramMessageID
        self.localPath = localPath
    }
}

enum TerminalAttachmentSendError: LocalizedError {
    case unnamedAgent
    case agentChanged
    case daemonUpgradeRequired
    var errorDescription: String? {
        switch self {
        case .unnamedAgent:
            return "Name this agent before sending it a file."
        case .agentChanged:
            return "The agent changed while the file was uploading. The file stayed in Gram; review before retrying."
        case .daemonUpgradeRequired:
            return "The daemon stored the file but did not return its path. Update Herdr before retrying."
        }
    }
}

/// Disk staging shared by file picks, photos, drops, and user-mediated paste.
enum TerminalAttachmentStaging {
    static let maxFileBytes = 100 * 1024 * 1024
    static let maxAttachments = 10
    static let inlineTextBytes = 4 * 1024

    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("terminal-attachment-staging", isDirectory: true)
    static let session = root
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    static func stageFile(_ source: URL, named requestedName: String? = nil) -> TerminalAttachment? {
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maxFileBytes
        else { return nil }
        let name = requestedName ?? source.lastPathComponent
        guard let staged = GramStaging.stageCopy(
            of: source, named: name, in: session, maxBytes: maxFileBytes)
        else { return nil }
        return TerminalAttachment(
            name: staged.url.lastPathComponent,
            mime: mimeType(for: staged.url),
            staged: staged)
    }

    static func stageData(_ data: Data, named name: String, mime: String) -> TerminalAttachment? {
        guard let staged = GramStaging.stageData(
            data, named: name, in: session, maxBytes: maxFileBytes)
        else { return nil }
        return TerminalAttachment(name: staged.url.lastPathComponent, mime: mime, staged: staged)
    }

    static func remove(_ attachment: TerminalAttachment) {
        try? FileManager.default.removeItem(at: attachment.dir)
    }

    static func sweepAbandonedOffMainActor() async {
        let stagingRoot = root
        let current = session.lastPathComponent
        await Task.detached(priority: .utility) {
            GramStaging.sweepAbandoned(root: stagingRoot, keeping: current)
        }.value
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}

/// One payload delivered by SwiftUI's system Paste button. This is deliberately
/// a Transferable: the app never queries UIPasteboard/NSPasteboard itself.
struct TerminalPastePayload: Transferable {
    enum Content: Sendable {
        case text(String)
        case image(Data)
        case file(URL)
    }

    let content: Content

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .utf8PlainText) { data in
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return TerminalPastePayload(content: .text(text))
        }
        DataRepresentation(importedContentType: .image) { data in
            TerminalPastePayload(content: .image(data))
        }
        FileRepresentation(importedContentType: .item) { received in
            TerminalPastePayload(content: .file(received.file))
        }
    }
}

/// PhotosPicker copies its temporary provider file before the transfer closure
/// returns, so iCloud-backed results remain readable during the later upload.
struct TerminalPickedMedia: Transferable {
    let attachment: TerminalAttachment?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            TerminalPickedMedia(
                attachment: TerminalAttachmentStaging.stageFile(received.file))
        }
    }
}
