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
        let fd = socket(AF_INET, sockStream, 0)
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

    /// herdrup#276. sshd runs the exec command through the ACCOUNT's login shell,
    /// so the string must mean the same thing to fish, csh and tcsh as to sh: words
    /// separated by spaces, each a bare word from a small safe alphabet or a
    /// single-quoted string holding no character some shell does not take literally
    /// inside single quotes, none as long as Debian csh's ~8 KiB word limit. Parsing
    /// it by exactly that grammar must recover `/bin/sh -c <script> sh <base64
    /// pieces>` with the request intact. The real shells run it in
    /// `LoginShellCommandTests`.
    func testBridgeCommandIsOneQuotedSimpleCommandForAnyLoginShell() throws {
        // Every character the grammar forbids, and a base64 argument well past csh's
        // word limit, long enough that line-wrapping base64 would add a newline.
        let request = String(repeating: #"{"text":"it's \"q\" \\ !x $(id) `id`\n"},"#, count: 400)
        let command = try CitadelTransport.bridgeCommand(for: request)

        let words = try Self.wordsEveryShellAgreesOn(command)
        guard words.count >= 5 else { return XCTFail("unexpected command shape: \(words)") }
        XCTAssertEqual(Array(words.prefix(2)), ["/bin/sh", "-c"], "the script is not handed to /bin/sh")
        XCTAssertEqual(words[3], "sh", "the script's $0 is missing, so the payload shifts into it")
        let longest = try XCTUnwrap(words.map(\.utf8.count).max())
        XCTAssertLessThan(longest, 8_000, "a \(longest)-byte word; Debian csh fails with Word too long")
        let decoded = try XCTUnwrap(Data(base64Encoded: words[4...].joined()).map { String(decoding: $0, as: UTF8.self) },
                                    "the request pieces do not rejoin into valid base64")
        XCTAssertEqual(decoded, request, "the request was altered in transit")
    }

    private struct NotPortable: Error, CustomStringConvertible { let description: String }

    /// Splits `command` into words the way every login shell agrees on, or throws at
    /// the first character where fish, csh, tcsh, bash, zsh or dash could differ.
    private static func wordsEveryShellAgreesOn(_ command: String) throws -> [String] {
        let bare = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_.")
        // Inside single quotes fish still unescapes `\\` and `\'`, csh and tcsh
        // reject a newline and history-expand `!`.
        let unsafeInQuotes = Set("\\!\n\r")
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoted = false
        for character in command {
            if quoted {
                if character == "'" {
                    quoted = false
                } else if unsafeInQuotes.contains(character) {
                    throw NotPortable(description: "\(character.debugDescription) inside single quotes in word \(words.count + 1)")
                } else {
                    word.append(character)
                }
            } else if character == "'" {
                quoted = true
                inWord = true
            } else if character == " " {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else if bare.contains(character) {
                word.append(character)
                inWord = true
            } else {
                throw NotPortable(description: "unquoted \(character.debugDescription) in word \(words.count + 1)")
            }
        }
        if quoted { throw NotPortable(description: "unterminated single quote") }
        if inWord { words.append(word) }
        return words
    }

    /// AXIS: the limit bounds the command line ACTUALLY sent, wrapper included — it is
    /// one argv element to the account's shell, where E2BIG fails with no bridge to
    /// report it. Across the boundary every accepted command fits, and a refusal
    /// reports the true command size. Measuring only the base64 argument accepts
    /// requests whose wrapped command exceeds the limit, which fails here.
    func testRequestSizeLimitCountsTheWholeCommand() throws {
        let limit = CitadelTransport.maxCommandBytes
        var accepted = 0
        var refused = 0
        // base64 grows 4 bytes per 3 input bytes, so the base64 alone reaches the limit
        // at the top of this range; the wrapper moves the real boundary inside it. Each
        // step grows the command by 16 bytes, finer than the wrapper's size.
        for size in stride(from: limit / 4 * 3 - 480, through: limit / 4 * 3, by: 12) {
            let request = String(repeating: "x", count: size)
            do {
                let command = try CitadelTransport.bridgeCommand(for: request)
                XCTAssertLessThanOrEqual(command.utf8.count, limit, "accepted a \(size)-byte request over the limit")
                accepted += 1
            } catch TransportError.requestTooLarge(let bytes, let max) {
                XCTAssertEqual(max, limit)
                XCTAssertGreaterThan(bytes, max, "refused a \(size)-byte request within the limit")
                refused += 1
            }
        }
        XCTAssertGreaterThan(accepted, 0, "the boundary is below the probed range")
        XCTAssertGreaterThan(refused, 0, "the boundary is above the probed range")
    }

    // MARK: - "herdr not installed" detection

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

    /// herdrup#276: a login shell that cannot parse the command exits 127 with its
    /// own diagnostic, before herdr runs. That is reported as the shell failing to
    /// start herdr, not as an api-bridge that ran and "produced no reply".
    func testClassifyExit127WithoutSentinelBlamesTheShell() {
        let stderr = "fish: Unsupported use of '='. In fish, please use 'set HERDR $(command -v herdr)'.\n"
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 127, host: "box.example")
        guard case TransportError.remoteShellFailed(let host, let diagnostic) = error else {
            return XCTFail("expected .remoteShellFailed, got \(error)")
        }
        XCTAssertEqual(host, "box.example", "the host was not carried through")
        XCTAssertEqual(diagnostic, stderr, "the shell's diagnostic was not preserved")
    }

    /// A specific rejection of the api-bridge subcommand, not exit 2 alone,
    /// identifies an old or incompatible installed Herdr.
    func testClassifyBridgeFailureExitTwoIsIncompatible() {
        let stderr = "error: unrecognized subcommand 'api-bridge'\n"
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 2, host: "box.example")
        guard case TransportError.herdrIncompatible(let host) = error else {
            return XCTFail("expected .herdrIncompatible, got \(error)")
        }
        XCTAssertEqual(host, "box.example", "the host was not carried through")
    }

    func testUnrelatedExitTwoPreservesDiagnostic() {
        let stderr = "error: invalid request argument\n"
        let error = CitadelTransport.classifyBridgeFailure(
            stderr: stderr, exitCode: 2, host: "box.example")
        guard case TransportError.bridgeFailed(let diagnostic) = error else {
            return XCTFail("an unrelated usage error was labelled incompatible: \(error)")
        }
        XCTAssertEqual(diagnostic, stderr)
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

    /// An unrelated stderr remains generic rather than asking for a reinstall.
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

    /// A compatible bridge writes a structured error on stdout and exits
    /// successfully when its local API socket is absent or refuses connections.
    func testOfflineDaemonFromBridgeReplyIsTyped() async {
        for (message, trailingNewline) in [
            ("No such file or directory (os error 2)", true),
            ("Connection refused (os error 111)", false)
        ] {
            let reply = #"{"id":"req-1","error":{"code":"transport_error","message":"api-bridge: \#(message)"}}"#
            let stream = bridgeStream(stdout: [reply + (trailingNewline ? "\n" : "")])
            do {
                _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
                XCTFail("expected an unavailable daemon for \(message)")
            } catch let error as TransportError {
                guard case .daemonUnavailable(let host) = error else {
                    return XCTFail("expected .daemonUnavailable, got \(error)")
                }
                XCTAssertEqual(host, "box.example")
                XCTAssertTrue(error.description.contains("not responding"))
                XCTAssertFalse(error.description.contains("stopped"))
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testUnrelatedTransportErrorIsNotMislabelledOffline() async throws {
        let reply = #"{"id":"req-1","error":{"code":"transport_error","message":"api-bridge: Broken pipe (os error 32)"}}"#
        let stream = bridgeStream(stdout: [reply + "\n"])
        let result = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
        XCTAssertEqual(result, reply)
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
