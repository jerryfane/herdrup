import Foundation
@testable import HerdrKit
import XCTest

/// `GramAttachmentSender`: the one attachment send path behind the Gram page, the terminal
/// reply and the guest composer. Upload and post are scripted closures recording each call
/// as `upload <name>` / `post <name>@<upload id>`.
@MainActor
final class GramAttachmentSenderTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GramAttachmentSenderTests-\(UUID().uuidString)", isDirectory: true)
    /// The composer's staged list, as each caller keeps it: `update` writes into it.
    private var staged: [ComposerAttachment] = []
    private var calls: [String] = []
    private var uploads = 0
    private var posts = 0
    /// Errors the next posts throw, in order, before posts succeed.
    private var postErrors: [String: [Error]] = [:]
    private var uploadErrors: [String: [Error]] = [:]
    /// The composer's pre-upload lookup (`ComposerUploader.waitForUpload`); none by default.
    private var preUploaded: GramAttachmentSender.PreUploaded = { _ in nil }

    private func stage(_ names: String...) throws -> [ComposerAttachment] {
        let root = root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try names.map { name -> ComposerAttachment in
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try Data("bytes of \(name)".utf8).write(to: url)
            return ComposerAttachment(
                name: name, mime: name.hasSuffix(".png") ? "image/png" : "text/plain",
                isImage: name.hasSuffix(".png"),
                staged: StagedAttachment(url: url, dir: dir, size: 8))
        }
        staged = files
        return files
    }

    private var sender: GramAttachmentSender {
        GramAttachmentSender(
            upload: { [unowned self] file in
                calls.append("upload \(file.name)")
                if var errors = uploadErrors[file.name], !errors.isEmpty {
                    let error = errors.removeFirst()
                    uploadErrors[file.name] = errors
                    throw error
                }
                uploads += 1
                return "u\(uploads)"
            },
            preUploaded: preUploaded,
            post: { [unowned self] file, attachment in
                calls.append("post \(file.name)@\(attachment.uploadID)")
                XCTAssertEqual(attachment.name, file.name)
                XCTAssertEqual(attachment.mime, file.mime)
                if var errors = postErrors[file.name], !errors.isEmpty {
                    let error = errors.removeFirst()
                    postErrors[file.name] = errors
                    throw error
                }
                posts += 1
                return "m\(posts)"
            },
            retryDelayNanoseconds: 0)
    }

    private func send(_ batch: [ComposerAttachment], sending: inout [String]) async
        -> Result<[GramAttachmentPrompt.Delivered], GramAttachmentSender.Failure>
    {
        var started: [String] = []
        let result = await sender.send(batch, sending: { started.append($0.name) }) { [unowned self] file in
            guard let index = staged.firstIndex(where: { $0.id == file.id }) else { return }
            staged[index] = file
        }
        sending = started
        return result
    }

    private func send(_ batch: [ComposerAttachment]) async
        -> Result<[GramAttachmentPrompt.Delivered], GramAttachmentSender.Failure>
    {
        var ignored: [String] = []
        return await send(batch, sending: &ignored)
    }

    private static let inProgress = APIError(code: "upload_in_progress", message: "read the upload connection to EOF")
    private static let stale = APIError(
        code: "invalid_params", message: "no staged upload with that id; upload the file chunks first")

    func testUploadsAndPostsEachFileInOrderAndDropsItsStagedBytes() async throws {
        let batch = try stage("a.txt", "b.png")
        var started: [String] = []
        let delivered = try await send(batch, sending: &started).get()

        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1", "upload b.png", "post b.png@u2"])
        XCTAssertEqual(started, ["a.txt", "b.png"])
        XCTAssertEqual(delivered.map(\.name), ["a.txt", "b.png"])
        XCTAssertEqual(delivered.map(\.isImage), [false, true])
        XCTAssertEqual(delivered.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(staged.map(\.messageID), ["m1", "m2"])
        for file in batch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.staged.dir.path),
                           "a posted file's staged bytes are not read again")
        }
    }

    /// THE RESUME. A batch that fails partway keeps each file's upload id and message id,
    /// so the retry posts nothing twice and uploads nothing twice.
    func testARetryAfterAPartialFailureResumesWhereTheBatchStopped() async throws {
        _ = try stage("a.txt", "b.txt", "c.txt")
        postErrors["b.txt"] = [URLError(.networkConnectionLost)]

        guard case .failure(let failure) = await send(staged) else {
            return XCTFail("the batch should stop at b.txt")
        }
        XCTAssertEqual(failure.attachment.name, "b.txt")
        XCTAssertEqual(failure.delivered, 1)
        XCTAssertEqual(failure.total, 3)
        XCTAssertEqual(failure.note("send failed"), "Sent 1 of 3. send failed")
        XCTAssertEqual(staged.map(\.messageID), ["m1", nil, nil])
        XCTAssertEqual(staged.map(\.uploadID), ["u1", "u2", nil])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged[1].staged.url.path),
                      "the failed file's bytes stay staged for the retry")

        calls = []
        var started: [String] = []
        let delivered = try await send(staged, sending: &started).get()
        XCTAssertEqual(calls, ["post b.txt@u2", "upload c.txt", "post c.txt@u3"],
                       "a: already posted; b: already uploaded")
        XCTAssertEqual(started, ["b.txt", "c.txt"])
        XCTAssertEqual(delivered.map(\.messageID), ["m1", "m2", "m3"])
    }

    func testAFailedUploadIsUploadedAgainOnTheRetry() async throws {
        _ = try stage("a.txt")
        uploadErrors["a.txt"] = [URLError(.timedOut)]

        guard case .failure(let failure) = await send(staged) else {
            return XCTFail("the upload should fail")
        }
        XCTAssertEqual(failure.delivered, 0)
        XCTAssertEqual(failure.note("send failed"), "send failed")
        XCTAssertNil(staged[0].uploadID)
        XCTAssertEqual(posts, 0)

        calls = []
        _ = try await send(staged).get()
        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1"])
    }

    func testAStaleUploadIsUploadedAgainAndPostedOnce() async throws {
        _ = try stage("a.txt", "b.txt")
        postErrors["a.txt"] = [Self.stale]

        let delivered = try await send(staged).get()
        XCTAssertEqual(calls, [
            "upload a.txt", "post a.txt@u1", "upload a.txt", "post a.txt@u2",
            "upload b.txt", "post b.txt@u3",
        ])
        XCTAssertEqual(delivered.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(staged[0].uploadID, "u2")
    }

    /// A stale upload on a RESUMED file (its kept upload id was consumed or aged out) is
    /// the case the guest added the re-upload for.
    func testAKeptUploadIDTheHostHasLostIsUploadedAgain() async throws {
        var batch = try stage("a.txt")
        batch[0].uploadID = "old"
        staged = batch
        postErrors["a.txt"] = [Self.stale]

        _ = try await send(staged).get()
        XCTAssertEqual(calls, ["post a.txt@old", "upload a.txt", "post a.txt@u1"])
    }

    func testAStaleUploadIsUploadedAgainOnlyOnce() async throws {
        _ = try stage("a.txt")
        postErrors["a.txt"] = [Self.stale, Self.stale]

        guard case .failure(let failure) = await send(staged) else {
            return XCTFail("a second stale refusal should stop the batch")
        }
        XCTAssertTrue(GramAttachmentSender.isStaleUpload(failure.error))
        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1", "upload a.txt", "post a.txt@u2"])
    }

    func testAnInProgressPostIsAskedAgainNotUploadedAgain() async throws {
        _ = try stage("a.txt")
        postErrors["a.txt"] = [Self.inProgress, Self.inProgress]

        _ = try await send(staged).get()
        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1", "post a.txt@u1", "post a.txt@u1"])
    }

    func testTheInProgressRetryIsBounded() async throws {
        _ = try stage("a.txt", "b.txt")
        postErrors["a.txt"] = Array(repeating: Self.inProgress, count: 10)

        guard case .failure(let failure) = await send(staged) else {
            return XCTFail("the post should give up")
        }
        XCTAssertEqual((failure.error as? APIError)?.code, "upload_in_progress")
        XCTAssertEqual(calls, ["upload a.txt"] + Array(
            repeating: "post a.txt@u1", count: GramAttachmentSender.postAttempts))
        XCTAssertEqual(GramAttachmentSender.postAttempts, 3)
        XCTAssertEqual(staged[0].uploadID, "u1", "the retry posts these bytes rather than re-sending them")
    }

    func testOtherPostRefusalsAreNotRetried() async throws {
        _ = try stage("a.txt")
        postErrors["a.txt"] = [APIError(code: "invalid_params", message: "text too long")]

        guard case .failure = await send(staged) else { return XCTFail("the post should fail") }
        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1"])
    }

    func testTheProgressNoteNamesHowMuchOfABatchLanded() {
        XCTAssertEqual(GramAttachmentSender.progressNote("x", delivered: 2, total: 3), "Sent 2 of 3. x")
        XCTAssertEqual(GramAttachmentSender.progressNote("x", delivered: 3, total: 3), "Sent 3 of 3. x")
        XCTAssertEqual(GramAttachmentSender.progressNote("x", delivered: 0, total: 3), "x")
        XCTAssertEqual(GramAttachmentSender.progressNote("x", delivered: 1, total: 1), "x")
    }

    /// Send posts the files whose pre-upload already landed first, then waits on the rest;
    /// the prompt still lists every file in the order it was attached.
    func testFinishedUploadsPostBeforeOnesStillUploading() async throws {
        var batch = try stage("a.txt", "b.txt")
        batch[1].uploadID = "pre-b"
        staged = batch
        preUploaded = { [unowned self] file in
            calls.append("wait \(file.name)")
            return "pre-\(file.name.prefix(1))"
        }

        let delivered = try await send(staged).get()
        XCTAssertEqual(calls, ["post b.txt@pre-b", "wait a.txt", "post a.txt@pre-a"])
        XCTAssertEqual(delivered.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(delivered.map(\.messageID), ["m2", "m1"])
    }

    // MARK: Pre-uploads (`ComposerUploader`)

    /// The composer uploaded the file as it was added: Send posts that upload and uploads
    /// nothing. A file with no pre-upload is uploaded as before.
    func testAPreUploadedFileIsPostedWithoutUploadingAgain() async throws {
        _ = try stage("a.txt", "b.txt")
        preUploaded = { [unowned self] file in
            calls.append("pre \(file.name)")
            return file.name == "a.txt" ? "pre-a" : nil
        }

        let delivered = try await send(staged).get()
        XCTAssertEqual(calls, ["pre a.txt", "post a.txt@pre-a", "pre b.txt", "upload b.txt", "post b.txt@u1"])
        XCTAssertEqual(delivered.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(staged.map(\.uploadID), ["pre-a", "u1"])
    }

    /// Send reaches a file whose upload is still running: it waits for that upload and posts
    /// it, rather than sending the same bytes a second time.
    func testAwaitingAnUploadInProgressDoesNotUploadTwice() async throws {
        let batch = try stage("a.txt")
        let uploader = ComposerUploader()
        var release: CheckedContinuation<String, Error>?
        uploader.start(batch[0], upload: { [unowned self] file, _ in
            calls.append("pre-upload \(file.name)")
            return try await withCheckedThrowingContinuation { release = $0 }
        }, uploaded: { [unowned self] id, uploadID in
            guard let index = staged.firstIndex(where: { $0.id == id }) else { return }
            staged[index].uploadID = uploadID
        }, discard: { _ in XCTFail("nothing is discarded on the way to a post") })
        preUploaded = { [unowned self] file in
            calls.append("wait \(file.name)")
            return try await uploader.waitForUpload(file.id)
        }
        await until { release != nil }

        let sending = Task { await self.send(batch) }
        await until { calls.contains("wait a.txt") }
        XCTAssertEqual(calls, ["pre-upload a.txt", "wait a.txt"], "Send waits; nothing is posted yet")
        release?.resume(returning: "pre-a")
        _ = try await sending.value.get()

        XCTAssertEqual(calls, ["pre-upload a.txt", "wait a.txt", "post a.txt@pre-a"])
        XCTAssertEqual(uploads, 0, "the sender's own upload never ran")
        XCTAssertEqual(staged[0].messageID, "m1")
        uploader.forget(batch.map(\.id))  // as a composer does once its files post
    }

    /// A pre-upload the host no longer holds is uploaded again once, by the sender, and the
    /// stale id is not asked for a second time.
    func testAStalePreUploadIsUploadedAgainOnce() async throws {
        _ = try stage("a.txt")
        preUploaded = { [unowned self] file in
            calls.append("pre \(file.name)")
            return "pre-a"
        }
        postErrors["a.txt"] = [Self.stale]

        _ = try await send(staged).get()
        XCTAssertEqual(calls, ["pre a.txt", "post a.txt@pre-a", "upload a.txt", "post a.txt@u1"])
        XCTAssertEqual(staged[0].uploadID, "u1")
    }

    /// A pre-upload that fails while Send waits on it fails the send at that file, as an
    /// upload of its own would.
    func testAPreUploadThatFailsStopsTheBatchThere() async throws {
        _ = try stage("a.txt", "b.txt")
        preUploaded = { file in
            guard file.name == "b.txt" else { return nil }
            throw URLError(.networkConnectionLost)
        }

        guard case .failure(let failure) = await send(staged) else {
            return XCTFail("the batch should stop at b.txt")
        }
        XCTAssertEqual(failure.attachment.name, "b.txt")
        XCTAssertEqual(failure.delivered, 1)
        XCTAssertEqual(calls, ["upload a.txt", "post a.txt@u1"])
    }

    /// Lets the main actor's other tasks run until `condition` holds (2 s at most).
    private func until(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        var tries = 0
        while !condition(), tries < 2000 {
            tries += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
