import XCTest
@testable import HerdrKit

/// Review P2 (herdrup#339): the owner can flip Share Gram faster than `guest.update` answers;
/// the daemon must end on the last choice.
@MainActor
final class LatestValueSenderTests: XCTestCase {

    /// A daemon whose answers the test releases one at a time, recording what it was sent.
    private final class HeldDaemon {
        private(set) var received: [Bool] = []
        private var waiting: [CheckedContinuation<Void, Error>] = []
        var refuse: Set<Int> = []

        func send(_ value: Bool) async throws {
            received.append(value)
            let index = received.count - 1
            try await withCheckedThrowingContinuation { waiting.append($0) }
            if refuse.contains(index) { throw URLError(.badServerResponse) }
        }

        var pendingAnswers: Int { waiting.count }

        func answer() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testQuickFlipsEndOnTheLastChoiceWithOneRequestInFlight() async {
        let daemon = HeldDaemon()
        let sender = LatestValueSender<String, Bool>()

        let first = Task { await sender.submit(true, for: "g1", send: daemon.send) }
        await settle()
        XCTAssertEqual(daemon.received, [true])
        // Off, on, off while the first request is still out.
        let queued = await [false, true, false].asyncMap { value in
            await sender.submit(value, for: "g1", send: daemon.send)
        }
        XCTAssertEqual(queued, [.queued, .queued, .queued], "flips made meanwhile wait their turn")
        XCTAssertEqual(daemon.received, [true], "never two requests at once")
        XCTAssertEqual(sender.pending("g1"), false, "the switch shows the last choice")

        daemon.answer()
        await settle()
        XCTAssertEqual(daemon.received, [true, false], "only the last choice follows")
        daemon.answer()
        let outcome = await first.value
        XCTAssertEqual(outcome, .finished(failed: false))
        XCTAssertEqual(daemon.received.last, false, "the daemon ends on the owner's final off")
        XCTAssertNil(sender.pending("g1"))
    }

    func testAFlipBackToWhatIsInFlightSendsNothingMore() async {
        let daemon = HeldDaemon()
        let sender = LatestValueSender<String, Bool>()
        let first = Task { await sender.submit(true, for: "g1", send: daemon.send) }
        await settle()
        _ = await sender.submit(false, for: "g1", send: daemon.send)
        _ = await sender.submit(true, for: "g1", send: daemon.send)
        daemon.answer()
        let outcome = await first.value
        XCTAssertEqual(outcome, .finished(failed: false))
        XCTAssertEqual(daemon.received, [true])
    }

    func testGuestsAreIndependentAndARefusedLastValueIsReported() async {
        let daemon = HeldDaemon()
        daemon.refuse = [1]
        let sender = LatestValueSender<String, Bool>()
        let a = Task { await sender.submit(true, for: "g1", send: daemon.send) }
        await settle()
        let b = Task { await sender.submit(true, for: "g2", send: daemon.send) }
        await settle()
        XCTAssertEqual(daemon.pendingAnswers, 2, "another guest's update doesn't wait")
        daemon.answer()
        daemon.answer()
        let outcomeA = await a.value
        let outcomeB = await b.value
        XCTAssertEqual(outcomeA, .finished(failed: false))
        XCTAssertEqual(outcomeB, .finished(failed: true))
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}
