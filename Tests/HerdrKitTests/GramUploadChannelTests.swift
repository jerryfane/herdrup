import XCTest

@testable import HerdrKit

/// The upload channel's teardown is the one part of this path with a deadline, and
/// a deadline is only worth having if it is provable. The bound exists because the
/// runner finishes only when NIOSSH succeeds a close promise that waits for the
/// peer's CHANNEL_CLOSE — no timer, and not interruptible by task cancellation — so
/// a stalled link would otherwise park the caller for the kernel's whole retransmit
/// budget and wedge the composer.
///
/// This mirrors `CitadelTransportTests.testConnectFailsWithinTheBudgetAgainstABlackHoleAddress`,
/// which shortens the same kind of unstructured race for the same reason.
final class GramUploadChannelTests: XCTestCase {
    /// A channel whose connection never resolves, so its runner can never finish.
    private func stalledChannel(closeGrace: UInt64) -> GramUploadChannel {
        GramUploadChannel(
            makeConnection: {
                // Far longer than any grace under test: this stands in for a
                // half-open TCP that neither completes nor errors.
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                throw CancellationError()
            },
            command: "true",
            openLine: #"{"id":"t","method":"gram.upload.stream","params":{"upload_id":"t"}}"#,
            closeGrace: closeGrace
        )
    }

    func testCloseAndWaitReturnsWithinItsGraceWhenTheRunnerNeverFinishes() async throws {
        let grace: UInt64 = 200_000_000  // 200 ms
        let channel = stalledChannel(closeGrace: grace)

        // `start()` parks until the open is acked, which never happens here — so it
        // runs detached, purely to spawn the runner `closeAndWait` must bound.
        let opening = Task { try? await channel.start() }
        // Give `start()` time to install the runner before closing.
        try await Task.sleep(nanoseconds: 50_000_000)

        let began = DispatchTime.now().uptimeNanoseconds
        await channel.closeAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        opening.cancel()
        XCTAssertLessThan(
            elapsed, grace * 20,
            "closeAndWait took \(elapsed / 1_000_000) ms against a \(grace / 1_000_000) ms grace — the bound is not holding")
    }

    /// Idempotence: a second close must not hang on an already-signalled gate, and
    /// the caller's `defer`-close runs after `closeAndWait` on every real path.
    func testCloseAndWaitIsIdempotentAndSurvivesAPlainClose() async throws {
        let channel = stalledChannel(closeGrace: 100_000_000)
        let opening = Task { try? await channel.start() }
        try await Task.sleep(nanoseconds: 50_000_000)

        await channel.closeAndWait()
        await channel.close()
        await channel.closeAndWait()

        opening.cancel()
    }

    /// A frame written after the channel is closed must fail rather than park on an
    /// ack that can never arrive.
    func testSendChunkAfterCloseFailsInsteadOfHanging() async throws {
        let channel = stalledChannel(closeGrace: 100_000_000)
        await channel.close()

        do {
            try await channel.sendChunk(offset: 0, dataBase64: "aGk=")
            XCTFail("sendChunk on a closed channel must throw")
        } catch let error as GramUploadChannel.ChannelError {
            XCTAssertEqual(error, .closedBeforeFrameAck)
        }
    }

    /// Every `upload_id` is distinct, since the daemon keys its staging file and its
    /// single-writer claim on it — a repeat would collide with a live upload.
    func testMintedUploadIDsAreDistinctAndSafePathComponents() {
        let ids = (0..<64).map { _ in HerdrClient.mintUploadID() }
        XCTAssertEqual(Set(ids).count, ids.count, "upload ids must not repeat")
        for id in ids {
            XCTAssertTrue(id.hasPrefix("app-"))
            XCTAssertTrue(
                id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" },
                "\(id) is not a safe single path component")
        }
    }
}
