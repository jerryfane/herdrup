import Foundation
@testable import HerdrKit
import XCTest

/// `GramDownloadStore` (#574): the reader's own Gram download outlives the page that waited
/// on it, and ends only when it lands, fails, or is cancelled (the reader's cancel, the
/// session's end). The transfer is a scripted closure held open until the test finishes,
/// fails or cancels it, so lifetimes are observed rather than raced.
@MainActor
final class GramDownloadStoreTests: XCTestCase {
    /// Transfers started, by message id, in order: a repeat is a download started again.
    private var started: [String] = []
    /// Transfers that saw their task cancelled.
    private var cancelled: [String] = []
    private var pending: [String: CheckedContinuation<GramDownloadStore.Fetched, Error>] = [:]
    private var reporters: [String: GramDownloadStore.Report] = [:]

    private struct Refused: Error {}

    private func transfer(_ id: String) -> GramDownloadStore.Transfer {
        { [unowned self] report in
            started.append(id)
            reporters[id] = report
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        cancelled.append(id)
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pending[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancelTransfer(id) }
            }
        }
    }

    private func cancelTransfer(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancelled.append(id)
        continuation.resume(throwing: CancellationError())
    }

    /// Lands the transfer for `id`, once it is in flight.
    private func finish(_ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        await until("\(id) is in flight", file: file, line: line) { pending[id] != nil }
        pending.removeValue(forKey: id)?.resume(returning: ("\(id).zip", "application/zip", Data(id.utf8), nil))
    }

    /// Fails the transfer for `id`, once it is in flight.
    private func fail(_ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        await until("\(id) is in flight", file: file, line: line) { pending[id] != nil }
        pending.removeValue(forKey: id)?.resume(throwing: Refused())
    }

    /// The page's wait on a download, as `GramView` runs it: a task the page cancels when it
    /// goes off screen.
    private func page(_ store: GramDownloadStore, _ id: String) -> Task<GramDownloadStore.Fetched?, Error> {
        Task { @MainActor in try await store.join(id: id) }
    }

    /// A card's image prefetch: a task the card cancels when it scrolls away.
    private func prefetch(_ store: GramDownloadStore, _ id: String) -> Task<GramDownloadStore.Fetched, Error> {
        Task { @MainActor in try await store.fetch(id: id, transfer: transfer(id)) }
    }

    private func isCancellation<T: Sendable>(_ task: Task<T, Error>) async -> Bool {
        do {
            _ = try await task.value
            return false
        } catch {
            return error is CancellationError
        }
    }

    /// Lets the store's tasks run until `condition` holds (2 s at most).
    private func until(
        _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        var tries = 0
        while !condition(), tries < 2000 {
            tries += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// A short settle, for asserting something did NOT happen.
    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// The bug: leaving Gram (a tab switch) cancelled the page's wait, and with it the
    /// download. Now the wait ends and the download does not; the page coming back joins
    /// the SAME transfer and gets the file when it lands.
    func testTheReadersDownloadOutlivesThePageThatWaitedOnIt() async throws {
        let store = GramDownloadStore()
        XCTAssertTrue(store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2")))
        await until("the open starts its transfer") { started == ["g2"] }
        XCTAssertEqual(store.held?.id, "g2")
        XCTAssertEqual(store.held?.purpose, .open)

        let first = page(store, "g2")
        await settle()
        first.cancel()
        let firstCancelled = await isCancellation(first)
        XCTAssertTrue(firstCancelled, "the page's wait ends with the page")
        await settle()
        XCTAssertEqual(cancelled, [], "the download does not")
        XCTAssertTrue(store.isRunning("g2"))
        XCTAssertEqual(store.held?.id, "g2", "its ring is still there for the page to draw")

        let back = page(store, "g2")
        await settle()
        await finish("g2")
        let fetched = try await back.value
        XCTAssertEqual(fetched?.name, "g2.zip", "the page that came back gets the file")
        XCTAssertEqual(started, ["g2"], "from the one transfer: nothing started again")
        XCTAssertNil(store.held, "the ring goes when the file lands")
        XCTAssertFalse(store.isRunning("g2"))
        let after = try await store.join(id: "g2")
        XCTAssertNil(after, "nothing to join once it has landed: the file is in the cache")
    }

    /// A download that lands with no page waiting (the reader is on Agents) just ends: the
    /// transfer's own cache write is what the next open finds.
    func testADownloadLandsWithNoPageWaiting() async {
        let store = GramDownloadStore()
        store.start(id: "g2", purpose: .save, expectedBytes: nil, transfer: transfer("g2"))
        await until("the save starts its transfer") { started == ["g2"] }
        await finish("g2")
        await until("its ring goes") { store.held == nil }
        XCTAssertFalse(store.isRunning("g2"))
        XCTAssertEqual(cancelled, [])
    }

    /// The image prefetch is the card's while it is on screen: scrolled away, it stops.
    func testAPrefetchEndsWhenItsLastWaiterLeaves() async {
        let store = GramDownloadStore()
        let card = prefetch(store, "g3")
        await until("the card's prefetch starts") { started == ["g3"] }
        XCTAssertNil(store.held, "a prefetch draws no ring")
        card.cancel()
        let cardCancelled = await isCancellation(card)
        XCTAssertTrue(cardCancelled)
        await until("the last waiter out cancels the transfer") { cancelled == ["g3"] }
        XCTAssertFalse(store.isRunning("g3"))
    }

    /// Opening an image the feed is prefetching joins that transfer, and from then on it is
    /// the reader's: the card scrolling away no longer ends it.
    func testAnOpenAdoptsTheRunningPrefetchAndKeepsIt() async throws {
        let store = GramDownloadStore()
        let card = prefetch(store, "g3")
        await until("the card's prefetch starts") { started == ["g3"] }
        XCTAssertTrue(store.start(id: "g3", purpose: .open, expectedBytes: nil, transfer: transfer("g3")))
        let waiting = page(store, "g3")
        card.cancel()
        let cardCancelled = await isCancellation(card)
        XCTAssertTrue(cardCancelled)
        await settle()
        XCTAssertEqual(cancelled, [], "the open keeps the transfer it adopted")
        XCTAssertEqual(started, ["g3"], "and never started a second")

        await finish("g3")
        let fetched = try await waiting.value
        XCTAssertEqual(fetched?.name, "g3.zip")
        XCTAssertNil(store.held)
    }

    /// One open or save at a time, as the page has always allowed.
    func testOnlyOneHeldDownloadAtATime() async {
        let store = GramDownloadStore()
        XCTAssertTrue(store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2")))
        XCTAssertFalse(store.start(id: "g5", purpose: .save, expectedBytes: nil, transfer: transfer("g5")))
        await settle()
        XCTAssertEqual(started, ["g2"], "the refused one starts nothing")
        XCTAssertEqual(store.held?.id, "g2")
        await finish("g2")
        await until("the slot frees when the first lands") { store.held == nil }
        XCTAssertTrue(store.start(id: "g5", purpose: .save, expectedBytes: nil, transfer: transfer("g5")))
        await until("then the next may start") { started == ["g2", "g5"] }
        await finish("g5")
    }

    /// The reader's cancel ends the download for everyone waiting on it, and the ring goes;
    /// a later open starts afresh.
    func testCancelEndsTheDownloadAndEveryWaiter() async {
        let store = GramDownloadStore()
        store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2"))
        await until("the open starts") { started == ["g2"] }
        let waiting = page(store, "g2")
        await settle()
        store.cancel(id: "g2")
        XCTAssertNil(store.held, "the ring goes at once")
        XCTAssertFalse(store.isRunning("g2"))
        let waitingCancelled = await isCancellation(waiting)
        XCTAssertTrue(waitingCancelled, "the page's wait ends")
        await until("and the transfer itself is cancelled") { cancelled == ["g2"] }

        XCTAssertTrue(store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2")))
        await until("a new open starts a new transfer") { started == ["g2", "g2"] }
        XCTAssertEqual(store.held?.id, "g2")
        await finish("g2")
        await until("which lands") { store.held == nil }
    }

    /// Disconnect and sign-out end every transfer: the reader's download and any prefetch.
    func testCancelAllEndsEveryTransfer() async {
        let store = GramDownloadStore()
        store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2"))
        let card = prefetch(store, "g3")
        await until("both run") { Set(started) == ["g2", "g3"] }
        let waiting = page(store, "g2")
        await settle()

        store.cancelAll()
        XCTAssertNil(store.held)
        XCTAssertFalse(store.isRunning("g2"))
        XCTAssertFalse(store.isRunning("g3"))
        let waitingCancelled = await isCancellation(waiting)
        let cardCancelled = await isCancellation(card)
        XCTAssertTrue(waitingCancelled)
        XCTAssertTrue(cardCancelled)
        await until("both transfers are cancelled") { Set(cancelled) == ["g2", "g3"] }
    }

    /// A failed download reaches the page waiting on it and clears the ring.
    func testAFailureReachesTheWaiterAndClearsTheRing() async {
        let store = GramDownloadStore()
        store.start(id: "g2", purpose: .open, expectedBytes: nil, transfer: transfer("g2"))
        await until("the open starts") { started == ["g2"] }
        let waiting = page(store, "g2")
        await settle()
        await fail("g2")
        do {
            _ = try await waiting.value
            XCTFail("the failure should reach the page")
        } catch {
            XCTAssertTrue(error is Refused, "the transfer's own error, not a cancellation: \(error)")
        }
        XCTAssertNil(store.held)
        XCTAssertFalse(store.isRunning("g2"))
        XCTAssertNil(store.takeFailure(), "the page that waited reported it; nothing is kept")
    }

    /// A download that fails while the reader is on Agents is kept for the page to report
    /// when it comes back, once; a card's prefetch waiting on it does not count as a page.
    func testAFailureWhileAwayIsKeptForThePageOnce() async {
        let store = GramDownloadStore()
        let card = prefetch(store, "g3")
        await until("the card's prefetch starts") { started == ["g3"] }
        store.start(id: "g3", purpose: .save, expectedBytes: nil, transfer: transfer("g3"))
        await fail("g3")
        let cardCancelled = await isCancellation(card)
        XCTAssertFalse(cardCancelled, "the card gets the failure")
        await until("the ring goes") { store.held == nil }
        let failure = store.takeFailure()
        XCTAssertEqual(failure?.id, "g3")
        XCTAssertEqual(failure?.purpose, .save)
        XCTAssertTrue(failure?.error is Refused)
        XCTAssertNil(store.takeFailure(), "reported once")
    }

    /// Disconnect, reconnect and session switch all reset this root-owned store. An error
    /// from a download that failed on Agents belongs to that connection, not the next one.
    func testConnectionResetDiscardsAFailureWhileAway() async {
        let store = GramDownloadStore()
        store.start(id: "old-session-file", purpose: .save, expectedBytes: nil,
                    transfer: transfer("old-session-file"))
        await until("the hidden page's download starts") { started == ["old-session-file"] }
        await fail("old-session-file")
        await until("the failed download has ended") { store.held == nil }

        store.cancelAll()

        XCTAssertNil(store.takeFailure(), "returning to Gram must not report the previous connection's failure")
    }

    /// The ring's progress: the held download's only, whole percents, never backwards, and
    /// never past the end.
    func testProgressDrawsOnlyTheHeldDownloadAndNeverRunsBackwards() async {
        let store = GramDownloadStore()
        let card = prefetch(store, "g3")
        store.start(id: "g2", purpose: .open, expectedBytes: 1000, transfer: transfer("g2"))
        await until("both run") { reporters["g2"] != nil && reporters["g3"] != nil }
        XCTAssertNil(store.held?.progress, "nil until the transport reports a byte")

        reporters["g3"]?(700)
        await settle()
        XCTAssertNil(store.held?.progress, "a prefetch nobody opened draws on no ring")

        reporters["g2"]?(500)
        await until("the open's bytes draw") { store.held?.progress?.received == 500 }
        XCTAssertEqual(store.held?.progress?.total, 1000)
        reporters["g2"]?(300)
        reporters["g2"]?(505)
        await settle()
        XCTAssertEqual(store.held?.progress?.received, 500, "never backwards, nor under a percent at a time")
        reporters["g2"]?(1400)
        await until("the last chunk always lands, clamped to the end") { store.held?.progress?.received == 1000 }

        await finish("g2")
        card.cancel()
        await until("the ring goes") { store.held == nil }
    }
}
