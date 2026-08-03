import Foundation
import Citadel
import Crypto
import NIOCore

/// The pure-Swift transport: swift-nio-ssh + Citadel, replacing libssh2.
///
/// Where `SSHTransport` needed a bounded thread pool, a cancellation handle that
/// publishes the socket, and `DescriptorAudit` — all because libssh2 blocks and
/// owns raw fds — this needs none of it. Citadel is async/await-native:
/// cancellation is `channel.close()` on an event loop, and there are no fds to
/// audit. That deletion is the whole point of route B.
///
/// It reaches herdr's JSON API not by forwarding a unix socket (libssh2's
/// `direct-streamlocal`, which nio-ssh does not implement) but by exec'ing the
/// `herdr api-bridge` subcommand over one SSH channel per call and reading its
/// stdout. The request rides as a base64 argument — Citadel's
/// `executeCommandStream` execs and reads output but does not write the channel
/// stdin, and base64 keeps arbitrary JSON off the remote shell's quoting rules.
///
/// One `SSHClient` is held and reused across calls (a fresh channel per call, no
/// per-request handshake — closing issue #25). Conforms to the two-method
/// `HerdrTransport` seam; `SessionRecovery`/`RecoveryExecutor` sit above it
/// unchanged.
public actor CitadelTransport: HerdrTransport {
    private let credentials: SSHCredentials
    private let hostKeyValidator: SSHHostKeyValidator
    private var client: SSHClient?
    /// A connect in flight, so concurrent first-use awaits one attempt (see
    /// `connectedClient`) rather than each opening — and leaking — its own session.
    private var connectTask: Task<SSHClient, Error>?

    /// - Parameters:
    ///   - credentials: host/port/username, the Ed25519 private key, and the
    ///     passphrase. `remoteSocketPath` is unused here — the server-side
    ///     api-bridge resolves the API socket itself.
    ///   - hostKeyValidator: the raw Citadel validator, for callers that need
    ///     full control (e.g. `.acceptAnything()` in an isolated live test).
    ///     Prefer the `hostKeyPolicy` initializer, whose default pins.
    public init(credentials: SSHCredentials, hostKeyValidator: SSHHostKeyValidator) {
        self.credentials = credentials
        self.hostKeyValidator = hostKeyValidator
    }

    /// Pins the host key on first contact and hard-stops on change (TOFU) — the
    /// safe default for a shipping client, and the same policy the libssh2
    /// transport used. Wraps the policy in the nio-ssh delegate internally, so a
    /// caller needs no Citadel/nio-ssh types and cannot accidentally get a
    /// trust-everything validator: the default here is the pinning one.
    public init(credentials: SSHCredentials, hostKeyPolicy: HostKeyPolicy = PinningHostKeyPolicy()) {
        self.credentials = credentials
        self.hostKeyValidator = .custom(PinningHostKeyValidator(
            host: credentials.host, port: credentials.port, policy: hostKeyPolicy))
    }

    // MARK: - connection

    /// Returns the held client, connecting on first use or after a drop.
    ///
    /// Concurrent first-use joins ONE connect. `SSHClient.connect` is a
    /// suspension point, and actor reentrancy lets a second caller pass the
    /// `client == nil` check while the first is still connecting; without the
    /// shared `connectTask` both would open a session and all but the last would
    /// leak (a live SSH session never closed). Callers await the same in-flight
    /// task instead.
    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        if let connectTask { return try await connectTask.value }

        let task = Task<SSHClient, Error> { try await self.makeConnection() }
        connectTask = task
        do {
            let connected = try await task.value
            client = connected
            connectTask = nil
            return connected
        } catch {
            connectTask = nil   // a failed attempt must not wedge every later call
            throw error
        }
    }

    private func makeConnection() async throws -> SSHClient {
        let privateKey = try Curve25519.Signing.PrivateKey(
            sshEd25519: Data(credentials.privateKeyPEM.utf8),
            decryptionKey: credentials.passphrase.map { Data($0.utf8) }
        )
        return try await SSHClient.connect(
            host: credentials.host,
            port: Int(credentials.port),
            authenticationMethod: .ed25519(username: credentials.username, privateKey: privateKey),
            hostKeyValidator: hostKeyValidator,
            reconnect: .never
        )
    }

    /// Conservative ceiling on the full command line, well under the kernel's
    /// MAX_ARG_STRLEN (~131072 on a 4-KiB-page Linux host; the reviewer measured
    /// E2BIG at exactly 131072). The margin absorbs the `herdr api-bridge `
    /// prefix and cross-platform variance. base64's 4/3 expansion means the raw
    /// request may be up to ~90 KiB — ample for every request except an enormous
    /// `agent.prompt` / `pane.send_text`, which is refused rather than failing at
    /// execve with no bridge to report it.
    static let maxCommandBytes = 120_000

    /// The request, base64-encoded. Kept separate from the command so the
    /// encoding contract can be tested without the shell wrapper around it.
    static func encodedRequest(for requestLine: String) -> String {
        Data(requestLine.utf8).base64EncodedString()
    }

    /// Resolves herdr on the remote host: prefer `PATH`, fall back to the
    /// standard `~/.local/bin` install location.
    ///
    /// A non-interactive SSH exec runs a NON-login shell, whose `PATH` does not
    /// include `~/.local/bin` — where herdr installs by default — so a bare
    /// `herdr api-bridge` fails with "command not found". A live round-trip
    /// caught exactly this. This mirrors herdr's own remote wrapper
    /// (src/remote/unix.rs: `command -v herdr`, else `$HOME/.local/bin/herdr`).
    static let herdrPathResolution =
        #"HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); exec "$HERDR" api-bridge "#

    /// The full exec command line: resolve herdr, then run
    /// `api-bridge <base64(requestLine)>`. base64 so no JSON metacharacter needs
    /// shell quoting. Throws `TransportError.requestTooLarge` rather than let the
    /// command exceed the argv limit and fail opaquely on the host (herdr#39's
    /// client contract).
    static func bridgeCommand(for requestLine: String) throws -> String {
        let command = herdrPathResolution + encodedRequest(for: requestLine)
        let byteCount = command.utf8.count
        guard byteCount <= maxCommandBytes else {
            throw TransportError.requestTooLarge(bytes: byteCount, max: maxCommandBytes)
        }
        return command
    }

    // MARK: - HerdrTransport

    public func roundTrip(_ requestLine: String) async throws -> String {
        let client = try await connectedClient()
        let output = try await client.executeCommandStream(try Self.bridgeCommand(for: requestLine))

        // One request, one reply line. Accumulate RAW bytes and decode UTF-8 only
        // at newline boundaries: decoding each SSH channel-data chunk on its own
        // (String(buffer:)) turns a multi-byte scalar split across a chunk boundary
        // into U+FFFD, silently corrupting the reply.
        var lines = LineAccumulator()
        var stderr = ""
        for try await chunk in output {
            switch chunk {
            case .stdout(let buffer):
                if let first = lines.append(buffer).first { return first }
            case .stderr(let buffer):
                stderr += String(buffer: buffer)  // diagnostic text; a lossy decode is fine here
            }
        }
        // Channel closed without a newline-terminated reply.
        if lines.hasRemainder { return lines.flush() }   // a reply that lacked a trailing newline
        // Empty stdout: surface the bridge/remote diagnostic rather than handing
        // the caller an empty string it can only fail to decode.
        if !stderr.isEmpty { throw TransportError.bridgeFailed(stderr: stderr) }
        throw TransportError.closedBeforeResponse
    }

    public nonisolated func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await self.connectedClient()
                    let output = try await client.executeCommandStream(try Self.bridgeCommand(for: requestLine))
                    // Same byte-accurate decoding as roundTrip: emit whole lines
                    // as they complete, decoding UTF-8 only at newline boundaries so
                    // a multi-byte scalar straddling two chunks is never corrupted.
                    var lines = LineAccumulator()
                    for try await chunk in output {
                        guard case .stdout(let bytes) = chunk else { continue }
                        for line in lines.append(bytes) { continuation.yield(line) }
                    }
                    if lines.hasRemainder { continuation.yield(lines.flush()) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer cancels the task, which closes the channel —
            // the clean teardown proven at 1.51s in the route-B falsifier, and
            // the api-bridge's stdout-hangup watcher reaps its side.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Closes the held SSH connection. Idempotent.
    public func close() async {
        connectTask?.cancel()
        connectTask = nil
        try? await client?.close()
        client = nil
    }
}

/// Accumulates raw stdout bytes and yields complete newline-delimited lines,
/// decoding UTF-8 only at line boundaries.
///
/// Decoding each SSH channel-data chunk independently (`String(buffer:)`) would
/// corrupt any multi-byte UTF-8 scalar split across a chunk boundary: the
/// incomplete tail becomes U+FFFD and its bytes are consumed, so concatenating
/// the decoded chunks can never reconstitute the character. A `\n` byte (0x0A)
/// can never fall inside a multi-byte UTF-8 sequence, so decoding only at
/// newlines keeps every line intact.
struct LineAccumulator {
    private var bytes: [UInt8] = []

    /// Appends a chunk and returns the lines it completed (newline stripped).
    mutating func append(_ buffer: ByteBuffer) -> [String] {
        bytes.append(contentsOf: buffer.readableBytesView)
        var lines: [String] = []
        while let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: bytes[..<newline], as: UTF8.self))
            bytes.removeSubrange(...newline)
        }
        return lines
    }

    /// Bytes remain after the last newline (an unterminated final line).
    var hasRemainder: Bool { !bytes.isEmpty }

    /// Decodes and clears whatever is left after the last newline.
    mutating func flush() -> String {
        defer { bytes.removeAll() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
