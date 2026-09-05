import XCTest

@testable import HerdrKit

/// Staging is what the composer hands to the uploader, and it used to live in the
/// iOS-only app target where no CI job can run it — a dropped copy there produced
/// the same user-facing message as an unreadable file and shipped once. These tests
/// exist so that class of defect fails on Linux.
final class GramStagingTests: XCTestCase {
    private var session: URL!

    override func setUpWithError() throws {
        session = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-staging-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: session)
    }

    private func sourceFile(_ bytes: Data, name: String = "pick.bin") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// The property the composer depends on: the staged file holds the SOURCE BYTES.
    /// A staging step that creates the directory but never copies satisfies every
    /// other check the app makes and silently rejects every attachment.
    func testStagedFileHoldsTheSourceBytes() throws {
        let payload = Data((0..<(64 * 1024 + 7)).map { UInt8($0 % 251) })
        let source = try sourceFile(payload, name: "photo.heic")

        let staged = try XCTUnwrap(
            GramStaging.stageCopy(
                of: source, named: "photo.heic", in: session, maxBytes: 100 * 1024 * 1024),
            "an in-cap readable pick must stage")

        XCTAssertEqual(try Data(contentsOf: staged.url), payload)
        XCTAssertEqual(staged.size, payload.count)
        XCTAssertEqual(staged.url.lastPathComponent, "photo.heic")
        // The staged copy survives the source going away, which is the whole point:
        // PhotosUI deletes its export as soon as the import closure returns.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: staged.url), payload)
    }

    /// Each pick gets its own directory, so removing one chip cannot take another's
    /// bytes with it.
    func testEachPickGetsItsOwnDirectory() throws {
        let source = try sourceFile(Data("one".utf8))
        let first = try XCTUnwrap(
            GramStaging.stageCopy(of: source, named: "a.txt", in: session, maxBytes: 1024))
        let second = try XCTUnwrap(
            GramStaging.stageCopy(of: source, named: "a.txt", in: session, maxBytes: 1024))

        XCTAssertNotEqual(first.dir, second.dir)
        try FileManager.default.removeItem(at: first.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    /// A rejected pick must leave NOTHING behind — otherwise every over-cap pick
    /// leaks a directory that only the next launch's sweep would reclaim.
    func testRejectedPicksLeaveNoDirectory() throws {
        let overCap = try sourceFile(Data(repeating: 9, count: 4096))
        XCTAssertNil(
            GramStaging.stageCopy(of: overCap, named: "big.bin", in: session, maxBytes: 1024))

        let empty = try sourceFile(Data())
        XCTAssertNil(
            GramStaging.stageCopy(of: empty, named: "empty.bin", in: session, maxBytes: 1024))

        let missing = session.appendingPathComponent("does-not-exist.bin")
        XCTAssertNil(
            GramStaging.stageCopy(of: missing, named: "gone.bin", in: session, maxBytes: 1024))

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: session, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers, [], "a rejected pick left staging behind: \(leftovers)")
    }


    /// The cap is INCLUSIVE, and that direction is the one worth pinning: a guard
    /// that refuses a file of exactly the allowed size fails silently — the pick just
    /// reports as "too large" — and the app's own gate uses the same `<=`, so an
    /// off-by-one here would reject a file the composer already accepted.
    func testExactlyMaxBytesStagesAndOneMoreDoesNot() throws {
        let cap = 8 * 1024
        let atCap = try sourceFile(Data(repeating: 3, count: cap), name: "at-cap.bin")
        let staged = try XCTUnwrap(
            GramStaging.stageCopy(of: atCap, named: "at-cap.bin", in: session, maxBytes: cap),
            "a file of exactly maxBytes must stage")
        XCTAssertEqual(staged.size, cap)

        let overCap = try sourceFile(Data(repeating: 3, count: cap + 1), name: "over-cap.bin")
        XCTAssertNil(
            GramStaging.stageCopy(of: overCap, named: "over-cap.bin", in: session, maxBytes: cap),
            "one byte past maxBytes must be refused")

        // A single-byte file is the other boundary: `size > 0` must not reject it.
        let oneByte = try sourceFile(Data([7]), name: "tiny.bin")
        let tiny = try XCTUnwrap(
            GramStaging.stageCopy(of: oneByte, named: "tiny.bin", in: session, maxBytes: cap))
        XCTAssertEqual(tiny.size, 1)
    }
    /// A pick named `../../evil` must not stage outside its own directory.
    func testTraversalNameStaysInsideTheItemDirectory() throws {
        let source = try sourceFile(Data("x".utf8))
        let staged = try XCTUnwrap(
            GramStaging.stageCopy(
                of: source, named: "../../etc/passwd", in: session, maxBytes: 1024))

        XCTAssertEqual(staged.url.lastPathComponent, "passwd")
        XCTAssertEqual(staged.url.deletingLastPathComponent(), staged.dir)
        XCTAssertTrue(
            staged.dir.deletingLastPathComponent().path == session.path,
            "staged dir escaped the session directory: \(staged.dir)")
    }

    /// The sweep reclaims OTHER sessions and never the live one, which is what makes
    /// it safe to run at launch while a composer may already hold staged chips.
    func testSweepRemovesOtherSessionsAndKeepsTheCurrentOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-staging-sweep/\(UUID().uuidString)", isDirectory: true)
        let current = UUID().uuidString
        let abandoned = UUID().uuidString
        for name in [current, abandoned] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("staged".utf8).write(to: dir.appendingPathComponent("file.bin"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        GramStaging.sweepAbandoned(root: root, keeping: current)

        let remaining = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(remaining, [current])
    }

    /// A missing root is the first-launch case: the sweep must be a no-op, not a
    /// failure that a caller has to guard.
    func testSweepToleratesAMissingRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gram-staging-absent/\(UUID().uuidString)", isDirectory: true)
        GramStaging.sweepAbandoned(root: root, keeping: "whatever")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
