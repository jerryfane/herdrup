import XCTest
@testable import HerdrKit

/// Decode tests for `pane.get`'s scroll block — the one authoritative answer to "does
/// earlier output exist for this pane at all".
///
/// The payloads here are REAL, captured from a live daemon (protocol 18) rather than
/// hand-invented, because the whole point of this decode is to be faithful to a wire shape
/// the client does not control.
final class PaneScrollInfoTests: XCTestCase {

    private func decode(_ json: String) throws -> HerdrClient.PaneScrollResult {
        try JSONDecoder().decode(ResultEnvelope<HerdrClient.PaneScrollResult>.self,
                                 from: Data(json.utf8)).result
    }

    /// A BACKGROUND-spawned Claude pane, captured live. It repaints in place, so the
    /// server holds no scrollback at all — this `0` is what separates it from a pane whose
    /// backfill simply has not landed yet.
    func testBackgroundPaneReportsZeroScrollback() throws {
        let json = """
        {"id":"cli:pane:get","result":{"pane":{"agent":"claude","agent_status":"working",\
        "cwd":"/root","focused":false,"label":"herdr-app","pane_id":"w6536a4e5b44342:p4A",\
        "revision":3373,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,\
        "viewport_rows":34},"terminal_title":"check branch state",\
        "workspace_id":"w6536a4e5b44342"},"type":"pane_info"}}
        """
        let scroll = try decode(json).pane.scroll
        XCTAssertEqual(scroll?.maxOffsetFromBottom, 0)
        XCTAssertEqual(scroll?.viewportRows, 34)
        XCTAssertEqual(scroll?.offsetFromBottom, 0)
    }

    /// An INTERACTIVE Claude pane on the same host, same 34-row viewport, captured in the
    /// same session. 2639 rows of real history — the contrast that makes the field useful.
    func testInteractivePaneReportsRealScrollback() throws {
        let json = """
        {"id":"cli:pane:get","result":{"pane":{"agent":"claude","agent_status":"done",\
        "cwd":"/root/gitmoot","focused":false,"label":"Jarvis","pane_id":"w6536a4e5b44342:p3W",\
        "revision":2195,"scroll":{"max_offset_from_bottom":2639,"offset_from_bottom":0,\
        "viewport_rows":34},"workspace_id":"w6536a4e5b44342"},"type":"pane_info"}}
        """
        XCTAssertEqual(try decode(json).pane.scroll?.maxOffsetFromBottom, 2639)
    }

    /// A pane record with NO scroll block — an older daemon, or a pane the server reports
    /// without geometry. Must decode to nil rather than throwing, because the caller
    /// treats "no evidence" as "do not drive this pane" and a thrown error would instead
    /// propagate into a pane open.
    func testMissingScrollBlockDecodesToNilNotAnError() throws {
        let json = """
        {"id":"x","result":{"pane":{"pane_id":"w1:p1","agent":"claude"},"type":"pane_info"}}
        """
        XCTAssertNil(try decode(json).pane.scroll)
    }

    /// Unknown sibling keys must not break the decode. The server adds fields; this client
    /// models three and ignores the rest by design.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {"id":"x","result":{"pane":{"pane_id":"w1:p1","scroll":{"max_offset_from_bottom":12,\
        "offset_from_bottom":3,"viewport_rows":40,"future_field":"whatever"},\
        "another_new_block":{"a":1}},"type":"pane_info"}}
        """
        XCTAssertEqual(try decode(json).pane.scroll?.maxOffsetFromBottom, 12)
    }

    /// A partially-populated scroll block still yields what it does carry.
    func testPartialScrollBlockDecodesAvailableFields() throws {
        let json = """
        {"id":"x","result":{"pane":{"pane_id":"w1:p1","scroll":{"viewport_rows":24}},"type":"pane_info"}}
        """
        let scroll = try decode(json).pane.scroll
        XCTAssertEqual(scroll?.viewportRows, 24)
        XCTAssertNil(scroll?.maxOffsetFromBottom)
    }

    /// The decoded value feeds `ScrollPolicy` directly, so pin the end-to-end meaning:
    /// server-zero on an agent pane is inert, server-positive is left to the native pan.
    func testDecodedRowsDriveTheScrollPolicy() throws {
        let bg = try decode("""
        {"id":"x","result":{"pane":{"pane_id":"w1:p1","scroll":{"max_offset_from_bottom":0}},"type":"pane_info"}}
        """).pane.scroll?.maxOffsetFromBottom
        let interactive = try decode("""
        {"id":"x","result":{"pane":{"pane_id":"w1:p1","scroll":{"max_offset_from_bottom":2639}},"type":"pane_info"}}
        """).pane.scroll?.maxOffsetFromBottom

        XCTAssertEqual(ScrollPolicy.decide(ScrollContext(
            nativeRangePoints: 0, hostsAgent: true, agentKind: "claude",
            serverScrollbackRows: bg)), .inert)
        XCTAssertEqual(ScrollPolicy.decide(ScrollContext(
            nativeRangePoints: 0, hostsAgent: true, agentKind: "claude",
            serverScrollbackRows: interactive)), .nativePan)
    }
}
