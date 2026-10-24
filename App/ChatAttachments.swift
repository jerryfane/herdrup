import HerdrKit
import SwiftUI

/// A chat attachment opens through the same authenticated Gram API and viewer as Gram.
/// Parsed command text supplies only an ID; the server still decides file access.
struct ChatAttachmentBundle: View {
    let files: [TranscriptAttachment]
    let client: HerdrClient
    @State private var expanded = false
    @State private var downloadingID: String?
    @State private var progress: (received: Int, total: Int)?
    @State private var failure: String?
    @State private var preview: GramPreview?
    @State private var openTask: Task<Void, Never>?

    @Environment(\.chatTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                    Text("\(files.count) attachment\(files.count == 1 ? "" : "s")")
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Typography.app(11 * textScale, .semibold))
                }
                .font(Typography.app(14 * textScale, .medium))
                .foregroundStyle(Palette.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat-attachment-bundle")

            if expanded {
                ForEach(files) { file in
                    Button { open(file) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: file.isImage ? "photo" : "doc")
                                .font(Typography.app(20 * textScale))
                            Text(file.name)
                                .font(Typography.app(14 * textScale, .medium))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if downloadingID == file.id {
                                ProgressView().controlSize(.small)
                            } else if file.messageID != nil {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .foregroundStyle(file.messageID == nil ? Palette.textFaint : Palette.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(file.messageID == nil || downloadingID != nil)
                    .accessibilityHint(file.messageID == nil ? "Upload not complete" : "Open attachment")
                }
            }
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.received), total: Double(progress.total))
                    .accessibilityLabel("Downloading attachment")
            }
            if let failure {
                Text(failure).font(Typography.app(12 * textScale)).foregroundStyle(Palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15))
        .gramFileViewer($preview)
        .onDisappear { openTask?.cancel() }
    }

    private func open(_ file: TranscriptAttachment) {
        guard let messageID = file.messageID, downloadingID == nil else { return }
        downloadingID = file.id
        progress = nil
        failure = nil
        openTask = Task { @MainActor in
            defer { downloadingID = nil; progress = nil }
            do {
                let (name, mime, data) = try await client.gramGetFileChunked(id: messageID) { received, total in
                    Task { @MainActor in progress = (received, total) }
                }
                try Task.checkCancellation()
                preview = try GramPreviewRouter.preview(data: data, name: name, mime: mime, cachedAt: nil)
            } catch is CancellationError {
            } catch {
                if GuestError.classify(error) == .forbidden {
                    failure = "This file is not shared with you."
                } else {
                    failure = "Couldn't open the file: \((error as? APIError)?.message ?? error.localizedDescription)"
                }
            }
        }
    }
}
