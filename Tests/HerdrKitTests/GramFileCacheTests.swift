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
        let stored = GramFileCache.store(data, id: "msg-1", name: "report.pdf", mime: "application/pdf", in: root)
        XCTAssertNotNil(stored)

        let hit = try XCTUnwrap(
            GramFileCache.cached(id: "msg-1", in: root),
            "a file that was just stored must be found, or the open path re-downloads it")
        XCTAssertEqual(hit.name, "report.pdf", "the real name must survive, QuickLook shows it")
        XCTAssertEqual(
            hit.mime, "application/pdf",
            """
            the mime must survive too: the viewer routing ORs the extension test with a             mime test, so a hit that forgot it routed the second open differently from             the first — markdown formatted once, then raw source forever.
            """)
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

        let payloadDir = GramFileCache.directory(for: "msg-1", in: root)
            .appendingPathComponent("payload")
        let payloads = try FileManager.default
            .contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(payloads, [payloadDir.appendingPathComponent("new-name.txt")],
                       "a replaced entry must not leave the previous payload behind")

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
            "deleting a message must not leave its file readable on disk")
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
        XCTAssertEqual(dir.lastPathComponent, GramFileCache.key(for: hostile))
        XCTAssertFalse(dir.lastPathComponent.contains("."), "a digest key cannot contain path syntax")

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

    /// The findings this file exists for, after review. Each of these would have passed
    /// silently before, and each is a permanent defect once it happens, because a cache
    /// with no revalidation never refetches a bad entry.

    /// Distinct ids must never share a directory. The first key scheme mapped every
    /// unsafe scalar to "_", so all of these collapsed onto one entry and whichever
    /// stored last owned the bytes.
    func testIdsThatDifferOnlyInPunctuationOrLengthStayDistinct() throws {
        let ids = ["msg/1", "msg.1", "msg 1", "msg:1", "msg+1", "msg_1",
                   String(repeating: "a", count: 130) + "X",
                   String(repeating: "a", count: 130) + "Y"]
        for (index, id) in ids.enumerated() {
            GramFileCache.store(Data("payload-\(index)".utf8), id: id, name: "f.txt", in: root)
        }
        XCTAssertEqual(Set(ids.map { GramFileCache.key(for: $0) }).count, ids.count,
                       "two different ids produced the same cache key")
        for (index, id) in ids.enumerated() {
            let hit = try XCTUnwrap(GramFileCache.cached(id: id, in: root), "lost entry for \(id)")
            XCTAssertEqual(try Data(contentsOf: hit.url), Data("payload-\(index)".utf8),
                           "\(id) served another message's bytes")
        }
    }

    /// An interrupted write leaves a payload with no metadata. That must read as a MISS
    /// and download again, not as a truncated hit served forever.
    func testAnEntryWithoutMetadataIsAMiss() throws {
        GramFileCache.store(Data("complete".utf8), id: "msg-1", name: "f.txt", in: root)
        let dir = GramFileCache.directory(for: "msg-1", in: root)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))
        XCTAssertNil(GramFileCache.cached(id: "msg-1", in: root),
                     "a half-written entry must not be served")
    }

    /// The recorded size is the integrity gate: a payload truncated after the fact is
    /// discarded rather than presented.
    func testATruncatedPayloadIsNotServed() throws {
        GramFileCache.store(Data(repeating: 0x41, count: 4096), id: "msg-1", name: "f.bin", in: root)
        let hit = try XCTUnwrap(GramFileCache.cached(id: "msg-1", in: root))
        try Data(repeating: 0x41, count: 10).write(to: hit.url)
        XCTAssertNil(GramFileCache.cached(id: "msg-1", in: root),
                     "the size recorded at store time must be checked on every lookup")
    }

    func testRemoveAllClearsEveryEntry() {
        GramFileCache.store(Data("a".utf8), id: "one", name: "a.txt", in: root)
        GramFileCache.store(Data("b".utf8), id: "two", name: "b.txt", in: root)
        GramFileCache.removeAll(in: root)
        XCTAssertNil(GramFileCache.cached(id: "one", in: root))
        XCTAssertNil(GramFileCache.cached(id: "two", in: root))
        XCTAssertEqual(GramFileCache.totalBytes(in: root), 0)
    }

    /// An attachment is free to be named `meta.json`: safeFileName only strips directory
    /// parts. When the payload sat beside the metadata, the metadata write destroyed the
    /// file and the reader's first open previewed the cache's own JSON.
    func testAnAttachmentNamedLikeTheMetadataStillRoundTrips() throws {
        let bytes = Data("the real attachment".utf8)
        XCTAssertNotNil(GramFileCache.store(bytes, id: "msg-1", name: "meta.json",
                                            mime: "application/json", in: root))
        let hit = try XCTUnwrap(GramFileCache.cached(id: "msg-1", in: root))
        XCTAssertEqual(hit.name, "meta.json")
        XCTAssertEqual(try Data(contentsOf: hit.url), bytes,
                       "the payload must survive: the reader tapped an attachment, not the cache's metadata")
    }
}
