import Citadel
import Foundation
import NIOCore

/// A streaming upload channel for ONE gram attachment. Holds a single SSH
/// exec channel running `herdr remote-api-bridge` for the upload's lifetime and writes
/// newline-delimited chunk frames to the daemon's `gram.upload.stream`, instead
/// of one `herdr api-bridge` exec per chunk.
///
/// Why this exists: the per-chunk path (`gram.upload_chunk`) costs an SSH channel
/// open, a non-login shell, a fresh `herdr` process, a unix-socket connect and a
/// teardown FOR EVERY CHUNK — 2133 of them for a 100 MB file, whose chunk size is
/// itself pinned at 48 KiB by the argv cap. Uploads are round-trip bound, not
/// bandwidth bound. One held channel with 512 KiB frames removes both limits.
///
/// Three upload-specific requirements:
///
/// 1. The encoder must not escape `/`. Base64 is slash-dense (an all-`0xFF` chunk
///    is ALL `/`), and JSONEncoder's default escaping nearly doubles those bytes.
/// 2. `sendChunk` keeps at most `maxFramesInFlight` frames unacked, and `finish`
///    waits for the last ack. Fire-and-forget is right for keystrokes and
///    catastrophic for a 100 MB file: the whole point of streaming from disk is
///    that resident memory stays at a few chunks, which an unbounded queue would
///    undo. The acks are also the only place a rejected chunk can surface, since an
///    upload has no echo channel. One frame in flight, though, idles the link for a
///    round trip per 512 KiB — about 2 MB/s at 120 ms (herdrup#573) — and the
///    daemon reads frames in order off one connection, so it needs no change to
///    take several.
/// 3. `remoteError` carries a DECODED `APIError`, because the caller must tell
///    "this daemon has no such method" (fall back) from "offset mismatch" or
///    "another stream owns this upload" (do not).
public actor GramUploadChannel {
    public enum ChannelError: Error, Equatable {
        case unsupported
        case closedBeforeAck
        /// A frame or open error from the daemon, decoded rather than raw: the
        /// caller needs `code`/`message` to tell "old daemon" and "offset
        /// mismatch" apart.
        case remoteError(APIError)
        /// The channel died between writing a frame and its ack.
        case closedBeforeFrameAck
    }

    /// One chunk. `offset` is the byte position, which the daemon validates
    /// against the staged size (staging is append-only), so frames MUST be sent
    /// in order — which is also why one outstanding ack is enough.
    private struct Frame: Encodable {
        let seq: UInt64
        let offset: UInt64
        let dataBase64: String
        enum CodingKeys: String, CodingKey {
            case seq, offset
            case dataBase64 = "data_base64"
        }
    }

    /// The daemon's two reply shapes: an open error carries `id`, a frame ack or
    /// frame error carries `seq`.
    private struct WireLine: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
        }
        let seq: UInt64?
        let ok: Bool?
        let error: Body?
    }

    private let makeConnection: @Sendable () async throws -> SSHClient
    private let command: String
    private let openLine: String
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Base64 payloads are slash-dense; default escaping would inflate a
        // 700 KB frame toward the daemon's 1 MiB frame cap for nothing.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
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

    /// Frames are acked in order, so the frames written but not yet acked are a
    /// FIFO of their sequence numbers.
    private var unacked: [UInt64] = []
    /// The one caller parked until at most `waitingFor` frames are unacked:
    /// `sendChunk` waiting for window space, or `finish` for the last ack.
    private var ackContinuation: CheckedContinuation<Void, Error>?
    private var waitingFor = 0
    /// A frame error the daemon sent while nobody was parked, rethrown by the
    /// next `sendChunk` or `finish` rather than lost.
    private var frameFailure: Error?

    /// How many chunk frames may be written ahead of their acks: a few round trips'
    /// worth of a 512 KiB frame keeps a 100 ms link busy, and bounds what is resident
    /// to ~4 × 700 KB of encoded frames.
    static let maxFramesInFlight = 4

    /// How long [`closeAndWait`] may wait for the SSH session to go away before the
    /// runner is cancelled. Injectable for the same reason
    /// `CitadelTransport.connectTimeoutNanoseconds` is: an unstructured race is only
    /// provably bounded if a test can shorten the bound.
    private let closeGrace: UInt64

    init(
        makeConnection: @escaping @Sendable () async throws -> SSHClient,
        command: String,
        openLine: String,
        closeGrace: UInt64 = GramUploadChannel.defaultCloseGraceNanoseconds
    ) {
        self.makeConnection = makeConnection
        self.command = command
        self.openLine = openLine
        self.closeGrace = closeGrace
    }

    /// Generous for a live link (the frames are already acked, so this is only
    /// channel teardown) and short enough that a dead link cannot hold the UI.
    static let defaultCloseGraceNanoseconds: UInt64 = 5 * 1_000_000_000

    /// Encodes one frame line. A static seam so the property that makes 512 KiB
    /// frames legal — a slash-heavy chunk stays inside the daemon's 1 MiB frame
    /// cap — is testable without an SSH connection.
    static func encodeFrame(seq: UInt64, offset: UInt64, dataBase64: String) throws -> String {
        let data = try encoder.encode(Frame(seq: seq, offset: offset, dataBase64: dataBase64))
        return String(decoding: data, as: UTF8.self)
    }

    /// Opens the channel, writes the `gram.upload.stream` open line, and awaits
    /// the daemon's ack. Throws `unsupported` when `withExec` is unavailable
    /// (macOS < 15; never on iOS 17+), `remoteError` when the daemon refuses the
    /// open, and `closedBeforeAck` on any transport failure — the caller then
    /// falls back to per-chunk uploads.
    public func start() async throws {
        guard #available(macOS 15.0, *) else { throw ChannelError.unsupported }

        let (stream, cont) = AsyncStream<ByteBuffer>.makeStream()
        framesCont = cont
        // Single ordered writer: the open line goes first, then chunk frames.
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

    /// Writes one chunk frame, then waits while `maxFramesInFlight` frames are
    /// unacked, so a large file cannot queue in memory and a rejected chunk surfaces
    /// within a few chunks of the one that caused it. Call `finish` after the last.
    public func sendChunk(offset: UInt64, dataBase64: String) async throws {
        if let frameFailure { throw frameFailure }
        guard live, let framesCont else { throw ChannelError.closedBeforeFrameAck }
        seq &+= 1
        let frameSeq = seq
        let line = try Self.encodeFrame(seq: frameSeq, offset: offset, dataBase64: dataBase64)

        var buffer = ByteBuffer()
        buffer.reserveCapacity(line.utf8.count + 1)
        buffer.writeString(line)
        buffer.writeInteger(UInt8(ascii: "\n"))

        try Task.checkCancellation()
        unacked.append(frameSeq)
        framesCont.yield(buffer)
        try await awaitAcks(untilAtMost: Self.maxFramesInFlight - 1)
    }

    /// Waits for the daemon to ack every frame written so far, so the caller knows
    /// the whole file is staged and every rejection has surfaced. Call it after the
    /// last `sendChunk` and before `closeAndWait`.
    public func finish() async throws {
        if let frameFailure { throw frameFailure }
        try await awaitAcks(untilAtMost: 0)
    }

    private func awaitAcks(untilAtMost limit: Int) async throws {
        guard unacked.count > limit else { return }
        guard live else { throw ChannelError.closedBeforeFrameAck }
        // A cancelled upload must not leave this task parked forever: nothing else
        // resumes the wait (the resumers are an ack line, a frame error, `close()` and
        // `markDead()`), and the caller's `defer`-based close cannot run while it is
        // suspended here. Cancelling tears the channel down, which resumes the wait
        // with `closedBeforeFrameAck`.
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                waitingFor = limit
                ackContinuation = continuation
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    /// Tears the channel down: finishing the frame stream returns from `withExec`,
    /// closing the SSH channel (the remote bridge then sees stdin EOF and exits,
    /// which is the daemon's clean end-of-upload signal). Idempotent.
    ///
    /// Does NOT wait for that teardown to complete. Use [`closeAndWait`] when the
    /// next action depends on the daemon having observed the close.
    public func close() {
        live = false
        framesCont?.finish()
        framesCont = nil
        runner?.cancel()
        resumeAck(.failure(ChannelError.closedBeforeFrameAck))
    }

    /// Closes the channel and waits until the SSH session is actually gone.
    ///
    /// The daemon releases its single-writer claim on the `upload_id` only when it
    /// observes EOF on this connection, and it now REFUSES a `gram.post` that would
    /// finalize an upload a stream still owns. So an upload followed by a post must
    /// order the two: returning while the teardown is still in flight makes the post
    /// race the claim release and fail with `upload_in_progress` after a completely
    /// successful upload.
    ///
    /// `nonisolated` on purpose: awaiting the runner must NOT hold this actor, or the
    /// runner's own calls back into it (`handleLine`, `markDead`) could never land.
    ///
    /// BOUNDED, and the shape of that bound matters. The runner finishes only once
    /// NIOSSH succeeds its close promise, which it does only when the PEER's
    /// CHANNEL_CLOSE arrives — there is no timer on that path, and cancelling a Task
    /// does NOT interrupt an await on a NIO promise. So the deadline must not be a
    /// task group: `group.cancelAll()` cannot make a child awaiting `runner.value`
    /// return, and the group's scope waits for every child, which would leave this
    /// exactly as unbounded as a bare `await runner.value`. Instead both observers
    /// are UNSTRUCTURED and signal a one-shot gate, so this returns on the deadline
    /// whatever the runner is doing. A half-open TCP (cell handoff, Wi-Fi drop, NAT
    /// rebind) would otherwise park here for the kernel's whole retransmit budget and
    /// wedge the composer exactly as the deadlocking reader used to.
    ///
    /// On the EXPIRY path the daemon has NOT yet freed its claim on this `upload_id`
    /// — that is precisely why we are returning early — so a `gram.post` issued next
    /// can legitimately be refused `upload_in_progress`. The caller must present that
    /// as retryable rather than as a failure; see `HerdrClient.gramUploadFile`.
    public nonisolated func closeAndWait() async {
        guard let runner = await beginGracefulClose() else { return }
        let gate = CloseGate()
        Task {
            await runner.value
            await gate.signal()
        }
        let grace = await closeGraceNanoseconds
        Task {
            // `try?`: a cancelled sleep must still fall through to the teardown, or a
            // cancelled caller would hang on the gate forever.
            try? await Task.sleep(nanoseconds: grace)
            runner.cancel()
            // Cancellation does NOT interrupt the runner's await on the SSH channel's
            // close promise, so without this the parent connection is never closed:
            // the actor would keep an `SSHClient`, a socket and a live Task for the
            // kernel's whole retransmit budget, and — because the FIN is never even
            // attempted — the daemon would see a channel that is open but silent,
            // which is exactly the input that pins its single-writer claim. Same
            // pattern as `CitadelTransport.close()`: tear the connection down locally
            // rather than wait on a per-channel promise.
            await self.closeConnection()
            await gate.signal()
        }
        await gate.wait()
    }

    private var closeGraceNanoseconds: UInt64 { closeGrace }

    /// Closes the upload's own SSH connection and forgets it. Idempotent: the field
    /// is cleared, so a later `run` tail close is a no-op rather than a double close.
    private func closeConnection() async {
        guard let client else { return }
        self.client = nil
        try? await client.close()
    }

    /// One-shot rendezvous: whichever of the two observers finishes first releases
    /// the waiter, and the other's later signal is dropped.
    private actor CloseGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var signalled = false

        func wait() async {
            if signalled { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            guard !signalled else { return }
            signalled = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Finishes the frame stream and hands back the runner to await. The runner is
    /// deliberately NOT nilled: `close()` must keep something to cancel, since
    /// `Task<Void, Never>.value` ignores the awaiting task's own cancellation.
    private func beginGracefulClose() -> Task<Void, Never>? {
        live = false
        framesCont?.finish()
        framesCont = nil
        resumeAck(.failure(ChannelError.closedBeforeFrameAck))
        return runner
    }

    // MARK: - internals

    @available(macOS 15.0, *)
    private func run(_ frameStream: AsyncStream<ByteBuffer>) async {
        // The connection is closed through `closeConnection()` on every exit — a
        // throw from `withExec` (dropped link, failed channel open, mid-upload write
        // error) included. Leaking it would strand one TCP session, one sshd session
        // and one remote `api-bridge` process PER FILE, since each upload mints its
        // own connection. One teardown path also means the expiry branch in
        // `closeAndWait` and this tail cannot double-close.
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
                        // stdout closed/errored.
                    }
                    // The reader is the ONLY observer of the remote side, so it must
                    // tear the actor down itself. Nothing else can: the writer loop
                    // below is parked on `frameStream`, which only `markDead`/`close`
                    // finish, and the caller's `defer`-close cannot run while it is
                    // suspended in `sendChunk` awaiting an ack. Without this, a daemon
                    // that closes the channel with an ack outstanding deadlocks the
                    // upload permanently — the composer stays `sending` and
                    // undismissable until the app is force-quit.
                    await self?.markDead()
                }
                defer { reader.cancel() }
                for await buffer in frameStream {
                    try await stdin.write(buffer)
                }
            }
        } catch {
            // makeConnection / withExec failed before or during the channel.
        }
        await closeConnection()
        settleOpen(.failure(ChannelError.closedBeforeAck))
        markDead()
    }

    /// One stdout line from the daemon. Internal so tests can play the daemon's
    /// acks without an SSH connection.
    func handleLine(_ line: String) {
        guard let wire = decode(line) else { return }

        if !openSettled {
            if let error = wire.error {
                settleOpen(.failure(ChannelError.remoteError(apiError(from: error))))
                markDead()
            } else {
                live = true
                settleOpen(.success(()))
            }
            return
        }

        if let error = wire.error {
            // A frame error is terminal: staging is append-only, so the daemon
            // closes the channel and the upload cannot continue on it. Kept for the
            // next call too: with frames in flight nobody may be parked right now.
            fail(ChannelError.remoteError(apiError(from: error)))
            return
        }

        guard wire.ok == true, let seq = wire.seq else { return }
        guard seq == unacked.first else {
            // An ack out of order, or for a frame never written, means the channel
            // and the client disagree about ordering; treat it as fatal rather than
            // silently accepting a chunk that may not have landed.
            fail(
                ChannelError.remoteError(
                    APIError(
                        code: "invalid_sequence",
                        message: "ack for seq \(seq) while awaiting \(unacked.first.map(String.init) ?? "none")"
                    )))
            return
        }
        unacked.removeFirst()
        if unacked.count <= waitingFor { resumeAck(.success(())) }
    }

    private func fail(_ error: Error) {
        if frameFailure == nil { frameFailure = error }
        resumeAck(.failure(error))
        markDead()
    }

    private func decode(_ line: String) -> WireLine? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(WireLine.self, from: data)
    }

    private func apiError(from body: WireLine.Body) -> APIError {
        APIError(code: body.code ?? "stream_failed", message: body.message ?? "upload stream failed")
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

    private func resumeAck(_ result: Result<Void, Error>) {
        guard let continuation = ackContinuation else { return }
        ackContinuation = nil
        continuation.resume(with: result)
    }

    private func markDead() {
        live = false
        framesCont?.finish()
        framesCont = nil
        resumeAck(.failure(ChannelError.closedBeforeFrameAck))
    }
}
