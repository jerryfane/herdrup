import Foundation
import XCTest
@testable import HerdrKit

final class SerialDeadlineQueueTests: XCTestCase {

    /// Records what happened, in order, from any task.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    /// A job that never finishes and ignores cancellation, like a mermaid layout that never
    /// ends inside the web page. `release()` lets it go at the end of the test.
    private final class Hang: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: UnsafeContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// The stall the renderer had: one hung diagram must not leave every later one waiting.
    /// The hung job times out, the owner's cleanup runs before the next job starts, and the
    /// next job still runs and returns its result.
    func testAHungJobTimesOutAndTheNextJobStillRuns() async throws {
        let queue = SerialDeadlineQueue()
        let log = Log()
        let hang = Hang()
        defer { hang.release() }

        let first = Task {
            try await queue.run(timeout: 0.2, {
                log.add("first started")
                await hang.wait()
                log.add("first finished")
                return 1
            }, onTimeout: {
                log.add("first timed out")
            })
        }
        // Queued behind the hung job before it times out.
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = Task {
            try await queue.run(timeout: 5, {
                log.add("second started")
                return 2
            })
        }

        do {
            _ = try await first.value
            XCTFail("A job that never finishes must time out")
        } catch {
            XCTAssertEqual(error as? DeadlineExceeded, DeadlineExceeded())
        }
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(log.all, ["first started", "first timed out", "second started"])
    }

    func testJobsRunOneAtATimeInOrderAndKeepTheirResultsAndErrors() async throws {
        struct Boom: Error, Equatable {}
        let queue = SerialDeadlineQueue()
        let log = Log()
        let slow = Task {
            try await queue.run(timeout: 5, {
                log.add("slow started")
                try await Task.sleep(nanoseconds: 150_000_000)
                log.add("slow finished")
                return "slow"
            })
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let failing = Task {
            try await queue.run(timeout: 5, { () async throws -> String in
                log.add("failing started")
                throw Boom()
            })
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let fast = Task {
            try await queue.run(timeout: 5, {
                log.add("fast started")
                return "fast"
            })
        }

        let slowValue = try await slow.value
        XCTAssertEqual(slowValue, "slow")
        do {
            _ = try await failing.value
            XCTFail("The job's own error must reach its caller")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
        let fastValue = try await fast.value
        XCTAssertEqual(fastValue, "fast")
        XCTAssertEqual(log.all, ["slow started", "slow finished", "failing started", "fast started"])
    }
}
