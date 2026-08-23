import XCTest
@testable import HerdrKit

/// Decode tests for `server.staged_update` / `server.apply_staged_update` wire types. The JSON is
/// built the way the daemon serializes `ResponseResult` — internally tagged with a `type` key and
/// snake_case fields — so a wrong CodingKey or a missed tag-ignore fails here rather than on-device.
final class StagedUpdateTests: XCTestCase {

    private func decodeStaged(_ obj: [String: Any]) throws -> StagedUpdate {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(StagedUpdate.self, from: data)
    }

    /// A staged build present: nested object decodes, snake_case → camelCase maps, and the
    /// internally-tagged `type` key is ignored (it has no field on the struct).
    func testDecodesStagedUpdateWithAStagedBuild() throws {
        let update = try decodeStaged([
            "type": "staged_update",
            "running_version": "0.8.0",
            "running_protocol": 20,
            "staged": [
                "version": "0.8.0",
                "sha": "b3e34990",
                "built_at": "2026-08-23T18:43:06Z",
            ],
        ])
        XCTAssertEqual(update.runningVersion, "0.8.0")
        XCTAssertEqual(update.runningProtocol, 20)
        XCTAssertEqual(update.staged?.version, "0.8.0")
        XCTAssertEqual(update.staged?.sha, "b3e34990")
        XCTAssertEqual(update.staged?.builtAt, "2026-08-23T18:43:06Z",
                       "built_at must map to builtAt — a wrong CodingKey fails here")
    }

    /// Nothing staged: the daemon omits `staged` (it is `skip_serializing_if = Option::is_none`), so
    /// `staged` decodes to nil. This is the "no update available" state the UI keys off.
    func testDecodesStagedUpdateWithNothingStaged() throws {
        let update = try decodeStaged([
            "type": "staged_update",
            "running_version": "0.8.0",
            "running_protocol": 20,
        ])
        XCTAssertNil(update.staged, "an omitted staged object is 'no update available'")
        XCTAssertEqual(update.runningVersion, "0.8.0")
    }

    /// The full wire path: `{ id, result: { type: staged_update, ... } }` unwraps through
    /// `ResultEnvelope`, exactly as `HerdrClient.call(as: StagedUpdate.self)` does.
    func testDecodesThroughResultEnvelopeLikeTheClient() throws {
        let line = #"""
        {"id":"herdrkit:server.staged_update:1","result":{"type":"staged_update",\#
        "running_version":"0.8.0","running_protocol":20,\#
        "staged":{"version":"0.8.0","sha":"b3e34990","built_at":"2026-08-23T18:43:06Z"}}}
        """#
        let env = try JSONDecoder().decode(ResultEnvelope<StagedUpdate>.self, from: Data(line.utf8))
        XCTAssertEqual(env.result.staged?.sha, "b3e34990")
    }

    /// A clean apply returns `{ type: "ok" }`; `OkAck` decodes it by ignoring the tag. (The apply may
    /// instead throw a transport error when the daemon drops mid-handoff — that path is the caller's.)
    func testOkAckDecodesTheApplyAcknowledgement() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "ok"])
        XCTAssertNoThrow(try JSONDecoder().decode(OkAck.self, from: data))
    }
}
