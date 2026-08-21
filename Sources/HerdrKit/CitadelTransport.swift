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
    /// Bumped by `close()`. A connect that resolves after its starting generation is
    /// STALE: close() has already torn down and believes there is no live session, so
    /// the resolved client must be reaped, never installed. This closes the residual
    /// window where a handshake completing exactly as the user disconnects would
    /// otherwise re-install a live session behind close()'s back (leak).
    private var generation = 0

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

    /// Pins the host key on first contact and hard-stops on change (TOFU),
    /// wrapping the policy in the nio-ssh delegate internally so a caller needs
    /// no Citadel/nio-ssh types and cannot accidentally get a trust-everything
    /// validator.
    ///
    /// The default policy (`PinningHostKeyPolicy()`) is backed by the
    /// PROCESS-WIDE `PinStore.shared`, so two transports created this way enforce
    /// one pin set (a transport recreated mid-process still hard-stops a changed
    /// key). It does NOT persist across app launches — for cross-launch TOFU a
    /// shipping client passes its own `HostKeyPolicy` here that pins against
    /// persistent (e.g. Keychain) storage; `PinStore` is in-memory only.
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

        // Capture the generation BEFORE awaiting: if close() runs during the
        // handshake it bumps `generation`, marking whatever resolves as stale.
        let gen = generation
        let task: Task<SSHClient, Error>
        if let connectTask {
            task = connectTask                      // join the in-flight attempt
        } else {
            let created = Task<SSHClient, Error> { try await self.makeConnection() }
            connectTask = created
            task = created
        }
        do {
            let connected = try await task.value
            // Validate AFTER the suspension, under actor isolation. If close() ran
            // while we awaited, this session is orphaned — close() already believes
            // there is nothing to tear down, so reap it rather than installing a live
            // client behind close()'s back. BOTH the creator and any joined waiter
            // pass through this same check.
            guard gen == generation else {
                try? await connected.close()
                throw CancellationError()
            }
            client = connected
            if connectTask == task { connectTask = nil }
            return connected
        } catch {
            // Only clear the slot if it still holds OUR task — never clobber a newer
            // connect started after a close() bumped the generation.
            if connectTask == task { connectTask = nil }
            throw error
        }
    }

    private func makeConnection() async throws -> SSHClient {
        let method: SSHAuthenticationMethod
        switch credentials.auth {
        case .privateKey(let pem, let passphrase):
            let privateKey = try Curve25519.Signing.PrivateKey(
                sshEd25519: Data(pem.utf8),
                decryptionKey: passphrase.map { Data($0.utf8) }
            )
            method = .ed25519(username: credentials.username, privateKey: privateKey)
        case .password(let password):
            method = .passwordBased(username: credentials.username, password: password)
        }
        // A client that resolves after a concurrent close() is reaped by the
        // generation check in connectedClient() (the only publisher of `self.client`),
        // so no cancellation handling is needed here.
        do {
            return try await SSHClient.connect(
                host: credentials.host,
                port: Int(credentials.port),
                authenticationMethod: method,
                hostKeyValidator: hostKeyValidator,
                reconnect: .never
            )
        } catch SSHClientError.unsupportedPasswordAuthentication {
            // The server offers no password auth (e.g. `PasswordAuthentication no`).
            throw TransportError.passwordAuthUnsupported(host: credentials.host)
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // Wrong password / rejected key. Host-key rejection is thrown by the
            // validator, not caught here, so it keeps its dedicated recovery path.
            throw TransportError.authenticationFailed(host: credentials.host)
        }
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

    /// Sentinel the exec wrapper prints to stderr when herdr is absent (see
    /// `herdrPathResolution`). `classifyBridgeFailure` matches it to raise
    /// `.herdrNotInstalled` rather than a generic `.bridgeFailed`. A fixed ASCII
    /// token, deliberately NOT the shell's locale-dependent "not found" wording.
    static let herdrNotInstalledSentinel = "__HERDR_NOT_INSTALLED__"

    /// Resolves herdr on the remote host: prefer `PATH`, fall back to the
    /// standard `~/.local/bin` install location — then GUARD that the resolved
    /// path is actually executable before exec'ing it.
    ///
    /// A non-interactive SSH exec runs a NON-login shell, whose `PATH` does not
    /// include `~/.local/bin` — where herdr installs by default — so a bare
    /// `herdr api-bridge` fails with "command not found". A live round-trip
    /// caught exactly this. This mirrors herdr's own remote wrapper
    /// (src/remote/unix.rs: `command -v herdr`, else `$HOME/.local/bin/herdr`).
    ///
    /// The `[ -x "$HERDR" ]` guard separates "herdr is not installed at all" from
    /// every other bridge failure: when neither PATH nor the fallback path holds an
    /// executable, it prints `herdrNotInstalledSentinel` and exits BEFORE exec, so
    /// `classifyBridgeFailure` can raise `.herdrNotInstalled` and the client can
    /// offer install guidance instead of surfacing a raw stderr line.
    static let herdrPathResolution =
        #"HERDR=$(command -v herdr || echo "$HOME/.local/bin/herdr"); [ -x "$HERDR" ] || { echo \#(herdrNotInstalledSentinel) >&2; exit 127; }; exec "$HERDR" api-bridge "#

    /// Classifies a bridge failure from its stderr and the remote EXIT CODE. When
    /// herdr is absent the exec wrapper prints `herdrNotInstalledSentinel` (see
    /// `herdrPathResolution`) → `.herdrNotInstalled(host:)`. When herdr IS present but
    /// does not understand the `api-bridge` subcommand — an upstream build, or a fork
    /// too old to have it — its arg-parser (clap) rejects the subcommand and exits
    /// with code 2 → `.herdrIncompatible(host:)`. Anything else stays a generic
    /// `.bridgeFailed(stderr:)`. Pure, so it is host-testable without SSH.
    static func classifyBridgeFailure(stderr: String, exitCode: Int, host: String) -> TransportError {
        if stderr.contains(herdrNotInstalledSentinel) { return .herdrNotInstalled(host: host) }
        // clap's usage-error exit code. The only thing the wrapper runs is
        // `herdr api-bridge`, so exit 2 almost always means herdr is there but can't run
        // the app. TRADE-OFF: a fork that HAS api-bridge but exits 2 for an unrelated
        // usage error is mis-badged "incompatible" — accepted, because the guidance is
        // non-destructive advice and the alternative is the raw exit code; matching on
        // clap's stderr text instead would re-couple to a fragile, version-specific string.
        if exitCode == 2 { return .herdrIncompatible(host: host) }
        return .bridgeFailed(stderr: stderr)
    }

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
        return try await Self.parseBridgeOutput(output, host: credentials.host)
    }

    /// Consumes the api-bridge exec output stream into its single reply line, or throws
    /// a classified `TransportError`. Extracted from `roundTrip` for ONE reason: to make
    /// the reachability of the exit-code classification testable. Citadel throws
    /// `CommandFailed` at EOF on ANY non-zero exit, so the `do/catch` MUST enclose the
    /// throwing loop or the raw "command failed, exit code N" escapes and the
    /// not-installed / incompatible guidance is never reached. `SSHClient` itself is not
    /// injectable, but a test can feed this a fake `AsyncThrowingStream` that finishes
    /// `throwing:` a `RemoteExitError`, binding that the catch is present AND scoped.
    static func parseBridgeOutput(
        _ output: AsyncThrowingStream<ExecCommandOutput, Error>, host: String
    ) async throws -> String {
        // One request, one reply line. Accumulate RAW bytes and decode UTF-8 only at
        // newline boundaries: decoding each SSH channel-data chunk on its own
        // (String(buffer:)) turns a multi-byte scalar split across a chunk boundary into
        // U+FFFD, silently corrupting the reply.
        var lines = LineAccumulator()
        var stderr = ""
        do {
            for try await chunk in output {
                switch chunk {
                case .stdout(let buffer):
                    if let first = lines.append(buffer).first { return first }
                case .stderr(let buffer):
                    stderr += String(buffer: buffer)  // diagnostic text; a lossy decode is fine here
                }
            }
        } catch let failure as RemoteExitError {
            // A non-zero remote exit: Citadel throws `CommandFailed` at EOF instead of
            // ending the stream, so this catch is the ONLY place the exit status is
            // visible — without it the raw "command failed, exit code N" escapes and the
            // not-installed / incompatible guidance is never reached. A reply may still
            // have arrived first (returned above); reaching here means it did not.
            if lines.hasRemainder { return lines.flush() }
            throw classifyBridgeFailure(stderr: stderr, exitCode: failure.remoteExitCode, host: host)
        }
        // Channel closed on exit 0 without a newline-terminated reply.
        if lines.hasRemainder { return lines.flush() }   // a reply that lacked a trailing newline
        // Empty stdout: surface the bridge/remote diagnostic rather than handing
        // the caller an empty string it can only fail to decode.
        if !stderr.isEmpty {
            throw classifyBridgeFailure(stderr: stderr, exitCode: 0, host: host)
        }
        throw TransportError.closedBeforeResponse
    }

    public nonisolated func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // A subscription gets its OWN connection, NOT the shared command
            // client. Citadel's public `executeCommandStream` exposes only the
            // output stream and never closes its child channel (only the internal
            // `_executeCommandStream` does), so a subscription's resources are not
            // individually owned. Giving each stream a dedicated client means
            // termination closes it explicitly — deterministic per-subscription
            // cleanup rather than relying on the event loop dropping it. (Review
            // finding #2 asked for this explicit ownership.)
            let connection = StreamConnection()
            let task = Task {
                do {
                    let client = try await self.makeConnection()
                    await connection.adopt(client)
                    if Task.isCancelled { await connection.close(); continuation.finish(); return }
                    let output = try await client.executeCommandStream(try Self.bridgeCommand(for: requestLine))
                    // Same byte-accurate decoding as roundTrip: decode UTF-8 only
                    // at newline boundaries so a multi-byte scalar straddling two
                    // chunks is never corrupted.
                    var lines = LineAccumulator()
                    for try await chunk in output {
                        guard case .stdout(let bytes) = chunk else { continue }
                        for line in lines.append(bytes) { continuation.yield(line) }
                    }
                    if lines.hasRemainder { continuation.yield(lines.flush()) }
                    await connection.close()
                    continuation.finish()
                } catch is CancellationError {
                    await connection.close()
                    continuation.finish()
                } catch let failure as RemoteExitError {
                    // Same non-zero-exit mapping as `roundTrip`, so a pane stream against
                    // an incompatible/absent herdr fails legibly instead of as a raw
                    // CommandFailed. This path accumulates no stderr, so classify by code
                    // (exit 2 → incompatible); the sentinel case is caught by roundTrip
                    // on the initial connect before any stream is opened.
                    await connection.close()
                    continuation.finish(
                        throwing: Self.classifyBridgeFailure(
                            stderr: "", exitCode: failure.remoteExitCode, host: self.credentials.host))
                } catch {
                    await connection.close()
                    continuation.finish(throwing: error)
                }
            }
            // Termination cancels the reader AND closes the dedicated client,
            // which reaps the SSH channel now rather than leaking it until the
            // process exits.
            continuation.onTermination = { _ in
                task.cancel()
                Task { await connection.close() }
            }
        }
    }

    /// Opens a persistent input channel to one pane (issue #62): a dedicated SSH
    /// exec channel running `herdr api-bridge --duplex`, over which
    /// `PaneInputChannel` writes newline-delimited input frames to the daemon's
    /// `pane.input.stream`. Uses its OWN connection (like `stream`) so input
    /// backpressure never blocks the shared command socket or the pane.stream
    /// firehose. `openLine` is the JSON `pane.input.stream` open request the
    /// daemon's `--duplex` bridge reads first from stdin.
    public nonisolated func openInputChannel(_ openLine: String) -> PaneInputChannel {
        PaneInputChannel(
            makeConnection: { try await self.makeConnection() },
            command: Self.herdrPathResolution + "--duplex",
            openLine: openLine
        )
    }

    /// Closes the held SSH connection. Idempotent.
    public func close() async {
        // Invalidate any in-flight connect so a handshake that resolves after this
        // point is reaped by connectedClient() rather than installed post-close.
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        // Snapshot and CLEAR the slot BEFORE awaiting teardown. Awaiting the old
        // client's close is a suspension point, and actor reentrancy lets a NEW
        // generation connect install a fresh client during it (a legitimate
        // reconnect). A trailing unconditional `client = nil` would then discard that
        // live session unclosed. Nil-before-await confines this teardown to the OLD
        // client and never clobbers a reconnect that lands mid-close.
        let old = client
        client = nil
        try? await old?.close()
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

/// Owns a subscription's dedicated SSH client so termination can close it —
/// which reaps the exec channel that Citadel's `executeCommandStream` would
/// otherwise leave open. Idempotent; a `close` that races the connect (`adopt`
/// after `close`) still closes the late client.
actor StreamConnection {
    private var client: SSHClient?
    private var closed = false

    func adopt(_ client: SSHClient) async {
        if closed {
            try? await client.close()
        } else {
            self.client = client
        }
    }

    func close() async {
        closed = true
        let held = client
        client = nil
        try? await held?.close()
    }
}

/// A remote command's non-zero exit, abstracted so `parseBridgeOutput`'s classification
/// path is unit-testable. A test cannot construct Citadel's `SSHClient.CommandFailed`
/// (its memberwise initialiser is internal to that module), so `parseBridgeOutput`
/// catches THIS protocol instead of the concrete type; the test injects its own
/// conforming error through a fake stream. Citadel's error conforms below.
protocol RemoteExitError: Error {
    var remoteExitCode: Int { get }
}

extension SSHClient.CommandFailed: RemoteExitError {
    var remoteExitCode: Int { exitCode }
}
