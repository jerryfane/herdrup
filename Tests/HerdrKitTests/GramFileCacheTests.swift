import XCTest
@testable import HerdrKit

/// The cache exists so a second open costs nothing. The defect it must never have is
/// SILENCE: a cache that stores but never finds behaves exactly like no cache, the
/// feature still looks implemented, and the only symptom is that the reader waits
/// again. So every test here asserts a lookup, not just a write.
final class GramFileCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-cache-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAStoredFileIsFoundAgainWithItsBytesAndName() throws {
        let data = Data("report contents".utf8)
        let stored = GramFileCache.store(data, id: "msg-1", name: "report.pdf", in: root)
        XCTAssertNotNil(stored)

        let hit = try XCTUnwrap(
            GramFileCache.cached(id: "msg-1", in: root),
            "a file that was just stored must be found, or the open path re-downloads it")
        XCTAssertEqual(hit.name, "report.pdf", "the real name must survive, QuickLook shows it")
        XCTAssertEqual(hit.size, data.count)
        XCTAssertEqual(try Data(contentsOf: hit.url), data)
    }

    func testAMessageNeverDownloadedIsAMiss() {
        XCTAssertNil(GramFileCache.cached(id: "never-fetched", in: root))
    }

    /// Two messages can ship files with the same name; neither may serve the other's
    /// bytes. This is the reason entries are per-id directories rather than flat files.
    func testSameFileNameUnderDifferentMessagesDoesNotCollide() throws {
        GramFileCache.store(Data("first".utf8), id: "msg-a", name: "notes.txt", in: root)
        GramFileCache.store(Data("second".utf8), id: "msg-b", name: "notes.txt", in: root)

        let a = try XCTUnwrap(GramFileCache.cached(id: "msg-a", in: root))
        let b = try XCTUnwrap(GramFileCache.cached(id: "msg-b", in: root))
        XCTAssertEqual(try Data(contentsOf: a.url), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: b.url), Data("second".utf8))
    }

    func testStoringAgainReplacesTheEarlierCopyRatherThanAccumulating() throws {
        GramFileCache.store(Data("old".utf8), id: "msg-1", name: "old-name.txt", in: root)
        GramFileCache.store(Data("new bytes".utf8), id: "msg-1", name: "new-name.txt", in: root)

        let dir = GramFileCache.directory(for: "msg-1", in: root)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "a replaced entry must not leave the previous file behind")

        let hit = try XCTUnwrap(GramFileCache.cached(id: "msg-1", in: root))
        XCTAssertEqual(hit.name, "new-name.txt")
        XCTAssertEqual(try Data(contentsOf: hit.url), Data("new bytes".utf8))
    }

    func testRemovingAMessageDropsItsBytes() throws {
        GramFileCache.store(Data("secret".utf8), id: "msg-1", name: "s.txt", in: root)
        XCTAssertNotNil(GramFileCache.cached(id: "msg-1", in: root))

        GramFileCache.remove(id: "msg-1", in: root)
        XCTAssertNil(
            GramFileCache.cached(id: "msg-1", in: root),
            "deleting or unsaving a message must not leave its file readable on disk")
    }

    /// An id is an opaque daemon string. A traversal attempt must land inside the root,
    /// not above it.
    func testAnIdContainingPathSeparatorsCannotEscapeTheCacheRoot() throws {
        let hostile = "../../etc/passwd"
        let dir = GramFileCache.directory(for: hostile, in: root)
        XCTAssertEqual(
            dir.deletingLastPathComponent().standardizedFileURL.path,
            root.standardizedFileURL.path,
            "the entry directory must be a direct child of the cache root")

        GramFileCache.store(Data("x".utf8), id: hostile, name: "p.txt", in: root)
        let hit = try XCTUnwrap(GramFileCache.cached(id: hostile, in: root))
        XCTAssertTrue(hit.url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path))
    }

    func testEvictionKeepsTheCacheUnderItsCeiling() throws {
        // 4 KB each, ceiling 10 KB: storing three must drop at least one.
        let chunk = Data(repeating: 0x41, count: 4 * 1024)
        for id in ["one", "two", "three"] {
            GramFileCache.store(chunk, id: id, name: "\(id).bin", in: root, maxBytes: 10 * 1024)
        }
        XCTAssertLessThanOrEqual(GramFileCache.totalBytes(in: root), 10 * 1024)
    }

    /// Eviction order is least-RECENTLY-USED, so the file the reader keeps opening
    /// survives. Without the touch-on-read this test fails: "one" would be the oldest
    /// stored entry and would be evicted despite being the one in use.
    func testTheMostRecentlyOpenedEntrySurvivesEviction() throws {
        let chunk = Data(repeating: 0x42, count: 4 * 1024)
        GramFileCache.store(chunk, id: "one", name: "one.bin", in: root, maxBytes: 10 * 1024)
        // Distinguish the touch timestamps: filesystem mtime granularity is coarse.
        Thread.sleep(forTimeInterval: 1.1)
        GramFileCache.store(chunk, id: "two", name: "two.bin", in: root, maxBytes: 10 * 1024)

        // Re-open "one", making "two" the least recently used.
        XCTAssertNotNil(GramFileCache.cached(id: "one", in: root))
        Thread.sleep(forTimeInterval: 1.1)

        GramFileCache.store(chunk, id: "three", name: "three.bin", in: root, maxBytes: 10 * 1024)
        XCTAssertNotNil(
            GramFileCache.cached(id: "one", in: root),
            "the entry the reader just opened must not be the one evicted")
        XCTAssertNil(GramFileCache.cached(id: "two", in: root))
    }

    func testAFileLargerThanTheWholeBudgetIsNotCached() {
        let big = Data(repeating: 0x43, count: 8 * 1024)
        XCTAssertNil(
            GramFileCache.store(big, id: "huge", name: "huge.bin", in: root, maxBytes: 4 * 1024),
            "caching it would evict everything else and then itself")
        XCTAssertNil(GramFileCache.cached(id: "huge", in: root))
    }

    func testEmptyBytesAreNotCached() {
        XCTAssertNil(GramFileCache.store(Data(), id: "empty", name: "e.txt", in: root))
        XCTAssertNil(GramFileCache.cached(id: "empty", in: root))
    }
}
