import Foundation

/// A job in a `SerialDeadlineQueue` did not finish in its time.
public struct DeadlineExceeded: Error, Equatable {
    public init() {}
}

/// Runs async jobs one at a time, each with a time limit, so one job that never finishes
/// cannot stall every job queued behind it.
///
/// The Chat view's mermaid renderer (#523 item 1) draws diagrams one at a time in a single
/// web page. An agent-written diagram whose layout never ends would otherwise leave every
/// later diagram in the chat on its placeholder. When a job runs out of time its caller gets
/// `DeadlineExceeded`, the job's task is cancelled, and `onTimeout` runs BEFORE the next job
/// starts, so the owner can throw away whatever the stuck job was using (the renderer
/// replaces its web page). The stuck job itself may never return; nothing waits for it.
public final class SerialDeadlineQueue: @unchecked Sendable {
    private let lock = NSLock()
    /// Finishes when the last queued job has finished or timed out.
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(
        timeout: TimeInterval,
        _ job: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) async throws -> T {
        lock.lock()
        let previous = tail
        let current = Task<T, Error> {
            await previous?.value
            do {
                return try await Self.race(timeout: timeout, job)
            } catch let error as DeadlineExceeded {
                await onTimeout()
                throw error
            }
        }
        tail = Task { _ = try? await current.value }
        lock.unlock()
        return try await current.value
    }

    /// `job`'s result, or `DeadlineExceeded` after `timeout` seconds, whichever comes first.
    /// Returns on time even when the job ignores cancellation.
    static func race<T: Sendable>(timeout: TimeInterval,
                                  _ job: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.arm(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if Task.isCancelled { return }
                if gate.finish(.failure(DeadlineExceeded())) { gate.cancelWork() }
            }
            gate.work = Task {
                let result: Result<T, Error>
                do { result = .success(try await job()) } catch { result = .failure(error) }
                if gate.finish(result) { timer.cancel() }
            }
        }
    }
}

/// Resumes the caller exactly once, with whichever of the job and the timer finishes first.
private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var _work: Task<Void, Never>?
    private var cancelled = false

    var work: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return _work }
        set {
            lock.lock()
            _work = newValue
            let cancel = cancelled
            lock.unlock()
            if cancel { newValue?.cancel() }
        }
    }

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Resumes the caller if nobody has yet; true if this call did.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    func cancelWork() {
        lock.lock()
        cancelled = true
        let work = _work
        lock.unlock()
        work?.cancel()
    }
}
