import XCTest
import Foundation
import NIOCore
@testable import HerdrKit

final class CitadelTransportTests: XCTestCase {

    // MARK: - LineAccumulator (byte-accurate line decoding)

    /// AXIS: a multi-byte UTF-8 scalar split across two stdout chunks is
    /// reconstructed intact. Decoding each chunk independently with
    /// `String(buffer:)` replaced the split scalar with U+FFFD — the HIGH bug
    /// the review caught. SSH splits large stdout at arbitrary byte boundaries,
    /// so this is the real wire condition, not a contrived one.
    func testLineAccumulatorReconstructsMultibyteScalarSplitAcrossChunks() {
        let rocket = Array("🚀".utf8)   // F0 9F 9A 80
        XCTAssertEqual(rocket.count, 4, "precondition: the scalar is 4 bytes")
        var acc = LineAccumulator()

        // Chunk boundary falls INSIDE the scalar: first two bytes, then the rest.
        XCTAssertTrue(acc.append(ByteBuffer(bytes: rocket[0..<2])).isEmpty,
                      "no newline yet, so no completed line")
        let completed = acc.append(ByteBuffer(bytes: Array(rocket[2..<4]) + [UInt8(ascii: "\n")]))
        XCTAssertEqual(completed, ["🚀"],
                       "the scalar split across chunks was corrupted, not reconstructed")
    }

    /// Splits on every newline and holds the unterminated tail as a remainder.
    func testLineAccumulatorSplitsLinesAndKeepsRemainder() {
        var acc = LineAccumulator()
        let lines = acc.append(ByteBuffer(string: "alpha\nbeta\ngamma"))
        XCTAssertEqual(lines, ["alpha", "beta"], "did not split on both newlines")
        XCTAssertTrue(acc.hasRemainder, "the tail after the last newline was dropped")
        XCTAssertEqual(acc.flush(), "gamma", "the remainder was not the unterminated tail")
        XCTAssertFalse(acc.hasRemainder, "flush did not clear the remainder")
    }


