import Foundation

/// One file staged in a composer (the Gram page, the terminal reply, the guest pane) on
/// its way to an agent as its own gram message. The same model in all three, so the one
/// `GramAttachmentSender` delivers for each of them.
public struct ComposerAttachment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let mime: String
    /// Chooses the chip glyph and the wording of the prompt reference; the delivery path
    /// is identical either way.
    public let isImage: Bool
    /// The bytes on disk, in app-owned staging. Removed once the gram posts.
    public let staged: StagedAttachment
    /// The host's id for the uploaded bytes, kept so a retry posts them without uploading
    /// again. Nil until the upload finishes, and again once the host says it has lost it.
    public var uploadID: String?
    /// The posted gram, kept so a retry skips this file. Nil until the post lands.
    public var messageID: String?

    public var size: Int { staged.size }

    public init(
        id: UUID = UUID(), name: String, mime: String, isImage: Bool,
        staged: StagedAttachment, uploadID: String? = nil, messageID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mime = mime
        self.isImage = isImage
        self.staged = staged
        self.uploadID = uploadID
        self.messageID = messageID
    }
}

/// "Upload each staged file, post it as a gram": the attachment half of every composer's
/// send. The caller then sends its own follow-up (the prompt naming the files, or nothing
/// more for the Gram page, whose caption rides on the first file's post).
///
/// Upload and post are closures so each composer keeps its own transport call (the
/// owner's `gram.post` to an agent or the queue, the guest's to the shared agent) and its
/// own progress state; what is shared is the order and the recovery:
/// - SERIAL, one file at a time, in the order given. `gram.post` consumes each staging
///   file, so one upload in flight keeps the daemon's 1 GiB aggregate staging budget
///   clear however many files are staged; ten parallel 100 MiB uploads would fill it and
///   fail gram uploads for every client on the box.
/// - RESUME. Each file's `uploadID` and `messageID` are handed to `update` the moment
///   they are known. The caller writes them back into its staged list, so a retry after
///   a mid-batch failure skips every file already posted and posts an uploaded one
///   without transferring it again.
/// - PRE-UPLOAD. A composer starts each file's upload as it is added (`ComposerUploader`).
///   A file Send reaches without an `uploadID` first awaits that upload (`preUploaded`),
///   so a file still uploading is never sent twice; only a file with none is uploaded here.
/// - A post refused with `upload_in_progress` is asked again (`postAttempts` tries,
///   `retryDelayNanoseconds` apart), never re-uploaded: see `postRetryingInProgress(_:)`.
/// - A post refused because the host holds no upload under that id (`isStaleUpload`)
///   uploads the file once more and posts again.
@MainActor
public struct GramAttachmentSender {
    /// Uploads one file's staged bytes; returns the host's `upload_id`.
    public typealias Upload = @MainActor (ComposerAttachment) async throws -> String
    /// The composer's pre-upload of a file (`ComposerUploader.waitForUpload`): its
    /// `upload_id` once it finishes (throwing its failure), or nil when there is none and
    /// the file is uploaded now.
    public typealias PreUploaded = @MainActor (ComposerAttachment) async throws -> String?
    /// Posts one uploaded file as a gram; returns the posted message's id.
    public typealias Post = @MainActor (ComposerAttachment, HerdrClient.GramFileAttachment) async throws -> String

    /// Why a batch stopped: the file that failed, how many of the batch had landed by
    /// then, and the underlying error.
    public struct Failure: Error {
        public let attachment: ComposerAttachment
        public let delivered: Int
        public let total: Int
        public let error: Error

        /// `reason`, prefixed with how much of the batch landed (`progressNote`).
        public func note(_ reason: String) -> String {
            GramAttachmentSender.progressNote(reason, delivered: delivered, total: total)
        }
    }

    /// Tries for a post the host refuses with `upload_in_progress`. Three tries over ~3 s:
    /// the daemon's own reap is 60 s, but the case this covers is a teardown a few hundred
    /// ms behind the post.
    public nonisolated static let postAttempts = 3

    private let upload: Upload
    private let preUploaded: PreUploaded
    private let post: Post
    private let retryDelayNanoseconds: UInt64

