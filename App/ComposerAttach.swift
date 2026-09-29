import HerdrKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer's paperclip, shared by the Gram page, the guest pane and the terminal
/// composer so all three look and behave alike. It only asks for the attach sheet;
/// `composerAttachPicker` presents it and stages what the reader picks.
struct ComposerAttachButton: View {
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComposerActionIcon(image: Image(systemName: "paperclip"), tint: Palette.textDim, busy: busy)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Attach file")
    }
}

/// One picked file, already copied into app-owned staging (`GramView.Staging`), so the
/// send streams it from disk and the composer owns its lifetime.
struct ComposerPickedFile {
    let name: String
    let mime: String
    let isImage: Bool
    let staged: StagedAttachment
}

/// What one pick produced: the files that staged, and a note naming what did not
/// (nil when everything staged), in the wording every composer shows.
struct ComposerPickOutcome {
    var files: [ComposerPickedFile] = []
    var note: String?
}

extension View {
    /// The attach sheet and the two system pickers behind it.
    ///
    /// The paperclip sets `isPresented`; a Telegram-style sheet picks the source, and
    /// the RIGHT system picker opens once that sheet has finished dismissing (presenting
    /// one sheet while another is dismissing drops the second on iOS). Picks are staged
    /// here, bounded by `GramView.Staging.maxFileBytes` each and by `room()` in number,
    /// so every composer enforces the same limits. `loading` is true while a photo batch
    /// loads (iCloud items can take a moment) and gates the composer's own send.
    func composerAttachPicker(
        isPresented: Binding<Bool>,
        loading: Binding<Bool>,
        room: @escaping () -> Int,
        onPick: @escaping (ComposerPickOutcome) -> Void
    ) -> some View {
        modifier(ComposerAttachPicker(isPresented: isPresented, loading: loading,
                                      room: room, onPick: onPick))
    }
}