    /// AXIS: the base64 argument the transport builds is exactly what the
    /// server-side `herdr api-bridge <base64>` decodes back to.
    ///
    /// This is the contract BETWEEN the two repos — the transport encodes, the
    /// bridge's `decode_request_arg` decodes. If they disagree on the encoding,
    /// every request silently breaks, so it is pinned here where it is cheap to
    /// check rather than discovered against a live server.
    func testEncodedRequestBase64RoundTrips() throws {
        let request = #"{"id":"7","method":"agent.list","params":{}}"#
        let encoded = CitadelTransport.encodedRequest(for: request)

        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) },
                                    "the argument is not valid base64")
        XCTAssertEqual(decoded, request,
                       "the base64 argument does not decode to the original request")
    }

    /// A request containing shell metacharacters must survive verbatim — the
    /// whole reason for base64 rather than shell-quoting. A prompt with quotes,
    /// backticks, `$(…)`, and newlines is exactly what would break a naive
    /// `herdr api-bridge '<json>'`.
    func testEncodedRequestSurvivesShellMetacharacters() throws {
        let nasty = #"{"id":"1","method":"agent.prompt","params":{"text":"run `id`; echo $(whoami) \"quoted\" & | ; newline\nhere"}}"#
        let encoded = CitadelTransport.encodedRequest(for: nasty)

        // No shell metacharacter leaks into the base64 blob.
        XCTAssertFalse(encoded.contains(where: { "`$();|&\"\n".contains($0) }),
                       "a shell metacharacter survived into the base64 argument")
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(decoded, nasty, "the request was altered in transit")
    }

    /// AXIS: the command resolves herdr's remote path rather than assuming it is
    /// on the non-interactive SSH `PATH`. A live round-trip proved a bare
    /// `herdr api-bridge` fails "command not found" because the default install
    /// (`~/.local/bin`) is not on a non-login shell's PATH. The command must
    /// therefore fall back to `$HOME/.local/bin/herdr` — this pins that so the
    /// resolution cannot be silently dropped back to a bare `herdr`.
    func testBridgeCommandResolvesHerdrPath() throws {
        let command = try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#)

        XCTAssertTrue(command.contains("command -v herdr"),
                      "the command does not consult PATH for herdr")
        XCTAssertTrue(command.contains("$HOME/.local/bin/herdr"),
                      "the command does not fall back to the ~/.local/bin install location")
        XCTAssertTrue(command.contains(" api-bridge "),
                      "the command does not invoke the api-bridge subcommand")
    }

    /// The full exec command line is single-line — an SSH exec command line
    /// cannot contain a raw newline, and base64 standard encoding without line
    /// wrapping is what guarantees the argument stays on one line. (Foundation's
    /// base64 does not wrap by default; this pins that assumption.)
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

    // MARK: - "herdr not installed" detection

    /// AXIS: the exec wrapper guards that the resolved herdr path is executable and,
    /// when it is not, emits the sentinel and exits BEFORE `exec`. This is what lets
    /// the client tell "herdr is not installed" apart from every other bridge failure
    /// and show install guidance instead of a raw stderr line. Pins the guard so it
    /// cannot be silently dropped back to an unconditional `exec`.
    func testBridgeCommandGuardsHerdrExecutableWithSentinel() throws {
        let command = try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#)

        XCTAssertTrue(command.contains(#"[ -x "$HERDR" ]"#),
                      "the command does not guard that the resolved herdr path is executable")
        XCTAssertTrue(command.contains(CitadelTransport.herdrNotInstalledSentinel),
                      "the command does not emit the not-installed sentinel")
        // The guard must run BEFORE exec, otherwise exec of a missing file wins and
        // the sentinel is never printed.
        let guardIndex = try XCTUnwrap(command.range(of: #"[ -x "$HERDR" ]"#)?.lowerBound)
        let execIndex = try XCTUnwrap(command.range(of: #"exec "$HERDR""#)?.lowerBound)
        XCTAssertLessThan(guardIndex, execIndex, "the executable guard runs after exec, so it never fires")
        // The installed path is unchanged: it still runs api-bridge.
        XCTAssertTrue(command.contains(" api-bridge "),
                      "the command no longer invokes the api-bridge subcommand for the installed path")
    }

    /// A stderr carrying the sentinel classifies as `.herdrNotInstalled(host:)`,
    /// carrying the host through for the client's guidance copy.
    func testClassifyBridgeFailureDetectsMissingHerdr() {
        let stderr = "bash: line 1: \(CitadelTransport.herdrNotInstalledSentinel)\n"
        // The not-installed wrapper exits 127, but the sentinel wins regardless of code.
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 127, host: "box.example")
        guard case TransportError.herdrNotInstalled(let host) = error else {
            return XCTFail("expected .herdrNotInstalled, got \(error)")
        }
        XCTAssertEqual(host, "box.example", "the host was not carried through")
    }

    /// Exit code 2 (clap's usage error for an unknown subcommand) with no sentinel
    /// means herdr is present but doesn't understand `api-bridge` — too old, or not
    /// the fork. It classifies as `.herdrIncompatible(host:)` so the client can say
    /// "update / install the fork" instead of showing "command failed, exit code 2".
    func testClassifyBridgeFailureExitTwoIsIncompatible() {
        let stderr = "error: unrecognized subcommand 'api-bridge'\n"
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 2, host: "box.example")
        guard case TransportError.herdrIncompatible(let host) = error else {
            return XCTFail("expected .herdrIncompatible, got \(error)")
        }
        XCTAssertEqual(host, "box.example", "the host was not carried through")
    }

    /// The sentinel outranks the exit code: an absent herdr must read as
    /// not-installed even though its wrapper also exits non-zero.
    func testClassifyBridgeFailureSentinelBeatsExitCode() {
        let stderr = "\(CitadelTransport.herdrNotInstalledSentinel)\n"
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 2, host: "box.example")
        guard case TransportError.herdrNotInstalled = error else {
            return XCTFail("expected .herdrNotInstalled, got \(error)")
        }
    }

    /// Any OTHER stderr stays a generic `.bridgeFailed` — the sentinel is the only
    /// signal that promotes it, so an unrelated failure is never mislabelled as
    /// "herdr not installed" (which would wrongly tell the user to reinstall).
    func testClassifyBridgeFailurePassesThroughUnrelatedStderr() {
        let stderr = "api-bridge: permission denied while opening the control socket\n"
        // A non-2, non-sentinel failure (e.g. exit 1) stays a generic bridge failure.
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 1, host: "box.example")
        guard case TransportError.bridgeFailed(let passed) = error else {
            return XCTFail("expected .bridgeFailed, got \(error)")
        }
        XCTAssertEqual(passed, stderr, "the original stderr was not preserved")
    }

    /// The description names the host so the surfaced error is legible on its own.
    func testHerdrNotInstalledDescriptionNamesHost() {
        let error = TransportError.herdrNotInstalled(host: "box.example")
        XCTAssertEqual(error.description, "herdr is not installed on box.example")
    }
}
