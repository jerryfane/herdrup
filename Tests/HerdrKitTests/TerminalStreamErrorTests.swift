import XCTest
@testable import HerdrKit

/// A server can end a live `pane.stream` with an error line AFTER frames; a guest
/// stream closes this way with `guest_paused` or `guest_revoked`.
final class TerminalStreamErrorTests: XCTestCase {
    private struct ClosingTransport: HerdrTransport {
        let closingLine: String

        func roundTrip(_ requestLine: String) async throws -> String {
            #"{"id":"x","result":{}}"#
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            let closingLine = closingLine
            return AsyncThrowingStream { continuation in
                continuation.yield(
                    #"{"id":"x","result":{"type":"stream_started","pane_id":"w1-3","epoch":1,"cols":48,"rows":30,"base_seq":0,"resync":true}}"#)
                continuation.yield(
                    #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":1,"cols":48,"rows":30,"data_b64":"aGk="}"#)
                continuation.yield(closingLine)
                continuation.finish()
            }
        }
    }

    func testErrorLineAfterFramesEndsTheStreamWithItsAPIError() async {
        let client = HerdrClient(transport: ClosingTransport(
            closingLine: #"{"id":"x","error":{"code":"guest_paused","message":"llm-opt isn't running"}}"#))
        var frames = 0
        do {
            for try await event in client.streamTerminal(pane: "w1-3") {
                if case .frame = event { frames += 1 }
            }
            XCTFail("the stream finished cleanly instead of throwing the server's error")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "guest_paused")
            XCTAssertEqual(GuestError.classify(error), .paused)
        } catch {
            XCTFail("expected APIError(guest_paused), got \(error)")
        }
        XCTAssertEqual(frames, 1, "the frame before the error line must still be delivered")
    }
}
