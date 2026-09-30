import Foundation
import XCTest
@testable import HerdrKit

/// A guest's Gram and push for the shared agent (herdrup#338): what the host advertises in
/// the hello, how the guest's Gram decodes and downloads, and where a tapped push goes.
final class GuestGramTests: XCTestCase {

    /// Answers each request by method, and keeps every request line.
    private final class ScriptedTransport: HerdrTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        let answer: (_ method: String, _ params: [String: Any]) -> String

        init(answer: @escaping (_ method: String, _ params: [String: Any]) -> String) {
            self.answer = answer
        }

        var requests: [(method: String, params: [String: Any])] {
            lock.withLock { lines }.compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let method = object["method"] as? String else { return nil }
                return (method, object["params"] as? [String: Any] ?? [:])
            }
        }

        func roundTrip(_ requestLine: String) async throws -> String {
            lock.withLock { lines.append(requestLine) }
            let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
            return answer(object?["method"] as? String ?? "", object?["params"] as? [String: Any] ?? [:])
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

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
        let transport = RelayTransport(endpoint: host.endpoint, identity: GuestIdentity(privateKey: .init()),
                                       connector: host.connector(), onFeatures: { log.append($0) })

        _ = try await transport.roundTrip("a")
        host.reply = ["ok": true, "features": ["gram": true, "push": true]]
        _ = try await transport.roundTrip("b")
        for try await _ in transport.stream("c") {}

        XCTAssertEqual(log.all, [.none, GuestFeatures(gram: true, push: true), GuestFeatures(gram: true, push: true)])
    }

    // MARK: Gram list

    func testGuestGramListDecodesTheHostsProjection() async throws {
        let transport = ScriptedTransport { _, _ in #"""
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

    func testGuestGramListOmitsUnsetParamsAndClampsTheLimit() async throws {
        let transport = ScriptedTransport { _, _ in #"{"id":"x","result":{"type":"guest_gram_list","messages":[]}}"# }
        let client = HerdrClient(transport: transport)
        let page = try await client.guestGramList()
        XCTAssertEqual(page, GuestGramPage(messages: [], hasMore: false), "no has_more means everything")
        XCTAssertTrue(try XCTUnwrap(transport.requests.last).params.isEmpty)
        _ = try await client.guestGramList(limit: 10_000)
        XCTAssertEqual(try XCTUnwrap(transport.requests.last).params["limit"] as? Int, 500)
    }

    func testMarkReadSendsTheIDs() async throws {
        let transport = ScriptedTransport { _, _ in #"{"id":"x","result":{"type":"ok"}}"# }
        try await HerdrClient(transport: transport).guestGramMarkRead(ids: ["m3", "m1"])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.method, "gram.mark_read")
        XCTAssertEqual(request.params["ids"] as? [String], ["m3", "m1"])
    }

    func testForbiddenGramSurfacesAsTheGuestError() async throws {
        let transport = ScriptedTransport { _, _ in
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
        let transport = ScriptedTransport { method, params in
            let offset = params["offset"] as? Int ?? -1
            guard method == "gram.get_file_chunk", params["id"] as? String == "m3", offset >= 0 else {
                return #"{"id":"x","error":{"code":"invalid_params","message":"bad"}}"#
            }
            let bytes = file[min(offset, file.count)..<min(offset + piece, file.count)]
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"bench.bin","mime":"application/octet-stream","size":\#(file.count),"sha256":"x","offset":\#(offset),"data_base64":"\#(Data(bytes).base64EncodedString())"}}"#
        }
        let (name, mime, data) = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m3")

        XCTAssertEqual(name, "bench.bin")
        XCTAssertEqual(mime, "application/octet-stream")
        XCTAssertEqual(data, file)
        XCTAssertEqual(transport.requests.map { $0.params["offset"] as? Int }, [0, piece, 2 * piece])
    }

    func testChunkedDownloadRejectsAHostThatStopsShort() async throws {
        let transport = ScriptedTransport { _, params in
            let offset = params["offset"] as? Int ?? 0
            let bytes = offset == 0 ? Data(repeating: 1, count: 10) : Data()
            return #"{"id":"x","result":{"type":"gram_file_chunk","name":"a","mime":"","size":20,"sha256":"x","offset":\#(offset),"data_base64":"\#(bytes.base64EncodedString())"}}"#
        }
        do {
            _ = try await HerdrClient(transport: transport).gramGetFileChunked(id: "m1")
            XCTFail("a truncated file must not open")
        } catch GramError.invalidFileData {
        }
        XCTAssertEqual(transport.requests.count, 2, "one empty piece before the end is enough to stop")
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
