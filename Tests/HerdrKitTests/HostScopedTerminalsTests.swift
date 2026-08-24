import XCTest
@testable import HerdrKit

/// Per-host scoping of saved terminals: each host key keeps its own list (the phantom-terminal fix),
/// and the one-time legacy migration folds a pre-scoping flat list into the first host only.
final class HostScopedTerminalsTests: XCTestCase {

    func testTwoHostsKeepSeparateLists() {
        var book = HostScopedTerminals()
        book.add(paneID: "wA:p1", createdUnixMs: 1, host: "a:22")
        book.add(paneID: "wB:p1", createdUnixMs: 2, host: "b:22")

        XCTAssertEqual(book.terminals(host: "a:22").map(\.paneID), ["wA:p1"])
        XCTAssertEqual(book.terminals(host: "b:22").map(\.paneID), ["wB:p1"],
                       "host B must not see host A's terminal")
        XCTAssertTrue(book.terminals(host: "c:22").isEmpty, "an unseen host has no terminals")
    }

    func testRemoveAndRenameAreScopedToTheHost() {
        var book = HostScopedTerminals()
        let a = book.add(paneID: "wA:p1", createdUnixMs: 1, host: "a:22")
        book.add(paneID: "wB:p1", createdUnixMs: 2, host: "b:22")

        book.rename(id: a.id, to: "build logs", host: "a:22")
        XCTAssertEqual(book.terminals(host: "a:22").first?.label, "build logs")

        // Deleting on the wrong host is a no-op; on the right host it removes.
        book.remove(id: a.id, host: "b:22")
        XCTAssertEqual(book.terminals(host: "a:22").count, 1, "a delete keyed to the wrong host must not touch host A")
        book.remove(id: a.id, host: "a:22")
        XCTAssertTrue(book.terminals(host: "a:22").isEmpty)
        XCTAssertEqual(book.terminals(host: "b:22").count, 1, "host B is untouched throughout")
    }

    func testLegacyMigrationFoldsIntoTheFirstHostOnce() {
        var legacy = SavedTerminals()
        legacy.add(paneID: "wOld:p1", createdUnixMs: 1)
        legacy.add(paneID: "wOld:p2", createdUnixMs: 2)

        var book = HostScopedTerminals()
        XCTAssertTrue(book.migrateLegacy(legacy, into: "a:22"), "first host inherits the legacy list")
        XCTAssertEqual(book.terminals(host: "a:22").count, 2)

        // A second host does NOT get the legacy list again (the host already inherited it, and the
        // caller retires the blob). And a host that already has a bucket is never overwritten.
        XCTAssertFalse(book.migrateLegacy(legacy, into: "a:22"), "same host with a bucket is not re-migrated")
        XCTAssertTrue(book.terminals(host: "b:22").isEmpty, "host B starts clean")
    }

    func testMigrationOfAnEmptyLegacyIsANoOp() {
        var book = HostScopedTerminals()
        XCTAssertFalse(book.migrateLegacy(SavedTerminals(), into: "a:22"))
        XCTAssertTrue(book.terminals(host: "a:22").isEmpty)
    }

    func testHostKeyCanonicalizesSpellings() {
        XCTAssertEqual(HostKey.canonical(host: "Example.COM.", port: 22), "example.com:22")
        XCTAssertEqual(HostKey.canonical(host: "[2001:DB8::1]", port: 2222), "2001:db8::1:2222")
        XCTAssertEqual(HostKey.canonical(host: " 10.0.0.1 ", port: 22), "10.0.0.1:22")
        XCTAssertNotEqual(HostKey.canonical(host: "a", port: 22), HostKey.canonical(host: "a", port: 2200),
                          "different ports are different hosts")
    }

    func testBookRoundTripsThroughCodable() throws {
        var book = HostScopedTerminals()
        book.add(paneID: "wA:p1", createdUnixMs: 1, host: "a:22")
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(HostScopedTerminals.self, from: data)
        XCTAssertEqual(decoded, book)
    }
}
