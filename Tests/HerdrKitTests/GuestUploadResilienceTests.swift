import Foundation
import XCTest
@testable import HerdrKit

/// A guest's attachment goes up as one `gram.upload_chunk` relay call per chunk, each its
/// own WebSocket and Noise session, so a 6 MB photo used to be 123 connections that all had
/// to work, and one that never answered stalled the send for good.
final class GuestUploadResilienceTests: XCTestCase {
    let identity = GuestIdentity(privateKey: .init())

    private func file(_ bytes: Int) throws -> (url: URL, payload: Data) {
        let payload = Data((0..<bytes).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-upload-\(UUID().uuidString).bin")
        try payload.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, payload)
    }

    private func chunks(_ transport: RecordingTransport) -> [(uploadID: String, offset: Int, data: Data)] {
        transport.requests.compactMap { request in
            guard request.method == "gram.upload_chunk",
                  let uploadID = request.params["upload_id"] as? String,
                  let offset = request.params["offset"] as? Int,
                  let base64 = request.params["data_base64"] as? String
            else { return nil }
            return (uploadID, offset, Data(base64Encoded: base64) ?? Data())
        }
    }

    func testAChunkWhoseConnectionDroppedIsResentAtTheSameOffsetAndTheUploadCompletes() async throws {
        let chunk = HerdrClient.gramUploadChunkBytes
        let (url, payload) = try file(chunk * 3 + 11)
        var failures: [Error] = [GuestError.connectionClosed(code: 1006, reason: nil),
                                 TransportError.requestTimedOut(host: "relay.test")]
        let lock = NSLock()
        let transport = RecordingTransport { method, params in
            guard method == "gram.upload_chunk", params["offset"] as? Int == chunk * 2 else {
                return RecordingTransport.okResult
            }
            if let failure = lock.withLock({ failures.isEmpty ? nil : failures.removeFirst() }) { throw failure }
            return RecordingTransport.okResult
        }

        let uploadID = try await HerdrClient(transport: transport).gramUploadFile(fileURL: url)

        let sent = chunks(transport)
        XCTAssertEqual(sent.map(\.offset), [0, chunk, chunk * 2, chunk * 2, chunk * 2, chunk * 3])
        XCTAssertEqual(Set(sent.map(\.uploadID)), [uploadID], "a resent chunk keeps the upload's id")
        XCTAssertEqual(sent[2].data, sent[3].data, "a resent chunk carries the same bytes")
        var staged = Data()
        for piece in sent where piece.offset == staged.count { staged.append(piece.data) }
        XCTAssertEqual(staged, payload)
    }

    func testAChunkTheHostRefusedAfterADroppedConnectionIsNotResentAgain() async throws {
        let chunk = HerdrClient.gramUploadChunkBytes
        let (url, _) = try file(chunk * 3)
        var dropped = false
        let lock = NSLock()
        let transport = RecordingTransport { method, params in
            guard method == "gram.upload_chunk", params["offset"] as? Int == chunk else {
                return RecordingTransport.okResult
            }
            // The first try loses its connection; the resend reaches the host, which refuses it.
            if lock.withLock({ defer { dropped = true }; return !dropped }) {
                throw TransportError.closedBeforeResponse
            }
            return RecordingTransport.errorReply(code: "gram_file_error", message: "offset mismatch")
        }

        do {
            _ = try await HerdrClient(transport: transport).gramUploadFile(fileURL: url)
            XCTFail("expected the host's refusal")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "gram_file_error")
        }
        XCTAssertEqual(chunks(transport).map(\.offset), [0, chunk, chunk],
                       "resent once for the dropped connection, never for the host's refusal")
    }

    func testAChunkIsSentAtMostFourTimesThenTheConnectionErrorSurfaces() async throws {
        let (url, _) = try file(100)
        let transport = RecordingTransport { method, _ in
            guard method == "gram.upload_chunk" else { return RecordingTransport.okResult }
            throw GuestError.hostOffline
        }

        do {
            _ = try await HerdrClient(transport: transport).gramUploadFile(fileURL: url)
            XCTFail("expected the dropped connection to surface")
        } catch let error as GuestError {
            XCTAssertEqual(error, .hostOffline)
        }
        XCTAssertEqual(chunks(transport).map(\.offset), [0, 0, 0, 0])
    }

    func testARelayUploadSendsRelaySizedChunks() async throws {
        let host = FakeHost()
        host.serve = { _ in [Data((RecordingTransport.okResult + "\n").utf8)] }
        let connector = host.connector()
        let transport = RelayTransport(endpoint: host.endpoint, identity: identity, connector: connector)
        let relayChunk = 256 * 1024
        let (url, payload) = try file(relayChunk * 2 + 5)

        _ = try await HerdrClient(transport: transport).gramUploadFile(fileURL: url)

        let sizes = host.requests.compactMap { line -> Int? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["method"] as? String == "gram.upload_chunk",
                  let params = object["params"] as? [String: Any],
                  let base64 = params["data_base64"] as? String
            else { return nil }
            return Data(base64Encoded: base64)?.count
        }
        XCTAssertEqual(sizes, [relayChunk, relayChunk, 5], "one relay connection per 256 KiB")
        XCTAssertEqual(sizes.reduce(0, +), payload.count)
    }

    func testARelayCallWhoseHandshakeNeverAnswersTimesOutAndClosesItsSocket() async throws {
        // The socket takes message 1 and never delivers message 2 or a close.
        let connector = FakeConnector(roundTripLimit: .milliseconds(300)) { FakeRelaySocket() }
        let transport = RelayTransport(endpoint: FakeHost().endpoint, identity: identity, connector: connector)
        let started = ContinuousClock.now

        let result = await Self.outcome(within: .seconds(10)) { try await transport.roundTrip("x") }

        switch result {
        case .failure(TransportError.requestTimedOut(let host)):
            XCTAssertEqual(host, "relay.test")
        default:
            XCTFail("expected requestTimedOut, got \(String(describing: result))")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(connector.sockets.count, 1)
        XCTAssertTrue(connector.sockets.first?.closed ?? false, "the stalled socket is closed")
    }

    /// `body`'s result, or nil when it is still running after `limit`, without waiting
    /// for it to end.
    private static func outcome<T: Sendable>(
        within limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        let box = ResultBox<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            box.waiter = continuation
            Task {
                do { box.finish(.success(try await body())) } catch { box.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                box.finish(nil)
            }
        }
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var waiter: CheckedContinuation<Result<T, Error>?, Never>?

    func finish(_ result: Result<T, Error>?) {
        let waiter = lock.withLock { () -> CheckedContinuation<Result<T, Error>?, Never>? in
            guard !done else { return nil }
            done = true
            return self.waiter
        }
        waiter?.resume(returning: result)
    }
}
