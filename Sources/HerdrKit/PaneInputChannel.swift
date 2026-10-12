import Citadel
import Foundation
import NIOCore

/// An ordered, fire-and-forget input channel to ONE local pane: the daemon's
/// `pane.input.stream`, the write-side mirror of the `pane.stream` read firehose.
///
/// `pane.send_text` is stop-and-wait in practice: the terminal's input drain keeps one
/// request in flight, so every key typed behind it waits a full network round trip
/// before it can even leave. Here every batch is written the moment it is typed, as a
/// `{"seq":N,"text":…,"ack":true}` line on one held exec channel, and the daemon applies
/// frames strictly in `seq` order and acks each one. Nothing awaits the network on send.
///
/// The carrier is an exec channel running `herdr remote-api-bridge`, a full-duplex
/// stdin↔daemon-socket forwarder. (`api-bridge` cannot carry it: it stops forwarding
/// stdin after the first request, which is why the first attempt at this, issue #62,
/// was removed.)
///
/// AT-MOST-ONCE, never replayed. When the channel ends, the frames not yet acked may or
/// may not have reached the PTY; resending them could type an Enter twice, so the owner
/// counts them lost and sends what follows another way.
///
/// A class with a lock rather than an actor on purpose: `send` must be synchronous so the
/// terminal's main-actor input path writes frames in exactly the order keys arrive. Two
/// `await channel.send(…)` hops from separate tasks could enter an actor in either order.
public final class PaneInputChannel: @unchecked Sendable {
    /// Why the channel ended. Every frame written but not acked by then is unresolved:
    /// it may or may not have reached the PTY.
    public enum Ending: Error, Equatable, Sendable {
        /// `close()` was called.
        case closed
        /// The daemon refused the open request or a frame, and closed the stream.
        case rejected(APIError)
        /// The open was not answered, or a frame was not acked, in time.
        case timedOut
        /// The exec channel ended: the bridge exited or the SSH link dropped.
        case linkEnded
    }

    public enum Event: Sendable, Equatable {
        /// Every frame up to and including this seq reached the PTY.
        case acked(UInt64)
        /// The channel is gone. Always the last event, and only sent once the channel
        /// can no longer deliver a frame.
        case ended(Ending)
    }

    public enum SendError: Error, Equatable {
        /// Nothing was written: the channel is not open (not yet, or no longer).
        case notOpen
    }

    /// Whether a pane can have a stream at all. A federated pane (`<alias>/…`,
    /// #139/#140) lives on another machine; the home daemon relays one-off
    /// `pane.send_text` to it but cannot proxy `pane.input.stream`.
    public static func canStream(pane: String) -> Bool {
        !pane.isEmpty && !pane.contains("/")
    }

    /// Upper bound on one frame line, newline included. Larger text (a paste) goes out
    /// as several consecutive frames.
    static let maxFrameBytes = 64 * 1024
    static let defaultOpenTimeout: UInt64 = 10 * 1_000_000_000
    /// Normal acks take one round trip; a frame unacked this long means a dead link (a
    /// half-open TCP connection stays silent instead of failing).
    static let defaultAckTimeout: UInt64 = 30 * 1_000_000_000
    /// How long `close()` waits for the frames already written to be acked.
    static let defaultCloseTimeout: UInt64 = 5 * 1_000_000_000

    /// Acks and the ending, in order. `.ended` is always last.
    public let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private let link: RequestChannelLink
    private let openLine: String
    private let openTimeout: UInt64
    private let ackTimeout: UInt64
    private let closeTimeout: UInt64

    private enum State {
        case idle, opening, open
        /// `close()` was called with frames unacked: no new frames, waiting for their acks.
        case closing
        case ended
    }

    private let lock = NSLock()
    private var state = State.idle
    private var stdin: AsyncStream<ByteBuffer>.Continuation?
    private var runner: Task<Void, Never>?
    private var openWaiter: CheckedContinuation<Void, Error>?
    /// The open deadline while opening, the ack deadline while frames are unacked, the
    /// close deadline while closing.
    private var timer: Task<Void, Never>?
    private var lines = LineAccumulator()
    private var lastSent: UInt64 = 0
    private var lastAcked: UInt64 = 0

