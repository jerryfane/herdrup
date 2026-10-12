import Foundation

/// The terminal's key-input path for one pane: every byte typed goes out in order,
/// over the pane's `pane.input.stream` when it has one, else `pane.send_text`.
///
/// `pane.send_text` is drained stop-and-wait: one request in flight, everything typed
/// meanwhile coalesced into the next, so each burst waits a full round trip before it
/// can leave. The stream writes every `enqueue` as a frame at once and acks arrive
/// later. It opens in the background on the first key; until it is open, and whenever
/// it cannot be had (a federated pane, a non-SSH transport, an older daemon, a failed
/// open), keys keep the `send_text` drain. A failed open or a failed stream is not
/// retried for `reopenAfter`.
///
/// ORDER across the two paths is kept by never letting both carry keys at once:
/// - `send_text` → stream: frames are written only while no `send_text` is in flight.
///   A stream that opens mid-send waits for that send to return; what was typed
///   meanwhile then goes out as the first frame.
/// - stream → `send_text`: the drain runs only while there is no stream. A stream that
///   fails or is closed stays the route (keys typed meanwhile wait in `pending`) until
///   its `.ended` event arrives, which comes after its last ack and only once the
///   channel can no longer deliver a frame: every frame is then resolved, acked or
///   counted lost, before the first `send_text` goes.
///
/// Frames never acked are counted lost, NOT resent: they may already have reached the
/// PTY, and typing an Enter twice is worse than losing a key the user can see is
/// missing.
@MainActor
public final class PaneInputSender {
    public typealias SendText = @Sendable (_ text: String) async throws -> Void
    public typealias OpenStream = @Sendable () async -> PaneInputChannel?

    /// How long a failed open or a failed stream keeps the pane on `send_text`.
    public static let defaultReopenAfter: TimeInterval = 30

    private let sendText: SendText
    private let openStream: OpenStream?
    private let recorder: TypingLatencyRecorder
    private let reopenAfter: TimeInterval
    private let now: () -> TimeInterval

    /// Typed bytes not yet handed to either route.
    private var pending = ""
    /// The `send_text` drain; non-nil while a `send_text` may be in flight.
    private var textDrain: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    /// Bumped by `closeStream`/`stop`: an open that resolves under an older value is
    /// closed instead of adopted.
    private var generation = 0
    private var stream: PaneInputChannel?
    /// Frames written and not yet acked, oldest first: the seq of each `enqueue`'s last
    /// frame, the recorder batch its keys went out in, and the last `enqueue` it carries.
    private var unacked: [(seq: UInt64, batch: UInt64, through: UInt64)] = []
    /// Number of the last `enqueue`.
    private var enqueued: UInt64 = 0
    private var nextOpenAt: TimeInterval = -.infinity
    private var stopped = false

    /// Called when the server has answered every `enqueue` numbered up to `through`
    /// (the number `enqueue` returned): a `send_text` returned, or the stream acked the
    /// frame carrying it. `failed`: the send failed, or the stream ended without acking
    /// it, so whether those keys reached the pane is unknown. Answers come in order.
    public var onAcked: ((_ through: UInt64, _ failed: Bool) -> Void)?

    /// - Parameters:
    ///   - sendText: one `pane.send_text` for the pane.
    ///   - openStream: opens the pane's input stream, nil when it cannot. Pass nil for
    ///     a pane that must never stream.
    public init(
        sendText: @escaping SendText,
        openStream: OpenStream?,
        recorder: TypingLatencyRecorder = .shared,
        reopenAfter: TimeInterval = PaneInputSender.defaultReopenAfter,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sendText = sendText
        self.openStream = openStream
        self.recorder = recorder
        self.reopenAfter = reopenAfter
        self.now = now
    }

    /// Whether keys currently go out on the input stream.
    public var isStreaming: Bool { stream != nil }

    /// Sends `text` after everything enqueued before it. Returns its number, increasing
    /// per call, which `onAcked` reports; 0 when nothing is sent.
    @discardableResult
    public func enqueue(_ text: String) -> UInt64 {
        guard !stopped, !text.isEmpty else { return 0 }
        enqueued += 1
        pending += text
        pump()
        return enqueued
    }