private struct ComposerAttachPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var loading: Bool
    let room: () -> Int
    let onPick: (ComposerPickOutcome) -> Void

    private enum Source { case photos, file }
    @State private var pending: Source?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: presentPending) {
                sheet
                    .presentationDetents([.height(190)])
                    .presentationDragIndicator(.visible)
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoItems,
                maxSelectionCount: GramView.Staging.maxAttachments,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []  // reset now so re-picking the same items fires onChange again
                Task { await stagePhotos(items) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { stageFiles($0) }
    }

    private var sheet: some View {
        VStack(spacing: 18) {
            Text("Attach")
                .font(Typography.app(14, .semibold)).foregroundStyle(Palette.textDim)
                .padding(.top, 16)
            HStack(spacing: 20) {
                option(icon: "photo.on.rectangle.angled", label: "Photo & Video", id: "composer-attach-photos") {
                    pending = .photos
                    isPresented = false
                }
                option(icon: "doc", label: "File", id: "composer-attach-file") {
                    pending = .file
                    isPresented = false
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.ground.ignoresSafeArea())
    }

    private func option(icon: String, label: String, id: String,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.text)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Palette.surface))
                    .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
                Text(label).font(Typography.app(13, .medium)).foregroundStyle(Palette.textDim)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func presentPending() {
        defer { pending = nil }
        switch pending {
        case .photos: showPhotoPicker = true
        case .file:
            #if DEBUG
            // The UI-test harness cannot drive the out-of-process document picker, so
            // it hands over a picked file here and it takes the picker's own callback.
            if let urls = TerminalInteractionHarness.pickedFiles() {
                stageFiles(.success(urls))
                return
            }
            #endif
            showFileImporter = true
        case nil: break
        }
    }

    /// Stages picked documents as COPIES ON DISK. Importer URLs are security-scoped,
    /// so the copy happens inside the access window; the URL is unreadable after it.
    /// A KNOWN size within the cap is required BEFORE copying: an unstat-able URL is
    /// treated as over-cap, never staged, so a multi-gigabyte pick with no reported
    /// size cannot fall through to an unbounded copy. Bad picks are COLLECTED into one
    /// note, so one bad file among several still stages the good ones.
    private func stageFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var outcome = ComposerPickOutcome()
        var bad: [String] = []
        var capped = 0
        let available = room()
        for url in urls {
            guard outcome.files.count < available else {
                capped += 1
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = GramStaging.safeFileName(url.lastPathComponent)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= GramView.Staging.maxFileBytes,
                  let staged = GramView.Staging.copy(of: url, named: name)
            else {
                bad.append(url.lastPathComponent)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            outcome.files.append(ComposerPickedFile(
                name: name, mime: type?.preferredMIMEType ?? "application/octet-stream",
                isImage: type?.conforms(to: .image) ?? false, staged: staged))
        }
        outcome.note = Self.skipNote(
            bad: bad.isEmpty ? nil : "too large or unreadable: \(bad.joined(separator: ", "))",
            capped: capped)
        onPick(outcome)
    }

    /// Loads photo-library picks SERIALLY (bounded disk pressure, stable order), each
    /// through `ComposerPickedMedia` so the size cap is enforced on the exported file
    /// before it is copied — the same invariant the document path holds.
    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        loading = true
        defer { loading = false }
        var outcome = ComposerPickOutcome()
        var bad = 0
        var capped = 0
        let available = room()
        for item in items {
            guard outcome.files.count < available else {
                capped += 1
                continue
            }
            // A nil transferable = couldn't produce a file; a nil `staged` = rejected by
            // the size guard, or the copy failed.
            guard let media = try? await item.loadTransferable(type: ComposerPickedMedia.self),
                  let staged = media.staged
            else {
                bad += 1
                continue
            }
            let (name, mime, isImage) = Self.photoNameAndMime(for: item)
            outcome.files.append(ComposerPickedFile(name: name, mime: mime, isImage: isImage, staged: staged))
        }
        outcome.note = Self.skipNote(
            bad: bad == 0 ? nil : bad == 1 ? "1 item too large or unreadable" : "\(bad) items too large or unreadable",
            capped: capped)
        onPick(outcome)
    }

    private static func skipNote(bad: String?, capped: Int) -> String? {
        var parts: [String] = []
        if let bad { parts.append(bad) }
        if capped > 0 { parts.append("\(capped) over the \(GramView.Staging.maxAttachments)-file limit") }
        guard !parts.isEmpty else { return nil }
        return "Skipped: " + parts.joined(separator: "; ") + "."
    }

    /// A filename, MIME and image flag for a library pick from its concrete content type
    /// (HEIC, JPEG, MOV, …). The name carries a short unique discriminator so three
    /// photos don't all arrive as "image.heic" — identical chips for the reader and a
    /// name collision for any receiving agent that stores attachments by name.
    private static func photoNameAndMime(for item: PhotosPickerItem) -> (String, String, Bool) {
        let disc = UUID().uuidString.prefix(8).lowercased()
        let type = item.supportedContentTypes.first
        let isMovie = type?.conforms(to: .movie) == true
        if let type, let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType {
            return ("\(isMovie ? "video" : "image")-\(disc).\(ext)", mime, !isMovie)
        }
        return isMovie ? ("video-\(disc).mov", "video/quicktime", false) : ("image-\(disc).jpg", "image/jpeg", true)
    }
}

/// A photo-library pick copied into app-owned staging. PhotosUI exports the item to a
/// temp file and DELETES it when the closure returns, so the copy has to happen inside
/// `FileRepresentation`; the importer stats that export and rejects an over-cap (or
/// unstat-able) pick THERE — `staged == nil` — before any copy.
///
/// Rejection is a VALUE, not a thrown error: `loadTransferable` routes through
/// NSItemProvider's Obj-C error bridge, across which a Swift error type may not survive.
private struct ComposerPickedMedia: Transferable {
    let staged: StagedAttachment?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            guard let size = try? received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= GramView.Staging.maxFileBytes
            else { return ComposerPickedMedia(staged: nil) }
            return ComposerPickedMedia(staged: GramView.Staging.copy(
                of: received.file, named: received.file.lastPathComponent))
        }
    }
}
