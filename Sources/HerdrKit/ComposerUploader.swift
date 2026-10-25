import Foundation
import Observation

/// Uploads a composer's attachments while the message is still being written, so Send only
/// has to post them and prompt. One per composer (the terminal reply, the guest pane, the
/// Gram page), all driving the same `GramAttachmentSender` on Send.
///
/// - UPLOAD ONLY. Each file's bytes go to the host's staging the moment it is added, but
///   nothing is posted: the agent sees nothing until Send, so a file removed from the draft
///   leaves nothing in its inbox to undo.
/// - ONE AT A TIME, in the order added, like the sender: every staged upload counts against
///   the host's shared 1 GiB staging budget, so ten parallel 100 MiB uploads would fill it
///   for every client on the box. A Send that needs a file uploaded queues behind the same
///   line (`upload(_:using:uploaded:discard:)`) rather than racing it.
/// - Progress is published per attachment id (`phases`), and a finished upload's id is
///   handed to the composer (`Uploaded`) so its staged list carries it, exactly as a
///   resumed send's would.
/// - `waitForUpload(_:)` lets Send await an upload already running instead of starting a
///   second one (`GramAttachmentSender.PreUploaded`).
/// - Removing a file cancels its upload and deletes its local copy; a finished upload is
///   discarded on the host (`gram.upload.discard`, best effort: a host without it, or a
///   discard that fails, leaves the bytes to the host's 24 h staging sweep).
/// - Leaving the composer pauses the uploads nobody is waiting on (`pause()`); coming back
///   resumes them (`resume()`). A Send already waiting on one keeps it running.
/// - The draft is abandoned when the composer's state goes (its pane closed): releasing the
///   uploader cancels the running upload and discards every finished one nothing posted.
@MainActor
@Observable
public final class ComposerUploader {
    /// Byte progress of the running upload, `(sent, total)`.
    public typealias Progress = @MainActor @Sendable (_ sent: Int, _ total: Int) -> Void
    /// Uploads one file's staged bytes, reporting progress; returns the host's `upload_id`.
    public typealias Upload = @MainActor (ComposerAttachment, _ progress: @escaping Progress) async throws -> String
    /// A file's upload finished: write `uploadID` into the composer's staged file `id`.
    public typealias Uploaded = @MainActor (_ id: UUID, _ uploadID: String) -> Void
    /// Drops a finished upload the composer will never post (`HerdrClient.gramUploadDiscard`).
    public typealias Discard = @MainActor (_ uploadID: String) async throws -> Void

    public enum Phase: Equatable, Sendable {
        /// Waiting behind another file's upload.
        case queued
        case uploading(sent: Int, total: Int)
        /// On the host, ready to post.
        case uploaded(uploadID: String)
        /// Stopped because the composer went away; `resume()` queues it again.
        case paused
        /// The upload failed; `retry(_:)` (or Send) uploads it again.
        case failed
    }

    /// Each staged file's upload, by attachment id. Absent for a file this uploader does
    /// not know (never started, removed, or sent).
    public private(set) var phases: [UUID: Phase] = [:]

    private struct Job {
        var file: ComposerAttachment
        let upload: Upload
        let uploaded: Uploaded
        let discard: Discard
        /// Sends awaiting this upload, resumed when it finishes.
        var waiters: [CheckedContinuation<String, Error>] = []
    }

    private struct Running {
        let id: UUID
        let attempt: Int
        let task: Task<String, Error>
        /// Set when the file was removed mid-upload: an upload that completes anyway is
        /// discarded the moment it lands.
        var discardOnLanding: Discard?
    }

    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    /// Ids in the order they were added: the upload order.
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var running: Running?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    /// What `deinit` cleans up, readable off the main actor.
    private let leftovers = Leftovers()

    /// Nonisolated so a SwiftUI view can hold one as `@State` from its initializer.
    public nonisolated init() {}

    deinit {
        leftovers.abandon()
    }

    public func phase(of id: UUID) -> Phase? { phases[id] }

    /// Queues `file`'s upload behind any already running, and starts it if the line is free.
    public func start(
        _ file: ComposerAttachment, upload: @escaping Upload, uploaded: @escaping Uploaded,
        discard: @escaping Discard
    ) {
        guard jobs[file.id] == nil else { return }
        jobs[file.id] = Job(file: file, upload: upload, uploaded: uploaded, discard: discard)
        order.append(file.id)
        phases[file.id] = .queued
        pump()
    }

