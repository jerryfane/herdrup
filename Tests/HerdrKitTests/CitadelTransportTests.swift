import XCTest
import Foundation
import NIOCore
import Citadel
@testable import HerdrKit

final class CitadelTransportTests: XCTestCase {

    // MARK: - connect budget (the endless-spinner fix)

    /// AXIS: the two wordings are genuinely different, and only the tailnet one
    /// names Tailscale.
    ///
    /// The generic branch must NOT mention Tailscale: on an ordinary host the
    /// cause is unknown, and guessing sends the user to fix something that is not
    /// broken. Asserting the absence is the half that keeps that honest.
    func testTimeoutMessageNamesTailscaleOnlyWhenTheHostIsOnATailnet() {
        let tailnet = TransportError.connectTimedOut(host: "box.ts.net", onTailnet: true).description
        XCTAssertTrue(tailnet.contains("Tailscale"), "the remedy must be named: \(tailnet)")
        XCTAssertTrue(tailnet.contains("box.ts.net"), "the host must be named: \(tailnet)")

        let generic = TransportError.connectTimedOut(host: "nas.local", onTailnet: false).description
        XCTAssertFalse(generic.contains("Tailscale"),
                       "an ordinary host must not be blamed on Tailscale: \(generic)")
        XCTAssertTrue(generic.contains("nas.local"), "the host must be named: \(generic)")
    }

    /// AXIS: the budget is REAL — a connect to an address that swallows packets
    /// fails within it instead of hanging.
    ///
    /// This is the actual regression. Before the budget there was no error at all:
    /// the OS sat on the socket for ~75s, which the user experienced as an endless
    /// spinner with nothing to act on.
    ///
    /// Gated on an INDEPENDENT probe (a raw socket, not the transport) that the
    /// address really does black-hole here — matching the LiveEnvironment
    /// convention. Where it fails fast instead, there is no hang to bound and the
    /// test would be asserting something the environment cannot produce.
    func testConnectFailsWithinTheBudgetAgainstABlackHoleAddress() async throws {
        let host = "100.64.0.1"   // CGNAT, and a tailnet address: exercises both halves
        try XCTSkipUnless(Self.blackHoles(host: host),
                          "\(host) does not black-hole in this environment; nothing to bound")

        let creds = SSHCredentials(
            host: host, port: 22, username: "nobody", password: "nobody", remoteSocketPath: "")
        let transport = CitadelTransport(
            credentials: creds,
            hostKeyPolicy: PinningHostKeyPolicy(),
            connectTimeoutNanoseconds: 300_000_000   // 0.3s, so the test is fast
        )

        let started = Date()
        do {
            _ = try await transport.roundTrip("{\"id\":\"x\",\"method\":\"server.ping\",\"params\":{}}")
            XCTFail("a black-hole address must not connect")
        } catch let error as TransportError {
            guard case .connectTimedOut(let h, let onTailnet) = error else {
                return XCTFail("expected connectTimedOut, got \(error)")
            }
            XCTAssertEqual(h, host)
            XCTAssertTrue(onTailnet, "100.64.0.1 is inside 100.64.0.0/10")
        }
        // The bound is the point: without the budget this is ~75 seconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the connect budget did not bound the wait")
    }

    /// Independent of the transport: does a raw TCP connect to this address hang?
    private static func blackHoles(host: String) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Connected, or refused/unreachable outright -> not a black hole.
        // Timed out (EINPROGRESS/EAGAIN/ETIMEDOUT) -> packets are being swallowed.
        return rc != 0 && (errno == ETIMEDOUT || errno == EINPROGRESS || errno == EAGAIN)
    }

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

    // MARK: - parseBridgeOutput reachability (the do/catch WIRING, not the pure classifier)

    /// A fake non-zero exit the test can inject — `SSHClient.CommandFailed`'s init is
    /// internal to Citadel, so `parseBridgeOutput` catches the `RemoteExitError` protocol
    /// (which `CommandFailed` conforms to) and this stands in for it here.
    private struct FakeExit: RemoteExitError { let remoteExitCode: Int }

    /// Builds the exec output stream a test wants: some stdout/stderr, then either a
    /// clean finish or a `throwing:` finish (what Citadel does on non-zero exit).
    private func bridgeStream(
        stdout: [String] = [], stderr: [String] = [], finishThrowing: Error? = nil
    ) -> AsyncThrowingStream<ExecCommandOutput, Error> {
        AsyncThrowingStream { continuation in
            for s in stdout { continuation.yield(.stdout(ByteBuffer(string: s))) }
            for s in stderr { continuation.yield(.stderr(ByteBuffer(string: s))) }
            if let finishThrowing { continuation.finish(throwing: finishThrowing) }
            else { continuation.finish() }
        }
    }

    /// THE REACHABILITY TEST. A stream that finishes `throwing:` a non-zero exit (as
    /// Citadel does) must be classified, not rethrown raw. Deleting or mis-scoping the
    /// do/catch in `parseBridgeOutput` reintroduces the raw "command failed, exit code 2"
    /// bug — this fails then, where the pure-classifier tests stay green.
    func testParseBridgeOutputExitTwoRethrowsIncompatible() async {
        let stream = bridgeStream(
            stderr: ["error: unrecognized subcommand 'api-bridge'\n"],
            finishThrowing: FakeExit(remoteExitCode: 2))
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .herdrIncompatible(let host) = error else {
                return XCTFail("expected .herdrIncompatible, got \(error)")
            }
            XCTAssertEqual(host, "box.example")
        } catch {
            XCTFail("raw \(error) escaped — the do/catch is gone or mis-scoped")
        }
    }

    /// The sentinel path through the SAME throwing-stream wiring: absent herdr exits 127
    /// but its sentinel wins, and it must be classified, not rethrown raw.
    func testParseBridgeOutputSentinelRethrowsNotInstalled() async {
        let stream = bridgeStream(
            stderr: ["\(CitadelTransport.herdrNotInstalledSentinel)\n"],
            finishThrowing: FakeExit(remoteExitCode: 127))
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .herdrNotInstalled = error else {
                return XCTFail("expected .herdrNotInstalled, got \(error)")
            }
        } catch {
            XCTFail("raw \(error) escaped — the do/catch is gone or mis-scoped")
        }
    }

    /// A reply that arrived before a non-zero exit is RETURNED, not overridden by the
    /// exit classification — guards the `lines.first` early-return / `hasRemainder` order.
    func testParseBridgeOutputReturnsReplyBeforeNonZeroExit() async throws {
        let stream = bridgeStream(
            stdout: ["{\"ok\":true}\n"],
            finishThrowing: FakeExit(remoteExitCode: 1))
        let reply = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
        XCTAssertEqual(reply, "{\"ok\":true}")
    }

    /// A clean exit-0 close with no reply surfaces `.closedBeforeResponse`, not a hang.
    func testParseBridgeOutputCleanCloseWithoutReply() async {
        let stream = bridgeStream()
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .closedBeforeResponse = error else {
                return XCTFail("expected .closedBeforeResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
