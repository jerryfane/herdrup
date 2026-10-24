import Foundation
import XCTest
@testable import HerdrKit

/// A guest's Gram and push for the shared agent (herdrup#338): what the host advertises in
/// the hello, how the guest's Gram decodes and downloads, and where a tapped push goes.
final class GuestGramTests: XCTestCase {

    private final class FeatureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GuestFeatures] = []
        var all: [GuestFeatures] { lock.withLock { stored } }
        func append(_ features: GuestFeatures) { lock.withLock { stored.append(features) } }
    }

    // MARK: Hello features

    func testHelloFeaturesReadGramAndPushAndAnOlderHostOffersNeither() {
        let current: [String: Any] = ["ok": true, "guest_id": "g1", "features": ["gram": true, "push": true]]
        XCTAssertEqual(GuestFeatures(helloReply: current), GuestFeatures(gram: true, push: true))

        let pushOnly: [String: Any] = ["ok": true, "features": ["gram": false, "push": true]]
        XCTAssertEqual(GuestFeatures(helloReply: pushOnly), GuestFeatures(gram: false, push: true))

        let older: [String: Any] = ["ok": true, "guest_id": "g1", "agent": ["target": "w1-3"]]
        XCTAssertEqual(GuestFeatures(helloReply: older), .none, "no features object: no Gram tab, no push")

        let odd: [String: Any] = ["ok": true, "features": ["gram": "yes", "push": 1]]
        XCTAssertEqual(GuestFeatures(helloReply: odd), .none, "only a JSON true turns a feature on")
    }

    /// Every relay session reports its hello's features, so a share the owner turned Gram on
    /// for shows the tab on the next call without a new invite.
    func testEveryRelaySessionReportsItsHellosFeatures() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data("{}\n".utf8)] }
        let log = FeatureLog()
        let transport = RelayTransport(guestID: "g_1", endpoint: host.endpoint, identity: GuestIdentity(privateKey: .init()),
                                       connector: host.connector(), onFeatures: { log.append($0) })

        _ = try await transport.roundTrip("a")
        host.reply = ["ok": true, "guest_id": "g_1", "features": ["gram": true, "push": true]]
        _ = try await transport.roundTrip("b")
        for try await _ in transport.stream("c") {}

        XCTAssertEqual(log.all, [.none, GuestFeatures(gram: true, push: true), GuestFeatures(gram: true, push: true)])
    }

    // MARK: Gram list

    func testGuestGramListDecodesTheHostsProjection() async throws {
        let transport = RecordingTransport { _, _ in #"""
        {"id":"x","result":{"type":"guest_gram_list","has_more":true,"messages":[
          {"id":"m3","direction":"agent_to_owner","from":"llm-opt","text":"Q5 table attached",
           "created_unix_ms":1790000300000,"read":false,
           "file":{"name":"tensorfold-q5.md","size":2048,"mime":"text/markdown","sha256":"ab12"}},
          {"id":"m2","direction":"owner_to_agent","from":"plotarmordev (via HerdrUp)","text":"rerun on Q4 too",
           "created_unix_ms":1790000200000,"read":true},
          {"id":"m1","direction":"agent_to_owner","from":"llm-opt","text":"bench started",
           "created_unix_ms":1790000100000,"read":true,"file":{"name":"log.txt","size":10}}]}}
        """# }
        let page = try await HerdrClient(transport: transport).guestGramList(limit: 50, beforeID: "m9")

        XCTAssertEqual(page.messages.map(\.id), ["m3", "m2", "m1"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.unreadCount, 1)
        XCTAssertEqual(page.messages[0].file, GuestGramFile(name: "tensorfold-q5.md", size: 2048,
                                                            mime: "text/markdown", sha256: "ab12"))
        XCTAssertTrue(page.messages[0].isUnread)
        XCTAssertFalse(page.messages[1].isFromAgent, "the guest's own post")
        XCTAssertFalse(page.messages[1].isUnread)
        XCTAssertEqual(page.messages[2].file, GuestGramFile(name: "log.txt", size: 10),
                       "a file without mime or sha256 still decodes")

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.method, "gram.list")
        XCTAssertEqual(request.params["limit"] as? Int, 50)
        XCTAssertEqual(request.params["before_id"] as? String, "m9")
        XCTAssertNil(request.params["caller_pane_id"], "a guest never names a pane")
    }

    /// herdr#298: the guest projection carries `expired_file` for a file the host's store
    /// expired. It decodes as metadata only, never as an openable `file`; absent stays nil.
    func testGuestGramListDecodesAnExpiredFile() async throws {
        let transport = RecordingTransport { _, _ in #"""
        {"id":"x","result":{"type":"guest_gram_list","messages":[
          {"id":"m3","direction":"agent_to_owner","from":"llm-opt","text":"",
           "created_unix_ms":1790000300000,"read":true,
           "expired_file":{"name":"bench.png","size":873472,"mime":"image/png","sha256":"cd34"}},
          {"id":"m2","direction":"agent_to_owner","from":"llm-opt","text":"both",
           "created_unix_ms":1790000200000,"read":true,
           "file":{"name":"live.md","size":10,"mime":"text/markdown","sha256":"ab12"},
           "expired_file":{"name":"old.md","size":10,"mime":"text/markdown","sha256":"ef56"}},
          {"id":"m1","direction":"agent_to_owner","from":"llm-opt","text":"plain",
           "created_unix_ms":1790000100000,"read":true}]}}
        """# }
        let page = try await HerdrClient(transport: transport).guestGramList()

        let expired = page.messages[0]
        XCTAssertNil(expired.file, "an expired file is never a file to open")
        XCTAssertEqual(expired.expiredFile, GuestGramFile(name: "bench.png", size: 873472,
                                                          mime: "image/png", sha256: "cd34"))
        XCTAssertEqual(page.messages[1].file?.name, "live.md")
        XCTAssertNil(page.messages[1].expiredFile, "a message with bytes is not also expired")
        XCTAssertNil(page.messages[2].file)
        XCTAssertNil(page.messages[2].expiredFile, "absent from the wire stays nil")
    }

    /// The guest's Gram tab draws the owner's feed rows: the agent's Grams come from the agent
    /// (unread until the guest's mark), and the guest's own posts go to the shared agent, so
    /// the row says "Delivered to <agent>".
    func testAGuestGramDrawsAsTheOwnersGramMessage() {
        let agents = GuestGramMessage(
            id: "gm-4", direction: .agentToOwner, from: "llm-opt", text: "Q5 table",
            createdUnixMs: 1_790_000_000_000,
            file: GuestGramFile(name: "q5.md", size: 512, mime: "text/markdown", sha256: nil), read: false)
        let owned = agents.gramMessage(agent: "llm-opt")
        XCTAssertEqual(owned.id, "gm-4")
        XCTAssertTrue(owned.isFromAgent)
        XCTAssertNil(owned.to, "the agent's Gram is addressed to no agent")
        XCTAssertTrue(owned.isUnread, "the guest's read mark carries over")
        XCTAssertEqual(owned.createdUnixMs, 1_790_000_000_000)
        XCTAssertEqual(owned.file, GramFile(name: "q5.md", size: 512, mime: "text/markdown", sha256: ""))
        XCTAssertNil(owned.expiredFile)

        let mine = GuestGramMessage(
            id: "gp-1", direction: .ownerToAgent, from: "plotarmordev (via HerdrUp)", text: "",
            createdUnixMs: 1_790_000_060_000,
            expiredFile: GuestGramFile(name: "old.png", size: 9, mime: "image/png", sha256: "9c0d"), read: true)
        let posted = mine.gramMessage(agent: "llm-opt")
        XCTAssertFalse(posted.isFromAgent)
        XCTAssertEqual(posted.to, "llm-opt", "the guest's post is delivered to the shared agent")
        XCTAssertFalse(posted.isOpenQueueItem)
        XCTAssertNil(posted.file)
        XCTAssertEqual(posted.expiredFile, GramFile(name: "old.png", size: 9, mime: "image/png", sha256: "9c0d"))
    }

    func testGuestGramListOmitsUnsetParamsAndClampsTheLimit() async throws {
        let transport = RecordingTransport { _, _ in #"{"id":"x","result":{"type":"guest_gram_list","messages":[]}}"# }
        let client = HerdrClient(transport: transport)
        let page = try await client.guestGramList()
        XCTAssertEqual(page, GuestGramPage(messages: [], hasMore: false), "no has_more means everything")
        XCTAssertTrue(try XCTUnwrap(transport.requests.last).params.isEmpty)
        _ = try await client.guestGramList(limit: 10_000)
        XCTAssertEqual(try XCTUnwrap(transport.requests.last).params["limit"] as? Int, 500)
    }

    func testMarkReadSendsTheIDs() async throws {
        let transport = RecordingTransport { _, _ in #"{"id":"x","result":{"type":"ok"}}"# }
        try await HerdrClient(transport: transport).guestGramMarkRead(ids: ["m3", "m1"])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.method, "gram.mark_read")
        XCTAssertEqual(request.params["ids"] as? [String], ["m3", "m1"])
    }

    /// herdrup#345: the live host's reply to a guest's attachment post, verbatim. It is the
    /// guest projection (no `direction`, no `read_by_owner`), which the owner's `GramMessage`
    /// cannot decode: the post landed, but the app saw a failure and posted the upload again.
    static let liveGuestPostReply = #"{"id":"e2e:gram.post","result":{"type":"gram_sent","message":{"created_unix_ms":1790849045630,"file":{"mime":"text/markdown","name":"brief.md","sha256":"1b000f…","size":6009},"from":"upload-e2e (via HerdrUp)","id":"gram-1a0f6ebd47e-320048-d","text":"Attachment from upload-e2e.","to":"mac-studio"}}}"#

    func testGuestPostDecodesTheHostsProjectedReply() async throws {
        let transport = RecordingTransport { _, _ in Self.liveGuestPostReply }
        let receipt = try await HerdrClient(transport: transport).guestGramPost(
            text: "Attachment from upload-e2e.", to: "mac-studio",
            attachment: HerdrClient.GramFileAttachment(uploadID: "app-1", name: "brief.md", mime: "text/markdown"))
        XCTAssertEqual(receipt.id, "gram-1a0f6ebd47e-320048-d")
        XCTAssertEqual(receipt.to, "mac-studio")
        XCTAssertEqual(receipt.createdUnixMs, 1_790_849_045_630)
        XCTAssertEqual(receipt.file, GuestGramFile(name: "brief.md", size: 6009, mime: "text/markdown", sha256: "1b000f…"))

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.method, "gram.post")
        XCTAssertEqual(request.params["to"] as? String, "mac-studio")
        let file = try XCTUnwrap(request.params["file"] as? [String: Any])
        XCTAssertEqual(file["upload_id"] as? String, "app-1")
        XCTAssertEqual(file["name"] as? String, "brief.md")
    }

    func testOnlyTheMissingStagedUploadErrorAsksForAFreshUpload() async throws {
        let stale = RecordingTransport { _, _ in
            #"{"id":"x","error":{"code":"invalid_params","message":"no staged upload with that id; upload the file chunks first"}}"#
        }
        do {
            try await HerdrClient(transport: stale).guestGramPost(text: "", to: "llm-opt")
            XCTFail("the post should be refused")
        } catch {
            XCTAssertTrue(GramAttachmentSender.isStaleUpload(error))
        }
        XCTAssertFalse(GramAttachmentSender.isStaleUpload(
            APIError(code: "invalid_params", message: "text too long")))
        XCTAssertFalse(GramAttachmentSender.isStaleUpload(
            APIError(code: "gram_file_error", message: "no staged upload with that id")))
    }

    /// Review P2: a refused mark is rolled back, and the rollback makes the ids unread again.
    /// Asking again right away must send nothing; the ids go out once their backoff passes,
    /// and the backoff doubles on each refusal up to its cap.
    func testRefusedReadMarksWaitOutABackoffInsteadOfLooping() {
        var marks = GuestGramReadMarks()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(marks.begin(unread: ["m1", "m2"], now: t0), ["m1", "m2"])
        XCTAssertEqual(marks.begin(unread: ["m1", "m2", "m3"], now: t0), ["m3"], "in flight is never sent twice")
        XCTAssertTrue(marks.isMarking("m1"))

        marks.failed(["m1", "m2"], now: t0)
        marks.succeeded(["m3"])
        XCTAssertFalse(marks.isMarking("m1"))
        for _ in 0..<100 {
            XCTAssertEqual(marks.begin(unread: ["m1", "m2"], now: t0), [], "the rollback must not resend at once")
        }
        XCTAssertEqual(marks.begin(unread: ["m1"], now: t0 + GuestGramReadMarks.initialBackoff - 1), [])
        let t1 = t0 + GuestGramReadMarks.initialBackoff
        XCTAssertEqual(marks.begin(unread: ["m1"], now: t1), ["m1"], "sent again once the backoff passes")

        marks.failed(["m1"], now: t1)
        XCTAssertEqual(marks.begin(unread: ["m1"], now: t1 + GuestGramReadMarks.initialBackoff), [],
                       "a second refusal waits longer")
        XCTAssertEqual(marks.begin(unread: ["m1"], now: t1 + 2 * GuestGramReadMarks.initialBackoff), ["m1"])

        var now = t1 + 2 * GuestGramReadMarks.initialBackoff
        for _ in 0..<20 {
            marks.failed(["m1"], now: now)
            now += GuestGramReadMarks.maxBackoff
            XCTAssertEqual(marks.begin(unread: ["m1"], now: now), ["m1"], "the backoff is capped")
        }
        marks.succeeded(["m1"])
        XCTAssertEqual(marks.begin(unread: ["m1"], now: now), ["m1"], "success forgets the backoff")
    }

    func testForbiddenGramSurfacesAsTheGuestError() async throws {
        let transport = RecordingTransport { _, _ in
            #"{"id":"x","error":{"code":"guest_forbidden","message":"gram is not shared with you"}}"#
        }
        do {
            _ = try await HerdrClient(transport: transport).guestGramList()
            XCTFail("expected guest_forbidden")
        } catch {
            XCTAssertEqual(GuestError.classify(error), .forbidden)
        }
    }

    // MARK: File download

    /// A 1.2 MB file arrives in three bounded pieces, each asked for at the bytes held so far.
    func testChunkedDownloadAssemblesTheFileFromOffsets() async throws {
        let file = Data((0..<1_200_000).map { UInt8($0 % 251) })
        let piece = 512 * 1024
        let transport = RecordingTransport { method, params in
            let offset = params["offset"] as? Int ?? -1
            guard method == "gram.get_file_chunk", params["id"] as? String == "m3", offset >= 0 else {
                return #"{"id":"x","error":{"code":"invalid_params","message":"bad"}}"#
            }
            let bytes = file[min(offset, file.count)..<min(offset + piece, file.count)]
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"bench.bin","mime":"application/octet-stream","size":\#(file.count),"sha256":"x","offset":\#(offset),"data_base64":"\#(Data(bytes).base64EncodedString())"}}"#
        }
        let (name, mime, data) = try await HerdrClient(transport: transport)
            .gramGetFileChunked(id: "m3", expectedSize: UInt64(file.count))

        XCTAssertEqual(name, "bench.bin")
        XCTAssertEqual(mime, "application/octet-stream")
        XCTAssertEqual(data, file)
        XCTAssertEqual(transport.requests.map { $0.params["offset"] as? Int }, [0, piece, 2 * piece])
    }

    func testChatDownloadDiscoversSizeFromTheFirstAuthorizedChunk() async throws {
        let file = Data("chat attachment".utf8)
        let transport = chunkHost(size: "\(file.count)") { offset in
            Data(file[offset..<min(offset + 4, file.count)])
        }
        let (_, _, data) = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1")
        XCTAssertEqual(data, file)
        XCTAssertEqual(transport.requests.map { $0.params["offset"] as? Int }, [0, 4, 8, 12])
    }

    func testChatDownloadRejectsSizeChangesAfterDiscovery() async throws {
        let transport = RecordingTransport { _, params in
            let offset = params["offset"] as? Int ?? 0
            let size = offset == 0 ? 8 : 9
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"a","mime":"","size":\#(size),"sha256":"x","offset":\#(offset),"data_base64":"YWJjZA=="}}"#
        }
        do {
            _ = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1")
            XCTFail("an attachment cannot change size midway through download")
        } catch GramError.invalidFileData {}
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testChatDownloadRejectsOversizedMetadataBeforeAllocatingTheFile() async throws {
        let transport = chunkHost(size: "\(UInt64.max)") { _ in Data() }
        do {
            _ = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1")
            XCTFail("unknown-size downloads still enforce the file ceiling")
        } catch GramError.invalidFileData {}
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testChunkedDownloadRejectsAHostThatStopsShort() async throws {
        let transport = RecordingTransport { _, params in
            let offset = params["offset"] as? Int ?? 0
            let bytes = offset == 0 ? Data(repeating: 1, count: 10) : Data()
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"a","mime":"","size":20,"sha256":"x","offset":\#(offset),"data_base64":"\#(bytes.base64EncodedString())"}}"#
        }
        do {
            _ = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1", expectedSize: 20)
            XCTFail("a truncated file must not open")
        } catch GramError.invalidFileData {
        }
        XCTAssertEqual(transport.requests.count, 2, "one empty piece before the end is enough to stop")
    }

    /// A host answering with a scripted piece at every offset.
    private func chunkHost(size: String, piece: @escaping (Int) -> Data) -> RecordingTransport {
        RecordingTransport { _, params in
            let offset = params["offset"] as? Int ?? 0
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"a","mime":"","size":\#(size),"sha256":"x","offset":\#(offset),"data_base64":"\#(piece(offset).base64EncodedString())"}}"#
        }
    }

    private func assertRejected(_ transport: RecordingTransport, expectedSize: UInt64, requests: Int,
                                _ why: String, line: UInt = #line) async {
        do {
            _ = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1", expectedSize: expectedSize)
            XCTFail("\(why): the file must not open", line: line)
        } catch GramError.invalidFileData {
        } catch {
            XCTFail("\(why): unexpected \(error)", line: line)
        }
        XCTAssertEqual(transport.requests.count, requests, why, line: line)
    }

    /// Review P2: the download holds the host to the listed size and the host's ceilings,
    /// before appending anything, and a huge size can't trap.
    func testChunkedDownloadEnforcesTheListedSizeAndTheCeilings() async {
        let maxFile = UInt64(HerdrClient.gramMaxFileBytes)
        let maxPiece = HerdrClient.gramMaxChunkBytes

        await assertRejected(chunkHost(size: "\(maxFile + 1)") { _ in Data([1]) },
                             expectedSize: maxFile + 1, requests: 0, "a listed size over 100 MiB isn't fetched")
        await assertRejected(chunkHost(size: "\(UInt64.max)") { _ in Data([1]) },
                             expectedSize: UInt64.max, requests: 0, "an absurd size neither traps nor fetches")
        await assertRejected(chunkHost(size: "\(UInt64.max)") { _ in Data([1]) },
                             expectedSize: 10, requests: 1, "the host's size must be the listed one")
        await assertRejected(chunkHost(size: "2000000") { _ in Data(repeating: 7, count: maxPiece + 1) },
                             expectedSize: 2_000_000, requests: 1, "a piece over 512 KiB is refused")
        await assertRejected(chunkHost(size: "10") { _ in Data(repeating: 7, count: 11) },
                             expectedSize: 10, requests: 1, "a piece can't run past the end")
        await assertRejected(chunkHost(size: "10") { offset in Data(repeating: 7, count: offset == 0 ? 6 : 5) },
                             expectedSize: 10, requests: 2, "the second piece would overflow the file")
    }

    // MARK: Push routing

    private let share = GuestAccess(
        guestID: "g1", guestName: "plotarmordev", machineLabel: "Mac Studio", ownerName: "Jerry",
        agentName: "llm-opt", agentTarget: "w1-3",
        endpoint: RelayEndpoint(relay: URL(string: "https://relay.test")!, hostID: "HOST", hostPublicKey: Data(count: 32)),
        acceptedAt: Date(timeIntervalSince1970: 0))

    func testGuestPushRoutesAGramToTheGramTabAndStatusToTheTerminal() {
        let gram: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "llm-opt", "body": "Q5 table"]],
            "herdr_guest": ["host_id": "HOST", "guest_id": "g1", "kind": "gram", "gram_id": "m3"],
        ]
        XCTAssertEqual(GuestPushRoute(userInfo: gram),
                       GuestPushRoute(hostID: "HOST", guestID: "g1", kind: .gram, gramID: "m3"))

        let status: [AnyHashable: Any] = ["herdr_guest": ["host_id": "HOST", "guest_id": "g1", "kind": "status"]]
        XCTAssertEqual(GuestPushRoute(userInfo: status)?.kind, .status)
        let future: [AnyHashable: Any] = ["herdr_guest": ["host_id": "HOST", "kind": "something-new"]]
        XCTAssertEqual(GuestPushRoute(userInfo: future)?.kind, .status, "an unknown kind opens the terminal")
    }

    func testOwnerPushesAreNotGuestPushes() {
        XCTAssertNil(GuestPushRoute(userInfo: ["gram": true, "pane_id": ""]))
        XCTAssertNil(GuestPushRoute(userInfo: ["pane_id": "w1:p1"]))
        XCTAssertNil(GuestPushRoute(userInfo: ["herdr_guest": ["guest_id": "g1", "kind": "gram"]]),
                     "without a host there is no share to open")
        XCTAssertNil(GuestPushRoute(userInfo: ["herdr_guest": ["host_id": "", "kind": "gram"]]))
    }

    /// Review P1: a guest push whose `herdr_guest` is malformed, or that also carries the
    /// owner's keys, must never open the owner's Gram or a pane.
    func testAnyGuestPushIsClassifiedAsGuestAndNeverOpensAnOwnerScreen() {
        let malformed: [[AnyHashable: Any]] = [
            ["herdr_guest": ["guest_id": "g1", "kind": "gram"], "gram": true, "pane_id": ""],
            ["herdr_guest": ["host_id": "", "kind": "status"], "pane_id": "w1:p1"],
            ["herdr_guest": ["host_id": 42], "gram": true],
            ["herdr_guest": "HOST", "pane_id": "w1:p1"],
            ["herdr_guest": NSNull(), "gram": true],
        ]
        for userInfo in malformed {
            XCTAssertEqual(PushTapTarget(userInfo: userInfo), .droppedGuest, "\(userInfo)")
        }
        let mixed: [AnyHashable: Any] = ["herdr_guest": ["host_id": "HOST", "kind": "status"],
                                         "gram": true, "pane_id": "w1:p1"]
        XCTAssertEqual(PushTapTarget(userInfo: mixed),
                       .guest(GuestPushRoute(hostID: "HOST", guestID: nil, kind: .status)),
                       "the owner's keys on a guest push are ignored")

        XCTAssertEqual(PushTapTarget(userInfo: ["gram": true, "pane_id": ""]), .ownerGram)
        XCTAssertEqual(PushTapTarget(userInfo: ["pane_id": "w1:p1"]), .ownerPane("w1:p1"))
        XCTAssertEqual(PushTapTarget(userInfo: ["pane_id": ""]), PushTapTarget.none)
    }

    func testAPushOpensOnlyTheShareItNames() {
        let other = GuestAccess(
            guestID: "g2", guestName: "plotarmordev", machineLabel: "Mac Studio", ownerName: "Jerry",
            agentName: "jarvis", agentTarget: "w1-1", endpoint: share.endpoint, acceptedAt: share.acceptedAt)
        let route = GuestPushRoute(hostID: "HOST", guestID: "g2", kind: .status)
        XCTAssertEqual(route.access(in: [share, other]), other, "two shares on one host: the guest id decides")
        XCTAssertEqual(GuestPushRoute(hostID: "HOST", guestID: nil, kind: .gram).access(in: [share]), share)
        XCTAssertNil(GuestPushRoute(hostID: "ELSEWHERE", guestID: "g1", kind: .gram).access(in: [share]),
                     "a share the phone no longer holds opens nothing")
        XCTAssertNil(GuestPushRoute(hostID: "HOST", guestID: "g9", kind: .gram).access(in: [share]))
    }
}
