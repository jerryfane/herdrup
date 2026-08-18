import Foundation
import Citadel
import NIOCore

/// A persistent, ordered input channel to ONE pane (herdr issue #62) — the
/// write-side mirror of the `pane.stream` read firehose. Holds one SSH exec
/// channel running `herdr api-bridge --duplex` open for the pane's lifetime and
/// writes newline-delimited input frames to its stdin, instead of a fresh
/// `herdr api-bridge` exec per keystroke (the remote fork/exec that dominates
/// felt typing latency on the iPad hardware-keyboard path).
///
/// Built on Citadel's `withExec` (macOS 15+/iOS 17+), which — unlike
/// `executeCommandStream`, whose output-only stream the command transport uses —
/// exposes a WRITABLE stdin (`TTYStdinWriter`) over a no-PTY, 8-bit-safe RFC-4254
/// exec channel. `withExec` is a SCOPED closure (the channel closes when it
/// returns), so the channel runs inside a long-lived Task fed by an
/// `AsyncStream<ByteBuffer>`; finishing that stream returns from the closure and
/// closes the channel (the remote bridge then sees stdin EOF and exits).
///
/// Ordering is preserved by construction: a single writer drains one ordered
/// stream to stdin. AT-MOST-ONCE, NO replay — on a drop the channel dies and the
/// caller falls back to per-call `pane.send_text`; a lost keystroke is visible
/// via the echo on `pane.stream` and retypable, whereas a duplicated Enter or
/// Escape would be dangerous.
public actor PaneInputChannel {
    public enum ChannelError: Error, Equatable {
        case unsupported
        case closedBeforeAck
        case remoteError(String)
    }

    private struct Frame: Encodable {
        let seq: UInt64
        let text: String
    }

    private struct WireErrorProbe: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
        }
        let error: Body?
    }

    private let makeConnection: @Sendable () async throws -> SSHClient
    private let command: String
    private let openLine: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var framesCont: AsyncStream<ByteBuffer>.Continuation?
    private var runner: Task<Void, Never>?
    private var client: SSHClient?
    private var seq: UInt64 = 0
    private var live = false

    // The open handshake resolves exactly once: on the daemon's first stdout line
    // (an ok ack, or an error line an old daemon returns for the unknown method),
    // or when the channel dies before any line arrives. `openOutcome` buffers the
    // result if it settles before `start()` parks its continuation.
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openOutcome: Result<Void, Error>?
    private var openSettled = false

    init(
        makeConnection: @escaping @Sendable () async throws -> SSHClient,
        command: String,
        openLine: String
    ) {
        self.makeConnection = makeConnection
        self.command = command
        self.openLine = openLine
    }

    /// Opens the channel, writes the `pane.input.stream` open line, and awaits the
    /// daemon's ack. Throws — so the caller falls back to per-call `send_text` —
    /// if `withExec` is unavailable (macOS < 15; never on iOS 17), if the daemon
    /// lacks the method (the open line returns an error), or on any transport
    /// failure. On success the channel is live and `send` writes frames.
    public func start() async throws {
        guard #available(macOS 15.0, *) else { throw ChannelError.unsupported }

        let (stream, cont) = AsyncStream<ByteBuffer>.makeStream()
        framesCont = cont
        // Single ordered writer: the open line goes first, then input frames.
        cont.yield(ByteBuffer(string: openLine + "\n"))

        runner = Task { [weak self] in
            await self?.run(stream)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let outcome = openOutcome {
                continuation.resume(with: outcome)
            } else {
                openContinuation = continuation
            }
        }
    }

    /// Enqueues one input frame. Returns false when the channel is not live (the
    /// caller then falls back to `send_text`). Fire-and-forget: never awaits an
    /// ack — the real confirmation for a human is the echo on `pane.stream`.
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard live, let framesCont, !text.isEmpty else { return false }
        seq &+= 1
        guard let data = try? encoder.encode(Frame(seq: seq, text: text)) else { return false }
        var buffer = ByteBuffer()
        buffer.reserveCapacity(data.count + 1)
        buffer.writeBytes(data)
        buffer.writeInteger(UInt8(ascii: "\n"))
        framesCont.yield(buffer)
        return true
    }

    /// Tears the channel down: finishing the frame stream returns from `withExec`,
    /// closing the SSH channel (the remote bridge then sees stdin EOF and exits).
    public func close() {
        live = false
        framesCont?.finish()
        framesCont = nil
        runner?.cancel()
    }

    // MARK: - internals

    @available(macOS 15.0, *)
    private func run(_ frameStream: AsyncStream<ByteBuffer>) async {
        do {
            let client = try await makeConnection()
            self.client = client
            try await client.withExec(command) { [weak self] inbound, stdin in
                let reader = Task { [weak self] in
                    var accumulator = LineAccumulator()
                    do {
                        for try await chunk in inbound {
                            guard case .stdout(let bytes) = chunk else { continue }
                            for line in accumulator.append(bytes) {
                                await self?.handleLine(line)
                            }
                        }
                    } catch {
                        // stdout closed/errored: the channel is done; the writer
                        // loop below unwinds when its stream finishes.
                    }
                }
                defer { reader.cancel() }
                for await buffer in frameStream {
                    try await stdin.write(buffer)
                }
            }
            try? await client.close()
        } catch {
            // makeConnection / withExec failed before or during the channel.
        }
        settleOpen(.failure(ChannelError.closedBeforeAck))
        markDead()
    }

    private func handleLine(_ line: String) {
        if !openSettled {
            if isErrorLine(line) {
                settleOpen(.failure(ChannelError.remoteError(line)))
                markDead()
            } else {
                live = true
                settleOpen(.success(()))
            }
            return
        }
        // Post-ack lines are only the daemon's terminal error (or an ack for a
        // frame that asked for one; v1 sends none). Any error line closes us.
        if isErrorLine(line) {
            markDead()
        }
    }

    private func isErrorLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let probe = try? decoder.decode(WireErrorProbe.self, from: data)
        else { return false }
        return probe.error != nil
    }

    private func settleOpen(_ result: Result<Void, Error>) {
        guard !openSettled else { return }
        openSettled = true
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(with: result)
        } else {
            openOutcome = result
        }
    }

    private func markDead() {
        live = false
        framesCont?.finish()
        framesCont = nil
    }
}