    /// The pane left the foreground: close its stream. Keys typed until the stream has
    /// ended wait, so they cannot overtake its last frames; frames it never acked count
    /// as lost. The next key opens a new stream without waiting out `reopenAfter`.
    public func closeStream() {
        generation += 1
        opening?.cancel()
        opening = nil
        stream?.close()
    }

    /// The pane stopped: nothing more is sent. A `send_text` in flight is cancelled and
    /// the stream closed.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        pending = ""
        textDrain?.cancel()
        textDrain = nil
        closeStream()
    }

    // MARK: - routing

    private func pump() {
        guard !stopped, !pending.isEmpty else { return }
        if let stream {
            // A `send_text` still in flight goes first; its drain hands over on return.
            guard textDrain == nil else { return }
            write(to: stream)
            return
        }
        openIfDue()
        drainText()
    }

    private func write(to stream: PaneInputChannel) {
        let text = pending
        let seq: UInt64
        do {
            seq = try stream.send(text)
        } catch {
            // The stream ended and its `.ended` event is on the way, behind any acks still
            // queued. Hold the text until that event resolves every frame in flight, then
            // send it on `send_text`.
            return
        }
        pending = ""
        let batch = recorder.batchSent(byteCount: text.utf8.count, route: .inputStream)
        unacked.append((seq, batch, enqueued))
    }

    private func drainText() {
        guard textDrain == nil else { return }
        textDrain = Task { @MainActor [weak self] in
            while let self, !self.stopped, self.stream == nil, !self.pending.isEmpty {
                let text = self.pending
                let through = self.enqueued
                self.pending = ""
                let batch = self.recorder.batchSent(byteCount: text.utf8.count, route: .sendText)
                // A failed batch is dropped, as ever; the recorder counts its keys lost.
                let failed: Bool
                do {
                    try await self.sendText(text)
                    failed = false
                } catch {
                    failed = true
                }
                self.recorder.batchAcked(failed: failed, through: batch)
                self.onAcked?(through, failed)
            }
            guard let self else { return }
            self.textDrain = nil
            // A stream that opened during the last send takes what queued behind it.
            self.pump()
        }
    }

    private func openIfDue() {
        guard let openStream, stream == nil, opening == nil, now() >= nextOpenAt else { return }
        let generation = self.generation
        opening = Task { @MainActor [weak self] in
            let channel = await openStream()
            guard let self, !self.stopped, self.generation == generation else {
                channel?.close()
                return
            }
            self.opening = nil
            guard let channel else {
                self.nextOpenAt = self.now() + self.reopenAfter
                return
            }
            self.adopt(channel)
        }
    }

    private func adopt(_ channel: PaneInputChannel) {
        stream = channel
        Task { @MainActor [weak self] in
            for await event in channel.events {
                guard let self else {
                    channel.close()
                    return
                }
                self.handle(event, from: channel)
            }
        }
        pump()
    }

    private func handle(_ event: PaneInputChannel.Event, from channel: PaneInputChannel) {
        guard channel === stream else { return }
        switch event {
        case .acked(let seq):
            resolveAcks(through: seq)
        case .ended(let ending):
            streamEnded(channel, failed: ending != .closed)
        }
    }

    /// Stamps the recorder's ack on the keys of every frame up to `seq`, and only those:
    /// later frames are still in flight.
    private func resolveAcks(through seq: UInt64) {
        var covered: (batch: UInt64, through: UInt64)?
        while let first = unacked.first, first.seq <= seq {
            covered = (first.batch, first.through)
            unacked.removeFirst()
        }
        if let covered {
            recorder.batchAcked(through: covered.batch)
            onAcked?(covered.through, false)
        }
    }

    /// Resolves every frame in flight (acked, or else lost) and returns the pane to
    /// `send_text`.
    private func streamEnded(_ channel: PaneInputChannel, failed: Bool) {
        guard channel === stream else { return }
        resolveAcks(through: channel.ackedThrough)
        if let last = unacked.last {
            recorder.batchAcked(failed: true, through: last.batch)
            onAcked?(last.through, true)
        }
        unacked.removeAll()
        stream = nil
        if failed { nextOpenAt = now() + reopenAfter }
        pump()
    }
}
