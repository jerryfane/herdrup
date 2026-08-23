import XCTest
@testable import HerdrKit

final class SavedTerminalsTests: XCTestCase {
    func testAddAutoLabelsSequentially() {
        var store = SavedTerminals()
        let a = store.add(paneID: "w:p1", createdUnixMs: 1)
        let b = store.add(paneID: "w:p2", createdUnixMs: 2)
        XCTAssertEqual(a.label, "Terminal 1")
        XCTAssertEqual(b.label, "Terminal 2")
        XCTAssertEqual(store.terminals.map(\.paneID), ["w:p1", "w:p2"])
    }

    func testDeleteThenAddReusesLowestFreeNumber() {
        var store = SavedTerminals()
        let a = store.add(paneID: "w:p1", createdUnixMs: 1) // Terminal 1
        _ = store.add(paneID: "w:p2", createdUnixMs: 2)     // Terminal 2
        store.remove(id: a.id)                              // free "Terminal 1"
        let c = store.add(paneID: "w:p3", createdUnixMs: 3)
        XCTAssertEqual(c.label, "Terminal 1", "should reuse the freed number, not climb to 3")
    }

    func testCustomLabelsAreIgnoredByNumbering() {
        var store = SavedTerminals()
        let a = store.add(paneID: "w:p1", createdUnixMs: 1) // Terminal 1
        store.rename(id: a.id, to: "build box")
        let b = store.add(paneID: "w:p2", createdUnixMs: 2)
        XCTAssertEqual(b.label, "Terminal 1", "a custom-renamed terminal frees its old number")
    }

    func testRenameIgnoresBlankAndTrims() {
        var store = SavedTerminals()
        let a = store.add(paneID: "w:p1", createdUnixMs: 1)
        store.rename(id: a.id, to: "   ")
        XCTAssertEqual(store.terminals[0].label, "Terminal 1", "blank rename is refused")
        store.rename(id: a.id, to: "  pi  ")
        XCTAssertEqual(store.terminals[0].label, "pi", "label is trimmed")
    }

    func testRemovePaneForgetsByPaneID() {
        var store = SavedTerminals()
        _ = store.add(paneID: "w:p1", createdUnixMs: 1)
        _ = store.add(paneID: "w:p2", createdUnixMs: 2)
        store.removePane("w:p1")
        XCTAssertEqual(store.terminals.map(\.paneID), ["w:p2"])
    }

    func testCodableRoundTrip() throws {
        var store = SavedTerminals()
        _ = store.add(paneID: "w:p1", createdUnixMs: 10, id: UUID())
        let a = store.add(paneID: "w:p2", createdUnixMs: 20, id: UUID())
        store.rename(id: a.id, to: "deploy")
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(SavedTerminals.self, from: data)
        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.terminals.map(\.label), ["Terminal 1", "deploy"])
    }
}
