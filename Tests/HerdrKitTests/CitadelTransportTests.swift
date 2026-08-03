import XCTest
import Foundation
@testable import HerdrKit

final class CitadelTransportTests: XCTestCase {

    /// AXIS: the exec command the transport builds is exactly what the
    /// server-side `herdr api-bridge <base64>` decodes back to.
    ///
    /// This is the contract BETWEEN the two repos — the transport encodes, the
    /// bridge's `decode_request_arg` decodes. If they disagree on the encoding,
    /// every request silently breaks, so it is pinned here where it is cheap to
    /// check rather than discovered against a live server.
    func testBridgeCommandBase64RoundTrips() throws {
        let request = #"{"id":"7","method":"agent.list","params":{}}"#
        let command = try CitadelTransport.bridgeCommand(for: request)

        XCTAssertTrue(command.hasPrefix("herdr api-bridge "),
                      "the command does not invoke the api-bridge subcommand")

        let encoded = String(command.dropFirst("herdr api-bridge ".count))
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) },
                                    "the argument is not valid base64")
        XCTAssertEqual(decoded, request,
                       "the base64 argument does not decode to the original request")
    }

    /// A request containing shell metacharacters must survive verbatim — the
    /// whole reason for base64 rather than shell-quoting. A prompt with quotes,
    /// backticks, `$(…)`, and newlines is exactly what would break a naive
    /// `herdr api-bridge '<json>'`.
    func testBridgeCommandSurvivesShellMetacharacters() throws {
        let nasty = #"{"id":"1","method":"agent.prompt","params":{"text":"run `id`; echo $(whoami) \"quoted\" & | ; newline\nhere"}}"#
        let command = try CitadelTransport.bridgeCommand(for: nasty)
        let encoded = String(command.dropFirst("herdr api-bridge ".count))

        // No shell metacharacter leaks into the command outside the base64 blob.
        XCTAssertFalse(encoded.contains(where: { "`$();|&\"\n".contains($0) }),
                       "a shell metacharacter survived into the command line unescaped")
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(decoded, nasty, "the request was altered in transit")
    }

    /// Base64 output is single-line — an SSH exec command line cannot contain a
    /// raw newline, and base64 standard encoding without line wrapping is what
    /// guarantees it. (Foundation's base64 does not wrap by default; this pins
    /// that assumption.)
    func testBridgeCommandIsASingleLine() throws {
        let request = String(repeating: #"{"k":"vvvvvvvvvv"},"#, count: 50)
        let command = try CitadelTransport.bridgeCommand(for: request)
        XCTAssertFalse(command.contains("\n"), "the exec command line contains a newline")
    }

    /// AXIS: a request too large for the argv transport is refused with a clear
    /// error, not allowed to fail opaquely at execve (E2BIG) on the host.
    func testOversizedRequestIsRefused() {
        // Just over the ceiling once base64-expanded.
        let huge = String(repeating: "x", count: CitadelTransport.maxCommandBytes)
        XCTAssertThrowsError(try CitadelTransport.bridgeCommand(for: huge)) { error in
            guard case TransportError.requestTooLarge(let bytes, let max) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertGreaterThan(bytes, max, "refused a request that was within the limit")
        }
        // A normal request is well under and does not throw.
        XCTAssertNoThrow(try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#))
    }
}
