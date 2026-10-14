import XCTest
@testable import HerdrKit

/// The feed downloads pictures unasked; these are the bounds on that.
final class GramImagePreviewTests: XCTestCase {

    private func file(mime: String, size: UInt64) throws -> GramFile {
        let json = #"{"name":"f","size":\#(size),"mime":"\#(mime)","sha256":""}"#
        return try JSONDecoder().decode(GramFile.self, from: Data(json.utf8))
    }

    func testOnlyImagesUpToTheCapArePrefetched() throws {
        let cap = GramImagePreview.maxPrefetchBytes
        XCTAssertTrue(GramImagePreview.shouldPrefetch(try file(mime: "image/png", size: 421_888)))
        XCTAssertTrue(GramImagePreview.shouldPrefetch(try file(mime: "IMAGE/JPEG", size: cap)))
        XCTAssertFalse(GramImagePreview.shouldPrefetch(try file(mime: "image/png", size: cap + 1)),
                       "an image over the cap keeps its placeholder until opened")
        XCTAssertFalse(GramImagePreview.shouldPrefetch(try file(mime: "application/zip", size: 1_000)),
                       "a file that is not an image is never fetched unasked")
    }

    func testSlotsAdmitTheLimitThenQueueInOrder() async throws {
        let slots = AsyncSlots(limit: 2)
        try await slots.acquire()
        try await slots.acquire()
        XCTAssertEqual(slots.inUse, 2)

        let third = Task { try await slots.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(slots.inUse, 2, "the third waits while two hold a slot")

        slots.release()
        try await third.value
        XCTAssertEqual(slots.inUse, 2, "the freed slot passes straight to the waiter")
        slots.release()
        slots.release()
        XCTAssertEqual(slots.inUse, 0)
    }

    func testACancelledWaiterThrowsAndTakesNoSlot() async throws {
        let slots = AsyncSlots(limit: 1)
        try await slots.acquire()

        let waiter = Task { try await slots.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter must not get a slot")
        } catch is CancellationError {}

        slots.release()
        XCTAssertEqual(slots.inUse, 0, "the release frees the slot rather than handing it to the cancelled waiter")
        try await slots.acquire()
        XCTAssertEqual(slots.inUse, 1)
    }

    func testAnAlreadyCancelledTaskDoesNotQueue() async {
        let slots = AsyncSlots(limit: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await slots.acquire()
        }
        do {
            try await task.value
            XCTFail("acquire in a cancelled task must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(slots.inUse, 0)
    }
}
