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

    /// `herdr api-bridge <base64(requestLine)>` — the exec command line the
    /// remote shell runs. base64 so no JSON metacharacter needs shell quoting.
    static func bridgeCommand(for requestLine: String) -> String {
        let encoded = Data(requestLine.utf8).base64EncodedString()
        return "herdr api-bridge \(encoded)"
    }

    // MARK: - HerdrTransport

    public func roundTrip(_ requestLine: String) async throws -> String {
        let client = try await connectedClient()
        let output = try await client.executeCommandStream(Self.bridgeCommand(for: requestLine))

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
                    let output = try await client.executeCommandStream(Self.bridgeCommand(for: requestLine))
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