    /// Uploads a failed or paused file again (the chip's tap to retry).
    public func retry(_ id: UUID) {
        switch phases[id] {
        case .failed, .paused:
            phases[id] = .queued
            pump()
        default:
            break
        }
    }

    /// The host's id for `id`'s pre-upload: at once when it has finished, after it
    /// finishes when it is queued or running (throwing its failure), or nil when there is
    /// none to wait for (never started, paused, failed) and the caller must upload now.
    public func waitForUpload(_ id: UUID) async throws -> String? {
        switch phases[id] {
        case .uploaded(let uploadID):
            return uploadID
        case .queued, .uploading:
            return try await withCheckedThrowingContinuation { continuation in
                jobs[id]?.waiters.append(continuation)
            }
        case .paused, .failed, nil:
            return nil
        }
    }

    /// Uploads `file` now, in line behind any running upload, and returns the host's id:
    /// Send's upload step for a file with no pre-upload to wait for, and for one whose
    /// upload the host has lost (`GramAttachmentSender.isStaleUpload`). Awaits the upload
    /// already running or queued for it rather than starting a second one.
    public func upload(
        _ file: ComposerAttachment, using upload: @escaping Upload, uploaded: @escaping Uploaded,
        discard: @escaping Discard
    ) async throws -> String {
        if jobs[file.id] == nil {
            jobs[file.id] = Job(file: file, upload: upload, uploaded: uploaded, discard: discard)
            order.append(file.id)
        }
        switch phases[file.id] {
        case .queued, .uploading:
            break
        default:
            // A finished upload asked for again is one the host lost: nothing to discard.
            leftovers.forget(file.id)
            phases[file.id] = .queued
            pump()
        }
        return try await withCheckedThrowingContinuation { continuation in
            jobs[file.id]?.waiters.append(continuation)
        }
    }

    /// The file left the draft: cancels its upload (running or queued), deletes its local
    /// copy, and discards a finished upload on the host. A file that already posted
    /// (`messageID`) has nothing staged to discard.
    public func remove(_ file: ComposerAttachment) {
        try? FileManager.default.removeItem(at: file.staged.dir)
        let phase = phases[file.id]
        let discard = jobs[file.id]?.discard
        drop(file.id, discardIfItLands: file.messageID == nil)
        if file.messageID == nil, case .uploaded(let uploadID) = phase, let discard {
            Task { try? await discard(uploadID) }
        }
    }

    /// Sent files: forgotten without a discard, since each post consumed its upload.
    public func forget(_ ids: some Sequence<UUID>) {
        for id in ids { drop(id, discardIfItLands: false) }
    }

    /// The composer went off screen: stops every upload no Send is waiting on. Finished
    /// uploads stay; `resume()` picks the stopped ones up again.
    public func pause() {
        for id in order where jobs[id]?.waiters.isEmpty == true {
            switch phases[id] {
            case .queued, .uploading:
                phases[id] = .paused
                if running?.id == id { running?.task.cancel() }
            default:
                break
            }
        }
    }

    /// The composer is back: queues the uploads `pause()` stopped.
    public func resume() {
        var resumed = false
        for id in order where phases[id] == .paused {
            phases[id] = .queued
            resumed = true
        }
        if resumed { pump() }
    }

    /// Byte progress over the uploads still to finish among `ids` (queued or running), for
    /// the Send button while it waits on them. Nil when none of them is pending.
    public func pendingProgress(of ids: [UUID]) -> Double? {
        var sent = 0
        var total = 0
        var pending = false
        for id in ids {
            switch phases[id] {
            case .queued:
                pending = true
                total += jobs[id]?.file.size ?? 0
            case .uploading(let done, let size):
                pending = true
                sent += done
                total += max(size, done)
            default:
                break
            }
        }
        guard pending else { return nil }
        guard total > 0 else { return 0 }
        return min(1, Double(sent) / Double(total))
    }

    // MARK: - The line

    private func drop(_ id: UUID, discardIfItLands: Bool) {
        phases[id] = nil
        leftovers.forget(id)
        guard let job = jobs.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if running?.id == id {
            running?.discardOnLanding = discardIfItLands ? job.discard : nil
            running?.task.cancel()
        }
        for waiter in job.waiters { waiter.resume(throwing: CancellationError()) }
    }

