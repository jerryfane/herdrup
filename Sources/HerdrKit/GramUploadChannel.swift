import Citadel
import Foundation
import NIOCore

/// A streaming upload channel for ONE gram attachment — the file-transfer mirror
/// of `PaneInputChannel`. Holds a single SSH exec channel running
/// `herdr api-bridge --duplex` open for the upload's lifetime and writes
/// newline-delimited chunk frames to the daemon's `gram.upload.stream`, instead
/// of one `herdr api-bridge` exec per chunk.
///
/// Why this exists: the per-chunk path (`gram.upload_chunk`) costs an SSH channel
/// open, a non-login shell, a fresh `herdr` process, a unix-socket connect and a
/// teardown FOR EVERY CHUNK — 2133 of them for a 100 MB file, whose chunk size is
/// itself pinned at 48 KiB by the argv cap. Uploads are round-trip bound, not
/// bandwidth bound. One held channel with 512 KiB frames removes both limits.
///
/// Three deliberate differences from `PaneInputChannel`:
///
/// 1. The encoder must not escape `/`. Base64 is slash-dense (an all-`0xFF` chunk
///    is ALL `/`), and JSONEncoder's default escaping nearly doubles those bytes.
/// 2. `sendChunk` AWAITS the daemon's ack. Fire-and-forget is right for
///    keystrokes and catastrophic for a 100 MB file: the whole point of streaming
///    from disk is that resident memory stays at one chunk, which an unbounded
///    queue would undo. The ack is also the only place a rejected chunk can
///    surface, since an upload has no echo channel.
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

    // Frames are strictly sequential, so ONE ack slot suffices.
    private var ackContinuation: CheckedContinuation<Void, Error>?
    private var pendingSeq: UInt64?

    init(
        makeConnection: @escaping @Sendable () async throws -> SSHClient,
        command: String,
        openLine: String
    ) {
        self.makeConnection = makeConnection
        self.command = command
        self.openLine = openLine
    }

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

    /// Writes one chunk frame and awaits its ack, so a large file cannot queue in
    /// memory and a rejected chunk surfaces at the chunk that caused it.
    public func sendChunk(offset: UInt64, dataBase64: String) async throws {
        guard live, let framesCont else { throw ChannelError.closedBeforeFrameAck }
        seq &+= 1
        let frameSeq = seq
        let line = try Self.encodeFrame(seq: frameSeq, offset: offset, dataBase64: dataBase64)

        var buffer = ByteBuffer()
        buffer.reserveCapacity(line.utf8.count + 1)
        buffer.writeString(line)
        buffer.writeInteger(UInt8(ascii: "\n"))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingSeq = frameSeq
            ackContinuation = continuation
            framesCont.yield(buffer)
        }
    }

    /// Tears the channel down: finishing the frame stream returns from `withExec`,
    /// closing the SSH channel (the remote bridge then sees stdin EOF and exits,
    /// which is the daemon's clean end-of-upload signal). Idempotent.
    public func close() {
        live = false
        framesCont?.finish()
        framesCont = nil
        runner?.cancel()
        resumeAck(.failure(ChannelError.closedBeforeFrameAck))
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
            // closes the channel and the upload cannot continue on it.
            resumeAck(.failure(ChannelError.remoteError(apiError(from: error))))
            markDead()
            return
        }

        guard wire.ok == true, let seq = wire.seq else { return }
        guard seq == pendingSeq else {
            // An ack for a frame we are not waiting on means the channel and the
            // client disagree about ordering; treat it as fatal rather than
            // silently accepting a chunk that may not have landed.
            resumeAck(
                .failure(
                    ChannelError.remoteError(
                        APIError(
                            code: "invalid_sequence",
                            message: "ack for seq \(seq) while awaiting \(pendingSeq.map(String.init) ?? "none")"
                        ))))
            markDead()
            return
        }
        resumeAck(.success(()))
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
        pendingSeq = nil
        continuation.resume(with: result)
    }

    private func markDead() {
        live = false
        framesCont?.finish()
        framesCont = nil
        resumeAck(.failure(ChannelError.closedBeforeFrameAck))
    }
}
