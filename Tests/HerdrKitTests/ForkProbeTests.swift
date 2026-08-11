import XCTest
import Foundation
@testable import HerdrKit

/// `probeFork()` decides whether to show the "you're not on the Herdr fork" notice.
/// The whole point is that a real fork user is NEVER falsely told to install the
/// fork — so only a definitive "unknown method" is `notFork`; everything else is
/// `indeterminate` (assume fork, stay quiet). Verified on Linux.
final class ForkProbeTests: XCTestCase {

    /// Returns one canned line for any request, or throws a canned transport error.
    private struct CannedTransport: HerdrTransport {
        let line: String?
        let thrown: Error?
        init(line: String) { self.line = line; self.thrown = nil }
        init(thrown: Error) { self.line = nil; self.thrown = thrown }
        func roundTrip(_ requestLine: String) async throws -> String {
            if let thrown { throw thrown }
            return line!
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct SocketClosed: Error {}

    private func result(_ raw: String) -> String { #"{"id":"x","result":\#(raw)}"# }
    private func error(code: String, message: String) -> String {
        #"{"id":"x","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    func testSuccessfulGramListIsFork() async {
        let client = HerdrClient(transport: CannedTransport(line: result(#"{"messages":[]}"#)))
        let r = await client.probeFork()
        XCTAssertEqual(r, .isFork)
    }

    func testUnknownVariantIsNotFork() async {
        // Exactly what the base daemon returns: it can't deserialize the unknown
        // `gram.list` method variant.
        let line = error(code: "invalid_request",
                         message: "invalid request: unknown variant `gram.list`, expected one of ...")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .notFork)
    }

    func testGramUnavailableIsFork() async {
        // The fork HAS gram.list; the shared server is simply down. Must NOT be read
        // as "not the fork".
        let line = error(code: "gram_unavailable", message: "not connected to the shared Herdr server")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .isFork)
    }

    func testUnknownVariantNotNamingTheMethodIsIndeterminate() async {
        // "unknown variant" that does NOT name gram.list (e.g. a future enum-typed
        // PARAM an older fork rejects) must degrade to indeterminate, never a false
        // notFork on a real fork user.
        let line = error(code: "invalid_request",
                         message: "invalid request: unknown variant `weekly`, expected one of `all`, `unread`")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testMixedCaseUnknownVariantIsNotFork() async {
        // The match is case-insensitive (.lowercased()), so a reworded/mixed-case
        // phrasing still classifies correctly.
        let line = error(code: "invalid_request",
                         message: "Invalid Request: Unknown Variant `gram.list`, expected one of ...")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .notFork)
    }

    func testUndecodableSuccessLineIsIndeterminate() async {
        // A 200-shaped line that doesn't decode to the result type throws a
        // DecodingError (not an APIError) → the trailing catch → indeterminate.
        let client = HerdrClient(transport: CannedTransport(line: #"{"id":"x","result":{"wrong":true}}"#))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testOtherInvalidRequestIsIndeterminate() async {
        // invalid_request WITHOUT "unknown variant" (e.g. a future required param) must
        // NOT flag a fork user — fail safe to indeterminate.
        let line = error(code: "invalid_request", message: "invalid request: missing field `foo`")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testUnrelatedApiErrorIsIndeterminate() async {
        let line = error(code: "internal", message: "boom")
        let client = HerdrClient(transport: CannedTransport(line: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testTransportErrorIsIndeterminate() async {
        // A dropped connection must never be read as "not the fork".
        let client = HerdrClient(transport: CannedTransport(thrown: SocketClosed()))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }
}