    init(
        link: RequestChannelLink, openLine: String,
        openTimeout: UInt64 = PaneInputChannel.defaultOpenTimeout,
        ackTimeout: UInt64 = PaneInputChannel.defaultAckTimeout,
        closeTimeout: UInt64 = PaneInputChannel.defaultCloseTimeout
    ) {
        self.link = link
        self.openLine = openLine
        self.openTimeout = openTimeout
        self.ackTimeout = ackTimeout
        self.closeTimeout = closeTimeout
        let (stream, sink) = AsyncStream<Event>.makeStream()
        events = stream
        eventSink = sink
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Starts the link, writes the open request and waits for the daemon's answer.
    /// Throws an `Ending` when the daemon refuses (unknown pane, guest), the bridge or
    /// link fails, or no answer arrives within the open timeout.
    func start() async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            let began: Bool = locked {
                guard state == .idle else { return false }
                state = .opening
                openWaiter = waiter
                let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
                stdin = continuation
                continuation.yield(ByteBuffer(string: openLine + "\n"))
                // Holds the channel for the link's lifetime: the link ends when stdin
                // finishes, the bridge exits, or the SSH connection drops.
                runner = Task { [link] in
                    do {
                        try await link.run(stdin: stream) { chunk in self.receive(chunk) }
                    } catch {
                        // A clean exit and a failure end the same way: every frame not
                        // acked by now is unresolved, which `.ended` reports.
                    }
                    self.linkEnded()
                }
                timer = after(openTimeout) { $0.openDeadlinePassed() }
                return true
            }
            if !began { waiter.resume(throwing: Ending.closed) }
        }
    }

    /// Writes `text` as one frame (several past `maxFrameBytes`; none for empty text)
    /// and returns the last seq written. Only enqueues: never waits for the network.
    /// Throws `SendError.notOpen`, having written nothing, unless the channel is open.
    @discardableResult
    public func send(_ text: String) throws -> UInt64 {
        try locked {
            guard state == .open, let stdin else { throw SendError.notOpen }
            let frames = PaneInputFrame.lines(text, firstSeq: lastSent + 1, maxLineBytes: Self.maxFrameBytes)
            for frame in frames {
                stdin.yield(frame)
            }
            lastSent += UInt64(frames.count)
            armAckDeadline()
            return lastSent
        }
    }

    /// The highest seq the daemon has acked: every frame up to it reached the PTY. Read
    /// once the channel has ended, it also covers acks whose `.acked` event was never
    /// consumed.
    public var ackedThrough: UInt64 { locked { lastAcked } }

    /// Stops taking frames and ends the channel once every frame already written is
    /// acked (at once when none is in flight), or after `closeTimeout`. So `.ended(.closed)`
    /// normally means every frame is resolved, and nothing written here can still be on
    /// its way when the owner sends what follows another way.
    public func close() {
        let now: Bool = locked {
            switch state {
            case .idle, .opening:
                return true
            case .open:
                if lastAcked == lastSent { return true }
                state = .closing
                timer?.cancel()
                timer = after(closeTimeout) { $0.end(.closed) }
                return false
            case .closing, .ended:
                return false
            }
        }
        if now { end(.closed) }
    }

    // MARK: - internals

    /// A task that runs `body` on this channel after `nanoseconds`, unless cancelled.
    private func after(_ nanoseconds: UInt64, _ body: @escaping @Sendable (PaneInputChannel) -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            body(self)
        }
    }

    private func receive(_ chunk: ExecCommandOutput) {
        // stderr is diagnostics only; nothing on this path reads it.
        guard case .stdout(let bytes) = chunk else { return }
        for line in locked({ lines.append(bytes) }) {
            handle(line)
        }
    }

    private func handle(_ line: String) {
        switch PaneInputStreamReply(line: line) {
        case .opened:
            let waiter: CheckedContinuation<Void, Error>? = locked {
                guard state == .opening else { return nil }
                state = .open
                timer?.cancel()
                timer = nil
                defer { openWaiter = nil }
                return openWaiter
            }
            waiter?.resume()
        case .acked(let seq):
            let drained: Bool = locked {
                // Acks come in seq order; anything else is not ours to count.
                guard state == .open || state == .closing, seq > lastAcked, seq <= lastSent else { return false }
                lastAcked = seq
                eventSink.yield(.acked(seq))
                return state == .closing && lastAcked == lastSent
            }
            if drained { end(.closed) }
        case .frameRejected(_, let error), .rejected(let error):
            end(.rejected(error))
        case nil:
            break
        }
    }

    /// Call with the lock held.
    private func armAckDeadline() {
        guard timer == nil, lastSent > lastAcked else { return }
        let target = lastSent
        timer = after(ackTimeout) { $0.ackDeadlinePassed(target) }
    }

    private func ackDeadlinePassed(_ target: UInt64) {
        let overdue: Bool = locked {
            guard state == .open else { return false }
            timer = nil
            if lastAcked < target { return true }
            armAckDeadline()   // later frames are still out: watch the newest
            return false
        }
        if overdue { end(.timedOut) }
    }

    private func openDeadlinePassed() {
        guard locked({ state == .opening }) else { return }
        end(.timedOut)
    }

    private func linkEnded() {
        let rest: String? = locked { lines.hasRemainder ? lines.flush() : nil }
        if let rest { handle(rest) }
        // Also while closing: a link that drops before the last ack leaves frames unresolved.
        end(.linkEnded)
    }

    private func end(_ ending: Ending) {
        let (ended, waiter, runner): (Bool, CheckedContinuation<Void, Error>?, Task<Void, Never>?) = locked {
            guard state != .ended else { return (false, nil, nil) }
            state = .ended
            stdin?.finish()
            stdin = nil
            timer?.cancel()
            timer = nil
            let waiter = openWaiter
            openWaiter = nil
            let runner = self.runner
            self.runner = nil
            // Under the lock, so no ack can be yielded after the ending.
            eventSink.yield(.ended(ending))
            eventSink.finish()
            return (true, waiter, runner)
        }
        guard ended else { return }
        waiter?.resume(throwing: ending)
        // The link may still be up (a refusal, a timeout, a close that timed out): tear
        // it down so no frame still buffered can be written after `.ended`.
        runner?.cancel()
    }
}

