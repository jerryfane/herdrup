import XCTest
@testable import HerdrKit

/// Settings → Typing latency: the recorder's attribution rules and summaries, driven by a
/// fake clock so every interval is exact.
final class TypingLatencyTests: XCTestCase {

    /// A clock the test advances by hand.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        var now: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(ms: Double) {
            lock.lock(); value += ms / 1000; lock.unlock()
        }
    }

    private func makeRecorder() -> (TypingLatencyRecorder, FakeClock) {
        let clock = FakeClock()
        let recorder = TypingLatencyRecorder(clock: { clock.now })
        recorder.begin(host: "mac-mini", network: "Wi-Fi")
        return (recorder, clock)
    }

    private func only(_ recorder: TypingLatencyRecorder, file: StaticString = #filePath,
                      line: UInt = #line) throws -> TypingLatencyReport {
        let reports = recorder.report()
        XCTAssertEqual(reports.count, 1, file: file, line: line)
        return try XCTUnwrap(reports.first, file: file, line: line)
    }

    // (a)
    func testSingleKeyRecordsEveryStageFromItsPress() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        clock.advance(ms: 5)
        recorder.batchSent(byteCount: 1)
        clock.advance(ms: 40)
        recorder.outputArrived()        // echo before the send returns, as on a fast link
        clock.advance(ms: 10)
        recorder.batchAcked()
        clock.advance(ms: 16)
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertEqual(try XCTUnwrap(report.queueWait).median, 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToEcho).median, 45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToAck).median, 55, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToPaint).median, 71, accuracy: 0.001)
        XCTAssertEqual(report.meanBatchSize, 1, accuracy: 0.001)
    }

    func testKeyIsNotASampleUntilItIsPaintedAndAcked() {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1)
        clock.advance(ms: 30)
        recorder.outputArrived()
        recorder.painted()
        XCTAssertTrue(recorder.report().isEmpty, "the send has not returned yet")
        recorder.batchAcked()
        XCTAssertEqual(recorder.report().first?.count, 1)
    }

    // (b)
    func testKeysInOneBatchShareStampsButKeepTheirOwnPressTime() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()           // t = 0
        clock.advance(ms: 20)
        recorder.keyPressed()           // t = 20
        clock.advance(ms: 10)
        recorder.batchSent(byteCount: 2) // t = 30
        clock.advance(ms: 50)
        recorder.batchAcked()           // t = 80
        recorder.outputArrived()        // t = 80
        clock.advance(ms: 20)
        recorder.painted()              // t = 100

        let report = try only(recorder)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.meanBatchSize, 2, accuracy: 0.001)
        XCTAssertEqual(report.meanBatchBytes, 2, accuracy: 0.001)
        let paint = try XCTUnwrap(report.keyToPaint)
        // Totals measured from each key's own press: 100 ms and 80 ms.
        XCTAssertEqual(paint.max, 100, accuracy: 0.001)
        XCTAssertEqual(paint.median, 80, accuracy: 0.001)
        let wait = try XCTUnwrap(report.queueWait)
        XCTAssertEqual(wait.max, 30, accuracy: 0.001)
        XCTAssertEqual(wait.median, 10, accuracy: 0.001)
    }

    func testAKeyPressedDuringASendWaitsForTheNextBatch() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1)
        clock.advance(ms: 10)
        recorder.keyPressed()           // typed while the first send is in flight
        clock.advance(ms: 40)
        recorder.batchAcked()           // must not ack the unsent second key
        recorder.batchSent(byteCount: 1)
        clock.advance(ms: 30)
        recorder.batchAcked()
        recorder.outputArrived()
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.meanBatchSize, 1, accuracy: 0.001)
        let ack = try XCTUnwrap(report.keyToAck)
        // First key acked at 50 ms; second pressed at 10, acked at 80 → 70 ms.
        XCTAssertEqual(ack.median, 50, accuracy: 0.001)
        XCTAssertEqual(ack.max, 70, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.queueWait).max, 40, accuracy: 0.001)
    }

    // (c)
    func testOutputBeforeTheKeyIsSentIsNotItsEcho() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        clock.advance(ms: 10)
        recorder.outputArrived()        // the agent's own output, not this key
        recorder.painted()
        clock.advance(ms: 10)
        recorder.batchSent(byteCount: 1)
        recorder.batchAcked()
        XCTAssertTrue(recorder.report().isEmpty, "an unsent key must not take earlier output as echo")

        clock.advance(ms: 30)
        recorder.outputArrived()
        clock.advance(ms: 10)
        recorder.painted()
        let report = try only(recorder)
        XCTAssertEqual(try XCTUnwrap(report.keyToEcho).median, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.keyToPaint).median, 60, accuracy: 0.001)
    }

    // (d)
    func testUnechoedKeyOlderThanTheWindowIsDroppedAndCounted() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1)
        recorder.batchAcked()
        clock.advance(ms: 2_100)
        recorder.outputArrived()        // far too late to be this key's echo
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.count, 0)
        XCTAssertEqual(report.dropped, 1)
        XCTAssertNil(report.keyToPaint)
    }

    func testKeyQueuedLongBehindASlowSendIsStillMeasured() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()               // sits in the queue behind a 2.3 s send
        clock.advance(ms: 2_300)
        recorder.outputArrived()            // the earlier batch's echo: not this key's
        recorder.batchSent(byteCount: 1)
        clock.advance(ms: 100)
        recorder.outputArrived()
        recorder.batchAcked()
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(try XCTUnwrap(report.keyToPaint).max, 2_400, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(report.queueWait).max, 2_300, accuracy: 0.5)
    }

    func testFailedSendCountsItsKeysAsLostNotMeasured() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 2)
        recorder.batchAcked(failed: true)
        recorder.keyPressed()           // typed after the failure: still measured normally
        clock.advance(ms: 5)
        recorder.batchSent(byteCount: 1)
        recorder.outputArrived()
        recorder.batchAcked()
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.lost, 2)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.dropped, 0)
        XCTAssertTrue(report.plainLines().contains("2 keys lost: their send failed"))
    }

    func testKeyEchoedInsideTheWindowIsKept() throws {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1)
        recorder.batchAcked()
        clock.advance(ms: 1_900)
        recorder.outputArrived()
        recorder.painted()

        let report = try only(recorder)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.dropped, 0)
    }

    // (e)
    func testMedianAndP90UseNearestRank() throws {
        let stats = try XCTUnwrap(TypingLatencyStats(seconds: (1...10).map { Double($0) / 1000 }.reversed()))
        XCTAssertEqual(stats.median, 5, accuracy: 0.001)
        XCTAssertEqual(stats.p90, 9, accuracy: 0.001)
        XCTAssertEqual(stats.max, 10, accuracy: 0.001)
        XCTAssertNil(TypingLatencyStats(seconds: []))

        let single = try XCTUnwrap(TypingLatencyStats(seconds: [0.042]))
        XCTAssertEqual(single.median, 42, accuracy: 0.001)
        XCTAssertEqual(single.p90, 42, accuracy: 0.001)
    }

    func testReportSummarisesRecordedKeys() throws {
        let (recorder, clock) = makeRecorder()
        // Ten keys, painted 10, 20, … 100 ms after their press.
        for paintMs in stride(from: 10.0, through: 100, by: 10) {
            recorder.keyPressed()
            recorder.batchSent(byteCount: 1)
            recorder.batchAcked()
            recorder.outputArrived()
            clock.advance(ms: paintMs)
            recorder.painted()
            clock.advance(ms: 500)
        }
        let paint = try XCTUnwrap(try only(recorder).keyToPaint)
        XCTAssertEqual(paint.median, 50, accuracy: 0.001)
        XCTAssertEqual(paint.p90, 90, accuracy: 0.001)
        XCTAssertEqual(paint.max, 100, accuracy: 0.001)
    }

    // (f)
    func testReportSeparatesHostsAndNetworks() throws {
        let (recorder, clock) = makeRecorder()
        func typeKey(paintAfterMs ms: Double) {
            recorder.keyPressed()
            recorder.batchSent(byteCount: 1)
            recorder.batchAcked()
            recorder.outputArrived()
            clock.advance(ms: ms)
            recorder.painted()
        }
        recorder.setLabel("mac-mini", forHost: "192.168.1.20")
        recorder.noteRoute(host: "192.168.1.20", held: true)
        recorder.noteRoute(host: "192.168.1.20", held: true)
        recorder.noteRoute(host: "192.168.1.20", held: false)
        recorder.noteRoute(host: "hetzner", held: false)

        typeKey(paintAfterMs: 30)                    // mac-mini, Wi-Fi
        recorder.begin(host: "mac-mini", network: "cellular")
        typeKey(paintAfterMs: 200)
        typeKey(paintAfterMs: 220)
        recorder.begin(host: "hetzner", network: "Wi-Fi")
        typeKey(paintAfterMs: 90)

        let reports = recorder.report()
        XCTAssertEqual(reports.map(\.host), ["hetzner", "mac-mini", "mac-mini"])
        XCTAssertEqual(reports.map(\.network), ["Wi-Fi", "Wi-Fi", "cellular"])
        let byKey = Dictionary(uniqueKeysWithValues: reports.map { ("\($0.host)/\($0.network)", $0) })
        XCTAssertEqual(byKey.count, 3)

        let macWifi = try XCTUnwrap(byKey["mac-mini/Wi-Fi"])
        XCTAssertEqual(macWifi.count, 1)
        XCTAssertEqual(try XCTUnwrap(macWifi.keyToPaint).median, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(macWifi.heldShare), 2.0 / 3.0, accuracy: 0.001)

        let macCell = try XCTUnwrap(byKey["mac-mini/cellular"])
        XCTAssertEqual(macCell.count, 2)
        XCTAssertEqual(try XCTUnwrap(macCell.keyToPaint).max, 220, accuracy: 0.001)
        XCTAssertEqual(macCell.heldRequests, 2, "route counts are per host, shared by its networks")

        let hetzner = try XCTUnwrap(byKey["hetzner/Wi-Fi"])
        XCTAssertEqual(hetzner.count, 1)
        XCTAssertEqual(try XCTUnwrap(hetzner.heldShare), 0, accuracy: 0.001)

        let text = recorder.reportText(appVersion: "1.4", build: "88")
        XCTAssertTrue(text.contains("app 1.4 (88)"))
        XCTAssertTrue(text.contains("mac-mini, cellular"))
        XCTAssertTrue(text.contains("Key to screen: 200 ms typical"))
    }

    func testResetForgetsEverything() {
        let (recorder, clock) = makeRecorder()
        recorder.keyPressed()
        recorder.batchSent(byteCount: 1)
        recorder.batchAcked()
        recorder.outputArrived()
        clock.advance(ms: 20)
        recorder.painted()
        recorder.noteRoute(host: "mac-mini", held: true)
        XCTAssertFalse(recorder.report().isEmpty)

        recorder.reset()
        XCTAssertTrue(recorder.report().isEmpty)
        XCTAssertTrue(recorder.reportText().contains("No typing measured yet."))
    }

    func testRingKeepsTheLastThousandSamplesPerContext() throws {
        let (recorder, clock) = makeRecorder()
        for _ in 0..<(TypingLatencyRecorder.ringCapacity + 5) {
            recorder.keyPressed()
            recorder.batchSent(byteCount: 1)
            recorder.batchAcked()
            recorder.outputArrived()
            clock.advance(ms: 10)
            recorder.painted()
        }
        XCTAssertEqual(try only(recorder).count, TypingLatencyRecorder.ringCapacity)
    }
}
