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

    /// - Parameters:
    ///   - credentials: host/port/username, the Ed25519 private key, and the
    ///     passphrase. `remoteSocketPath` is unused here — the server-side
    ///     api-bridge resolves the API socket itself.
    ///   - hostKeyValidator: TOFU pinning belongs here. Until the
    ///     `PinningHostKeyPolicy` port lands, callers must pass an explicit
    ///     validator; there is deliberately no `acceptAnything` default, so
    ///     this cannot silently ship trusting every host.
    public init(credentials: SSHCredentials, hostKeyValidator: SSHHostKeyValidator) {
        self.credentials = credentials
        self.hostKeyValidator = hostKeyValidator
    }

    // MARK: - connection

    /// Returns the held client, connecting on first use or after a drop.
    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }

        let privateKey = try Curve25519.Signing.PrivateKey(
            sshEd25519: Data(credentials.privateKeyPEM.utf8),
            decryptionKey: credentials.passphrase.map { Data($0.utf8) }
        )
        let client = try await SSHClient.connect(
            host: credentials.host,
            port: Int(credentials.port),
            authenticationMethod: .ed25519(username: credentials.username, privateKey: privateKey),
            hostKeyValidator: hostKeyValidator,
            reconnect: .never
        )
        self.client = client
        return client
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

        // One request, one reply line. Accumulate stdout and return the first
        // complete line; the channel closes after the single-shot API reply.
        var accumulated = ""
        for try await chunk in output {
            if case .stdout(let buffer) = chunk {
                accumulated += String(buffer: buffer)
                if let newline = accumulated.firstIndex(of: "\n") {
                    return String(accumulated[..<newline])
                }
            }
        }
        // No trailing newline (shouldn't happen for a well-formed reply) — return
        // what arrived rather than dropping it.
        return accumulated
    }

    public nonisolated func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try await self.connectedClient()
                    let output = try await client.executeCommandStream(try Self.bridgeCommand(for: requestLine))
                    var buffer = ""
                    for try await chunk in output {
                        guard case .stdout(let bytes) = chunk else { continue }
                        buffer += String(buffer: bytes)
                        // Emit whole lines as they arrive; a subscription streams
                        // one JSON object per line.
                        while let newline = buffer.firstIndex(of: "\n") {
                            continuation.yield(String(buffer[..<newline]))
                            buffer = String(buffer[buffer.index(after: newline)...])
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
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
        try? await client?.close()
        client = nil
    }
}