    public init(
        upload: @escaping Upload,
        preUploaded: @escaping PreUploaded = { _ in nil },
        post: @escaping Post,
        retryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.upload = upload
        self.preUploaded = preUploaded
        self.post = post
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    /// Delivers every file of `batch` that has not posted yet and returns the whole batch
    /// as delivered, in batch order (for `GramAttachmentPrompt`), or the failure that
    /// stopped it. Files already on the host (a finished pre-upload, or a resumed send's)
    /// post first, so a finished upload never waits behind one still running; the rest
    /// follow in order. `sending` names each file as its upload/post starts; `update`
    /// receives every change to a file's `uploadID` / `messageID`. A posted file's staged
    /// bytes are removed at once: nothing reads them again.
    public func send(
        _ batch: [ComposerAttachment],
        sending: (ComposerAttachment) -> Void = { _ in },
        update: (ComposerAttachment) -> Void
    ) async -> Result<[GramAttachmentPrompt.Delivered], Failure> {
        let onHost = batch.indices.filter { batch[$0].uploadID != nil || batch[$0].messageID != nil }
        let order = onHost + batch.indices.filter { !onHost.contains($0) }
        var delivered: [Int: GramAttachmentPrompt.Delivered] = [:]
        for index in order {
            var file = batch[index]
            if file.messageID == nil {
                sending(file)
                do {
                    try await deliver(&file, update: update)
                } catch {
                    return .failure(Failure(
                        attachment: file, delivered: delivered.count, total: batch.count, error: error))
                }
            }
            delivered[index] = GramAttachmentPrompt.Delivered(
                name: file.name, isImage: file.isImage, messageID: file.messageID ?? "")
        }
        return .success(batch.indices.compactMap { delivered[$0] })
    }

    private func deliver(_ file: inout ComposerAttachment, update: (ComposerAttachment) -> Void) async throws {
        if file.uploadID == nil {
            // A file the composer started uploading as it was added: wait for that upload
            // (or take the one that already landed) rather than send the bytes twice.
            if let pending = try await preUploaded(file) {
                file.uploadID = pending
            } else {
                file.uploadID = try await upload(file)
            }
            update(file)
        }
        let messageID: String
        do {
            messageID = try await postRetryingInProgress(file)
        } catch let error where Self.isStaleUpload(error) {
            // The host holds nothing under that upload id (an earlier post used it up, or
            // it aged out): upload the file again and post once more.
            file.uploadID = nil
            update(file)
            file.uploadID = try await upload(file)
            update(file)
            messageID = try await postRetryingInProgress(file)
        }
        file.messageID = messageID
        update(file)
        try? FileManager.default.removeItem(at: file.staged.dir)
    }

    /// Posts an uploaded file, retrying the POST — never the upload — while the daemon
    /// still owns the `upload_id`.
    ///
    /// The daemon frees its single-writer claim only when it observes EOF on the upload
    /// connection, and the client's close wait is bounded, so a stalled link can put the
    /// post in front of that release. Uploading again would mint a FRESH `upload_id` and
    /// transfer the whole file again, leaving the previous — complete — staging file to
    /// age out over 24 hours; ten taps of a 100 MB attachment would exhaust the daemon's
    /// 1 GiB staging budget and fail every gram upload from every client. The bytes are
    /// already there, so all that is needed is to ask again.
    private func postRetryingInProgress(_ file: ComposerAttachment) async throws -> String {
        let attachment = HerdrClient.GramFileAttachment(
            uploadID: file.uploadID ?? "", name: file.name, mime: file.mime)
        var attempt = 1
        while true {
            do {
                return try await post(file, attachment)
            } catch let error as APIError where error.code == "upload_in_progress" && attempt < Self.postAttempts {
                attempt += 1
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
    }

    /// The host has no staged upload under the posted `upload_id`: it was already consumed
    /// by an earlier post, or never finished. The file must be uploaded again before posting.
    public nonisolated static func isStaleUpload(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        return api.code == "invalid_params" && api.message.contains("no staged upload")
    }

    /// Says how much of a batch landed before the failure, so a retry is an informed act
    /// rather than a guess. Posted grams are NOT rolled back: their files keep their
    /// message id and the retry skips them.
    public nonisolated static func progressNote(_ reason: String, delivered: Int, total: Int) -> String {
        guard total > 1, delivered > 0 else { return reason }
        return "Sent \(delivered) of \(total). \(reason)"
    }
}
