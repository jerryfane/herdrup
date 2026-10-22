import Foundation
import XCTest
@testable import HerdrKit

/// `pane.history`: the cursor-paged scrollback above a keyframe's history (herdr terminal
/// history paging). The wire shape and the two "stop paging" refusals are what the app's
/// terminal relies on; a wrong key here would decode as "no more history" and silently end
/// paging instead of failing.
final class PaneHistoryTests: XCTestCase {
    private static func page(rows: Int, b64: String, cursor: String?) -> String {
        let cursorJSON = cursor.map { #""\#($0)""# } ?? "null"
        return #"{"id":"x","result":{"type":"pane_history","pane_id":"w1:p1","history_b64":"\#(b64)","rows":\#(rows),"cursor":\#(cursorJSON)}}"#
    }

    func testRequestCarriesPaneCursorAndLines() async throws {
        let transport = RecordingTransport(reply: Self.page(rows: 0, b64: "", cursor: nil))
        _ = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "hc-9", lines: 500)

        let request = try transport.last()
        XCTAssertEqual(request.method, "pane.history")
        XCTAssertEqual(request.params["pane_id"] as? String, "w1:p1")
        XCTAssertEqual(request.params["cursor"] as? String, "hc-9")
        XCTAssertEqual(request.params["lines"] as? Int, 500)
        XCTAssertEqual(request.params.count, 3, "no other params: \(request.params)")
    }

    func testLinesAreClampedToTheServersRange() async throws {
        let transport = RecordingTransport(reply: Self.page(rows: 0, b64: "", cursor: nil))
        let client = HerdrClient(transport: transport)
        _ = try await client.paneHistory(pane: "w1:p1", cursor: "c", lines: 0)
        XCTAssertEqual(try transport.last().params["lines"] as? Int, 1)
        _ = try await client.paneHistory(pane: "w1:p1", cursor: "c", lines: 5000)
        XCTAssertEqual(try transport.last().params["lines"] as? Int, 1000)
    }

    func testPageDecodesRowsAndNextCursor() async throws {
        let ansi = "\u{1b}[31mold 1\u{1b}[0m\r\nold 2"
        let transport = RecordingTransport(reply: Self.page(
            rows: 2, b64: Data(ansi.utf8).base64EncodedString(), cursor: "hc-older"))
        let page = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "hc-9")

        XCTAssertEqual(page.paneID, "w1:p1")
        XCTAssertEqual(page.rows, 2)
        XCTAssertEqual(String(decoding: page.data, as: UTF8.self), ansi)
        XCTAssertEqual(page.cursor, "hc-older")
    }

    func testNullCursorMeansStartOfHistory() async throws {
        let transport = RecordingTransport(reply: Self.page(
            rows: 1, b64: Data("first".utf8).base64EncodedString(), cursor: nil))
        let page = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "hc-9")
        XCTAssertEqual(page.rows, 1)
        XCTAssertNil(page.cursor)

        // An omitted cursor reads the same as null.
        let omitted = RecordingTransport(reply:
            #"{"id":"x","result":{"type":"pane_history","pane_id":"w1:p1","history_b64":"","rows":0}}"#)
        let empty = try await HerdrClient(transport: omitted).paneHistory(pane: "w1:p1", cursor: "hc-9")
        XCTAssertEqual(empty.rows, 0)
        XCTAssertNil(empty.cursor)
    }

    func testCorruptHistoryFailsThePage() async {
        let transport = RecordingTransport(reply: Self.page(rows: 1, b64: "%%", cursor: "c"))
        do {
            _ = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "hc-9")
            XCTFail("invalid base64 must not decode as a page")
        } catch is DecodingError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testExpiredCursorIsTyped() async {
        let transport = RecordingTransport.error(code: "history_cursor_expired", message: "history cursor expired")
        do {
            _ = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "hc-gone")
            XCTFail("an expired cursor must throw")
        } catch {
            XCTAssertEqual(error as? PaneHistoryError, .historyCursorExpired)
        }
    }

    func testServerWithoutTheMethodIsUnsupported() async {
        let transport = RecordingTransport.error(
            code: "invalid_request",
            message: "unknown variant `pane.history`, expected one of `ping`, `pane.read`")
        do {
            _ = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "c")
            XCTFail("an older server must throw")
        } catch {
            XCTAssertEqual(error as? PaneHistoryError, .unsupported)
        }
    }

    func testOtherRefusalsStayAPIErrors() async {
        let transport = RecordingTransport.error(code: "pane_not_found", message: "pane w1:p1 not found")
        do {
            _ = try await HerdrClient(transport: transport).paneHistory(pane: "w1:p1", cursor: "c")
            XCTFail("a missing pane must throw")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "pane_not_found")
        }
    }

    func testPingAdvertisesPaneHistoryAndDefaultsFalse() async throws {
        let current = RecordingTransport(reply:
            #"{"id":"x","result":{"type":"pong","version":"0.8.2","protocol":22,"capabilities":{"pane_history":true}}}"#)
        let capabilities = try await HerdrClient(transport: current).serverCapabilities()
        XCTAssertEqual(capabilities?.paneHistory, true)

        let older = RecordingTransport(reply:
            #"{"id":"x","result":{"type":"pong","version":"0.8.2","protocol":22,"capabilities":{"live_handoff":true}}}"#)
        let olderCapabilities = try await HerdrClient(transport: older).serverCapabilities()
        XCTAssertEqual(olderCapabilities?.paneHistory, false)
    }
}
