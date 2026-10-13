import Foundation

/// When Gram fetches an image attachment on its own, so the feed shows the picture
/// without the owner opening it first.
///
/// The fetch goes through the same daemon download and cache as an explicit open, so
/// these rules bound what the feed spends unasked: images only, nothing over the size
/// cap (those keep the placeholder until opened), and only a couple at a time so a
/// fast scroll past many pictures never queues a burst of transfers.
public enum GramImagePreview {
    /// The largest attachment the feed downloads unasked.
    public static let maxPrefetchBytes: UInt64 = 8 * 1024 * 1024
    /// Unasked downloads running at once. An explicit open or save is never counted.
    public static let maxConcurrentPrefetches = 2

    public static func shouldPrefetch(_ file: GramFile) -> Bool {
        file.isImage && file.size <= maxPrefetchBytes
    }
}

/// At most `limit` holders at a time; later `acquire` calls wait in order.
///
/// A waiter whose task is cancelled leaves the queue at once and throws
/// `CancellationError` without ever taking a slot, so a row scrolled away before its
/// turn costs nothing. Each successful `acquire` must be paired with one `release`.
public final class AsyncSlots: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var active = 0
    private var nextWaiter = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func acquire() async throws {
        let id = takeWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Under the lock, so a cancellation either lands before this check (and
                // throws here) or finds the waiter queued (and throws there).
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if active < limit {
                    active += 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let index = self.waiters.firstIndex(where: { $0.id == id })
            let waiter = index.map { self.waiters.remove(at: $0).continuation }
            self.lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func takeWaiterID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextWaiter += 1
        return nextWaiter
    }

    /// Hands the slot to the longest waiter, or frees it.
    public func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            active = max(0, active - 1)
            lock.unlock()
            return
        }
        let next = waiters.removeFirst().continuation
        lock.unlock()
        next.resume()
    }

    /// Slots held right now.
    public var inUse: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}