/// One input frame on an open `pane.input.stream`: `{"seq":N,"text":"…","ack":true}`.
///
/// Encoded by hand rather than with `JSONEncoder`: a frame goes out per keystroke, and a
/// paste is split by its EXACT encoded size, which needs an escaper whose output length
/// is known per input byte.
enum PaneInputFrame {
    private static let hex = Array("0123456789abcdef".utf8)
    private static let prefix = Array(#"{"seq":"#.utf8)
    private static let textKey = Array(#","text":""#.utf8)
    private static let suffix = Array("\",\"ack\":true}\n".utf8)
    /// Fixed bytes around the escaped text, the seq's digits (at most 20) included.
    static let overheadBytes = prefix.count + 20 + textKey.count + suffix.count
    /// Most bytes one input byte escapes to (`\u001b`).
    static let maxEscapedBytes = 6

    /// `text` as frame lines numbered from `firstSeq`, each at most `maxLineBytes`
    /// (newline included). Cuts fall only between UTF-8 scalars, so every frame's text
    /// is valid UTF-8 on its own; the daemon writes the frames' bytes to the PTY back to
    /// back, which is exactly `text`. No lines for empty text.
    static func lines(_ text: String, firstSeq: UInt64, maxLineBytes: Int) -> [ByteBuffer] {
        let budget = maxLineBytes - overheadBytes
        precondition(budget >= maxEscapedBytes, "a frame must hold at least one scalar")
        let utf8 = text.utf8
        guard !utf8.isEmpty else { return [] }
        var frames: [ByteBuffer] = []
        var seq = firstSeq
        var buffer = open(seq: seq, capacity: min(utf8.count, budget))
        var used = 0
        for byte in utf8 {
            // At a scalar's first byte: room for the whole scalar. A one-byte scalar
            // escapes to at most `maxEscapedBytes`; a longer one is never escaped (≤ 4).
            if byte & 0xC0 != 0x80, used > 0, used + maxEscapedBytes > budget {
                buffer.writeBytes(suffix)
                frames.append(buffer)
                seq += 1
                buffer = open(seq: seq, capacity: budget)
                used = 0
            }
            used += appendEscaped(byte, to: &buffer)
        }
        buffer.writeBytes(suffix)
        frames.append(buffer)
        return frames
    }

    private static func open(seq: UInt64, capacity: Int) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: overheadBytes + capacity)
        buffer.writeBytes(prefix)
        buffer.writeBytes(String(seq).utf8)
        buffer.writeBytes(textKey)
        return buffer
    }

    /// Appends `byte` escaped for a JSON string; returns the bytes written.
    private static func appendEscaped(_ byte: UInt8, to out: inout ByteBuffer) -> Int {
        let escaped: UInt8
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"): escaped = byte
        case 0x0A: escaped = UInt8(ascii: "n")
        case 0x0D: escaped = UInt8(ascii: "r")
        case 0x09: escaped = UInt8(ascii: "t")
        case 0x00..<0x20:
            out.writeInteger(UInt8(ascii: "\\"))
            out.writeInteger(UInt8(ascii: "u"))
            out.writeInteger(UInt8(ascii: "0"))
            out.writeInteger(UInt8(ascii: "0"))
            out.writeInteger(hex[Int(byte >> 4)])
            out.writeInteger(hex[Int(byte & 0x0F)])
            return maxEscapedBytes
        default:
            return out.writeInteger(byte)
        }
        out.writeInteger(UInt8(ascii: "\\"))
        out.writeInteger(escaped)
        return 2
    }
}
