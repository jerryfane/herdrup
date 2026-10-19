import XCTest
import Foundation
@testable import HerdrKit

/// `probeFork()` decides whether to show the "you're not on the Herdr fork" notice.
/// The whole point is that a real fork user is NEVER falsely told to install the
/// fork — so only a definitive "unknown method" is `notFork`; everything else is
/// `indeterminate` (assume fork, stay quiet). Verified on Linux.
final class ForkProbeTests: XCTestCase {

    private struct SocketClosed: Error {}

    private func result(_ raw: String) -> String { #"{"id":"x","result":\#(raw)}"# }

    func testSuccessfulGramListIsFork() async {
        let client = HerdrClient(transport: RecordingTransport(reply: result(#"{"messages":[]}"#)))
        let r = await client.probeFork()
        XCTAssertEqual(r, .isFork)
    }

    func testUnknownVariantIsNotFork() async {
        // Exactly what the base daemon returns: it can't deserialize the unknown
        // `gram.list` method variant.
        let line = RecordingTransport.errorReply(code: "invalid_request",
                                                 message: "invalid request: unknown variant `gram.list`, expected one of ...")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .notFork)
    }

    func testGramUnavailableIsFork() async {
        // The fork HAS gram.list; the shared server is simply down. Must NOT be read
        // as "not the fork".
        let line = RecordingTransport.errorReply(code: "gram_unavailable", message: "not connected to the shared Herdr server")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .isFork)
    }

    func testUnknownVariantNotNamingTheMethodIsIndeterminate() async {
        // "unknown variant" that does NOT name gram.list (e.g. a future enum-typed
        // PARAM an older fork rejects) must degrade to indeterminate, never a false
        // notFork on a real fork user.
        let line = RecordingTransport.errorReply(code: "invalid_request",
                                                 message: "invalid request: unknown variant `weekly`, expected one of `all`, `unread`")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testMixedCaseUnknownVariantIsNotFork() async {
        // The match is case-insensitive (.lowercased()), so a reworded/mixed-case
        // phrasing still classifies correctly.
        let line = RecordingTransport.errorReply(code: "invalid_request",
                                                 message: "Invalid Request: Unknown Variant `gram.list`, expected one of ...")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .notFork)
    }

    func testUndecodableSuccessLineIsIndeterminate() async {
        // A 200-shaped line carrying no gram list must NOT read as a fork.
        //
        // The mechanism CHANGED with conditional fetch: `GramListResult.messages` is
        // now optional (an unchanged answer omits it), so this line no longer fails to
        // decode — it decodes with every field nil. The verdict comes from
        // `probeFork`'s `guard ... .messages != nil`, NOT from a DecodingError reaching
        // the trailing catch. Deleting that guard makes this test fail with `.isFork`,
        // which is the point: an unconditional `gram.list` on the fork always carries
        // messages, so their absence means the answer was not a gram list at all.
        let client = HerdrClient(transport: RecordingTransport(reply: #"{"id":"x","result":{"wrong":true}}"#))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testOtherInvalidRequestIsIndeterminate() async {
        // invalid_request WITHOUT "unknown variant" (e.g. a future required param) must
        // NOT flag a fork user — fail safe to indeterminate.
        let line = RecordingTransport.errorReply(code: "invalid_request", message: "invalid request: missing field `foo`")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testUnrelatedApiErrorIsIndeterminate() async {
        let line = RecordingTransport.errorReply(code: "internal", message: "boom")
        let client = HerdrClient(transport: RecordingTransport(reply: line))
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }

    func testTransportErrorIsIndeterminate() async {
        // A dropped connection must never be read as "not the fork".
        let client = HerdrClient(transport: RecordingTransport { _, _ in throw SocketClosed() })
        let r = await client.probeFork()
        XCTAssertEqual(r, .indeterminate)
    }
}
