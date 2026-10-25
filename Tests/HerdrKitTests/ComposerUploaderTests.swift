import Foundation
@testable import HerdrKit
import XCTest

/// `ComposerUploader`: each composer's uploads start as files are added, one at a time,
/// before Send. The upload is a scripted closure that stays open until the test finishes,
/// fails or cancels it, so the order, the cancellation and the progress are observed
/// rather than raced.
@MainActor
final class ComposerUploaderTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ComposerUploaderTests-\(UUID().uuidString)", isDirectory: true)
    /// Uploads under way, by file name, each held until the test ends it.
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var reporters: [String: ComposerUploader.Progress] = [:]
    private var started: [String] = []
    private var cancelled: [String] = []
    private var running = 0
    private var mostRunning = 0
    /// The upload ids the uploader wrote back into the composer's list, by file id.
    private var written: [UUID: String] = [:]
    private var discarded: [String] = []

    private func stage(_ name: String) throws -> ComposerAttachment {
        let root = root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("12345678".utf8).write(to: url)
        return ComposerAttachment(name: name, mime: "text/plain", isImage: false,
                                  staged: StagedAttachment(url: url, dir: dir, size: 8))
    }

    private var upload: ComposerUploader.Upload {
        { [unowned self] file, report in
            started.append(file.name)
            reporters[file.name] = report
            running += 1
            mostRunning = max(mostRunning, running)
            defer { running -= 1 }
            let name = file.name
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        cancelled.append(name)
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pending[name] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancelUpload(name) }
            }
        }
    }

    private var uploaded: ComposerUploader.Uploaded {
        { [unowned self] id, uploadID in written[id] = uploadID }
    }

    private var discard: ComposerUploader.Discard {
        { [unowned self] uploadID in discarded.append(uploadID) }
    }

    private func start(_ uploader: ComposerUploader, _ files: ComposerAttachment...) {
        for file in files {
            uploader.start(file, upload: upload, uploaded: uploaded, discard: discard)
        }
    }

    private func finish(_ name: String, as uploadID: String) {
        pending.removeValue(forKey: name)?.resume(returning: uploadID)
    }

    private func fail(_ name: String) {
        pending.removeValue(forKey: name)?.resume(throwing: URLError(.networkConnectionLost))
    }

    private func cancelUpload(_ name: String) {
        guard let continuation = pending.removeValue(forKey: name) else { return }
        cancelled.append(name)
        continuation.resume(throwing: CancellationError())
    }

    /// Lets the uploader's tasks run until `condition` holds (2 s at most).
    private func until(
        _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        var tries = 0
        while !condition(), tries < 2000 {
            tries += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// A short settle, for asserting something did NOT happen.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func testStartsEachUploadAsItIsAddedOneAtATimeInOrder() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt"), c = try stage("c.txt")
        start(uploader, a, b, c)

        await until("the first file starts uploading at once") { started == ["a.txt"] }
        await settle()
        XCTAssertEqual(started, ["a.txt"], "the others wait their turn")
        XCTAssertEqual(uploader.phase(of: b.id), .queued)
        XCTAssertEqual(uploader.phase(of: c.id), .queued)

        finish("a.txt", as: "u-a")
        await until("the next file starts once the first lands") { started == ["a.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        await until("then the last") { started == ["a.txt", "b.txt", "c.txt"] }
        finish("c.txt", as: "u-c")
        await until("every upload lands") { uploader.phase(of: c.id) == .uploaded(uploadID: "u-c") }

        XCTAssertEqual(mostRunning, 1, "never two uploads at once")
        XCTAssertEqual(uploader.phase(of: a.id), .uploaded(uploadID: "u-a"))
        XCTAssertEqual(written, [a.id: "u-a", b.id: "u-b", c.id: "u-c"],
                       "each upload id is written back into the composer's list")
        XCTAssertEqual(discarded, [])
    }

    func testRemovingAFileCancelsItsUploadDeletesItsCopyAndFreesTheLine() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt"), c = try stage("c.txt")
        start(uploader, a, b, c)
        await until("a starts") { started == ["a.txt"] }

        uploader.remove(c)
        uploader.remove(a)
        await until("removing the running file cancels its upload") { cancelled == ["a.txt"] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.staged.dir.path), "its local copy goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.staged.dir.path))
        XCTAssertNil(uploader.phase(of: a.id))
        XCTAssertNil(uploader.phase(of: c.id))

        await until("the next file takes the line") { started == ["a.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        await until("b lands") { uploader.phase(of: b.id) == .uploaded(uploadID: "u-b") }
        await settle()
        XCTAssertEqual(started, ["a.txt", "b.txt"], "a removed file that was waiting never uploads")
        XCTAssertNil(written[a.id])
        XCTAssertEqual(discarded, [], "nothing landed for the removed files, so nothing to discard")
    }

    func testPublishesProgressPerAttachment() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt")
        start(uploader, a, b)
        await until("a starts") { reporters["a.txt"] != nil }
        XCTAssertEqual(uploader.phase(of: a.id), .uploading(sent: 0, total: 8))

        reporters["a.txt"]?(3, 8)
        XCTAssertEqual(uploader.phase(of: a.id), .uploading(sent: 3, total: 8))
        XCTAssertEqual(uploader.phase(of: b.id), .queued, "only the running file moves")
        XCTAssertEqual(uploader.pendingProgress(of: [a.id, b.id]) ?? -1, 3.0 / 16, accuracy: 0.0001,
                       "Send's remaining progress spans every file still to land")

        finish("a.txt", as: "u-a")
        await until("b starts") { reporters["b.txt"] != nil }
        reporters["b.txt"]?(6, 8)
        reporters["a.txt"]?(1, 8)
        XCTAssertEqual(uploader.phase(of: a.id), .uploaded(uploadID: "u-a"),
                       "a finished upload's late report changes nothing")
        XCTAssertEqual(uploader.phase(of: b.id), .uploading(sent: 6, total: 8))
        XCTAssertEqual(uploader.pendingProgress(of: [a.id, b.id]) ?? -1, 6.0 / 8, accuracy: 0.0001)

        finish("b.txt", as: "u-b")
        await until("b lands") { uploader.phase(of: b.id) == .uploaded(uploadID: "u-b") }
        XCTAssertNil(uploader.pendingProgress(of: [a.id, b.id]), "nothing left to wait for")
    }

    func testRemovingAFinishedUploadDiscardsItOnTheHost() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt")
        start(uploader, a, b)
        await until("a starts") { started == ["a.txt"] }
        finish("a.txt", as: "u-a")
        await until("b starts") { started == ["a.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        await until("both land") { uploader.phase(of: b.id) == .uploaded(uploadID: "u-b") }

        uploader.remove(a)
        await until("the removed file's upload is discarded") { discarded == ["u-a"] }

        var posted = b
        posted.messageID = "m1"
        uploader.remove(posted)
        await settle()
        XCTAssertEqual(discarded, ["u-a"], "a posted file's upload was consumed by the post")
    }

    /// Sent files are forgotten, not discarded: their posts consumed the uploads.
    func testSentFilesAreForgottenWithoutADiscard() async throws {
        var uploader: ComposerUploader? = ComposerUploader()
        let a = try stage("a.txt")
        start(uploader!, a)
        await until("a starts") { started == ["a.txt"] }
        finish("a.txt", as: "u-a")
        await until("a lands") { uploader?.phase(of: a.id) == .uploaded(uploadID: "u-a") }

        uploader?.forget([a.id])
        XCTAssertNil(uploader?.phase(of: a.id))
        uploader = nil
        await settle()
        XCTAssertEqual(discarded, [], "neither forgetting nor closing discards a posted upload")
    }

    /// The composer's state going (its pane closed) abandons the draft: the running upload is
    /// cancelled and every finished one is discarded on the host.
    func testReleasingTheUploaderCancelsAndDiscardsEverything() async throws {
        var uploader: ComposerUploader? = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt")
        start(uploader!, a, b)
        await until("a starts") { started == ["a.txt"] }
        finish("a.txt", as: "u-a")
        await until("b starts") { started == ["a.txt", "b.txt"] }

        weak var released = uploader
        uploader = nil
        XCTAssertNil(released, "nothing but the composer holds the uploader, even mid-upload")
        await until("b's upload is cancelled") { cancelled == ["b.txt"] }
        await until("a's upload is discarded") { discarded == ["u-a"] }
    }

    /// An older host (or a federated peer) cannot deserialize `gram.upload.discard`; the
    /// remove goes through all the same and the bytes are left to the host's sweep.
    func testAHostWithoutDiscardIsIgnored() async throws {
        let transport = RecordingTransport.error(
            code: "invalid_request",
            message: "invalid request: unknown variant `gram.upload.discard`, expected one of `ping`")
        let client = HerdrClient(transport: transport)
        let discardedOnHost = try await client.gramUploadDiscard(uploadID: "u-a")
        XCTAssertFalse(discardedOnHost)
        let request = try transport.last()
        XCTAssertEqual(request.method, "gram.upload.discard")
        XCTAssertEqual(request.params["upload_id"] as? String, "u-a")

        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt")
        uploader.start(a, upload: upload, uploaded: uploaded) { _ = try await client.gramUploadDiscard(uploadID: $0) }
        await until("a starts") { started == ["a.txt"] }
        finish("a.txt", as: "u-a2")
        await until("a lands") { uploader.phase(of: a.id) == .uploaded(uploadID: "u-a2") }
        uploader.remove(a)
        await until("the discard is asked for") { transport.requestLines.count == 2 }
        XCTAssertNil(uploader.phase(of: a.id))

        start(uploader, b)
        await until("the uploader carries on") { started == ["a.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        await until("b lands") { uploader.phase(of: b.id) == .uploaded(uploadID: "u-b") }
    }

    func testTheDiscardCallReadsTheHostsAnswerAndSurfacesOtherErrors() async throws {
        let answered = RecordingTransport(
            reply: #"{"id":"x","result":{"type":"gram_upload_discarded","discarded":true}}"#)
        let discardedOnHost = try await HerdrClient(transport: answered).gramUploadDiscard(uploadID: "u-a")
        XCTAssertTrue(discardedOnHost)

        let busy = RecordingTransport.error(code: "upload_in_progress", message: "read the upload connection to EOF")
        do {
            try await HerdrClient(transport: busy).gramUploadDiscard(uploadID: "u-a")
            XCTFail("only an unknown method is read as unsupported")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "upload_in_progress")
        }
    }

    func testSendWaitsForTheRunningUploadAndAFailureCanBeRetried() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt")
        start(uploader, a)
        await until("a starts") { started == ["a.txt"] }

        let waiting = Task { try await uploader.waitForUpload(a.id) }
        await settle()
        finish("a.txt", as: "u-a")
        let waited = try await waiting.value
        XCTAssertEqual(waited, "u-a")
        let landed = try await uploader.waitForUpload(a.id)
        XCTAssertEqual(landed, "u-a", "a landed upload answers at once")

        let b = try stage("b.txt")
        start(uploader, b)
        await until("b starts") { started == ["a.txt", "b.txt"] }
        fail("b.txt")
        await until("b fails") { uploader.phase(of: b.id) == .failed }
        let none = try await uploader.waitForUpload(b.id)
        XCTAssertNil(none, "a failed upload is not waited for: Send uploads it itself")

        uploader.retry(b.id)
        await until("tap to retry uploads it again") { started == ["a.txt", "b.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        await until("b lands") { uploader.phase(of: b.id) == .uploaded(uploadID: "u-b") }
        XCTAssertEqual(written[b.id], "u-b")
    }

    /// Send's own upload (a stale or failed pre-upload) queues behind the running one.
    func testSendsOwnUploadQueuesBehindTheRunningOne() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt"), b = try stage("b.txt")
        start(uploader, a)
        await until("a starts") { started == ["a.txt"] }

        let sending = Task { try await uploader.upload(b, using: upload, uploaded: uploaded, discard: discard) }
        await settle()
        XCTAssertEqual(started, ["a.txt"], "b waits for a")
        finish("a.txt", as: "u-a")
        await until("b starts after a") { started == ["a.txt", "b.txt"] }
        finish("b.txt", as: "u-b")
        let uploadID = try await sending.value
        XCTAssertEqual(uploadID, "u-b")
        XCTAssertEqual(mostRunning, 1)
    }

    func testLeavingPausesUploadsNoSendWaitsOnAndComingBackResumesThem() async throws {
        let uploader = ComposerUploader()
        let a = try stage("a.txt")
        start(uploader, a)
        await until("a starts") { started == ["a.txt"] }

        uploader.pause()
        await until("leaving cancels the running upload") { cancelled == ["a.txt"] }
        await settle()
        XCTAssertEqual(uploader.phase(of: a.id), .paused)

        uploader.resume()
        await until("coming back starts it again") { started == ["a.txt", "a.txt"] }
        let waiting = Task { try await uploader.waitForUpload(a.id) }
        await settle()
        uploader.pause()
        await settle()
        XCTAssertEqual(cancelled, ["a.txt"], "an upload a Send waits on keeps running")
        finish("a.txt", as: "u-a")
        let waited = try await waiting.value
        XCTAssertEqual(waited, "u-a")
    }
}