    /// One task works the line, holding the uploader only between uploads (never across
    /// one), so releasing the uploader is what abandons the draft.
    private func pump() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let next = self?.startNext() {
                // The line waits for a cancelled upload to wind down too, so the next file
                // never overlaps the teardown of the last.
                let result = await next.task.result
                self?.complete(next, result)
            }
            self?.runner = nil
        }
    }

    private func startNext() -> Running? {
        guard let id = order.first(where: { phases[$0] == .queued }), let job = jobs[id] else { return nil }
        attempts += 1
        let attempt = attempts
        let file = job.file
        let upload = job.upload
        phases[id] = .uploading(sent: 0, total: file.size)
        let report: Progress = { [weak self] sent, total in
            self?.progress(id, attempt: attempt, sent: sent, total: total)
        }
        let task = Task { () async throws -> String in try await upload(file, report) }
        let next = Running(id: id, attempt: attempt, task: task)
        running = next
        leftovers.track(task, discard: job.discard)
        return next
    }

    private func progress(_ id: UUID, attempt: Int, sent: Int, total: Int) {
        guard running?.attempt == attempt, case .uploading = phases[id] else { return }
        phases[id] = .uploading(sent: sent, total: total)
    }

    private func complete(_ started: Running, _ result: Result<String, Error>) {
        // `drop` marks the running upload when its file is removed; one upload runs at a time.
        let discardOnLanding = running?.discardOnLanding
        running = nil
        leftovers.track(nil, discard: nil)
        let id = started.id
        guard var job = jobs[id] else {
            // Removed mid-upload. One that landed anyway would hold staging until the sweep.
            if case .success(let uploadID) = result, let discard = discardOnLanding {
                Task { try? await discard(uploadID) }
            }
            return
        }
        switch result {
        case .success(let uploadID):
            let waiters = job.waiters
            job.waiters = []
            job.file.uploadID = uploadID
            jobs[id] = job
            phases[id] = .uploaded(uploadID: uploadID)
            leftovers.landed(id, uploadID, job.discard)
            job.uploaded(id, uploadID)
            for waiter in waiters { waiter.resume(returning: uploadID) }
        case .failure(let error):
            // Paused, or paused and queued again since: the stop was ours, not a failure,
            // and whoever waits is served by the next run.
            guard case .uploading = phases[id] else { return }
            let waiters = job.waiters
            job.waiters = []
            jobs[id] = job
            phases[id] = .failed
            for waiter in waiters { waiter.resume(throwing: error) }
        }
    }
}

/// The uploads a released `ComposerUploader` must not leave behind: the one running, and
/// every finished upload nothing posted. Lock-guarded because `deinit` reaches it off the
/// main actor.
private final class Leftovers: @unchecked Sendable {
    private let lock = NSLock()
    private var uploads: [UUID: (uploadID: String, discard: ComposerUploader.Discard)] = [:]
    private var task: Task<String, Error>?
    private var taskDiscard: ComposerUploader.Discard?

    func track(_ task: Task<String, Error>?, discard: ComposerUploader.Discard?) {
        lock.lock()
        self.task = task
        taskDiscard = discard
        lock.unlock()
    }

    func landed(_ id: UUID, _ uploadID: String, _ discard: @escaping ComposerUploader.Discard) {
        lock.lock()
        uploads[id] = (uploadID, discard)
        lock.unlock()
    }

    func forget(_ id: UUID) {
        lock.lock()
        uploads[id] = nil
        lock.unlock()
    }

    /// The draft is gone: cancels the running upload (discarding it if it lands anyway)
    /// and discards every finished one.
    func abandon() {
        lock.lock()
        let running = task
        let pending = running != nil || !uploads.isEmpty
        lock.unlock()
        running?.cancel()
        guard pending else { return }
        Task { @MainActor in
            if let running = self.takeRunning(), case .success(let uploadID) = await running.task.result {
                try? await running.discard(uploadID)
            }
            for (uploadID, discard) in self.takeUploads() { try? await discard(uploadID) }
        }
    }

    private func takeRunning() -> (task: Task<String, Error>, discard: ComposerUploader.Discard)? {
        lock.lock()
        defer { lock.unlock() }
        guard let task, let taskDiscard else { return nil }
        self.task = nil
        self.taskDiscard = nil
        return (task, taskDiscard)
    }

    private func takeUploads() -> [(String, ComposerUploader.Discard)] {
        lock.lock()
        defer { lock.unlock() }
        let taken = uploads.values.map { ($0.uploadID, $0.discard) }
        uploads = [:]
        return taken
    }
}
