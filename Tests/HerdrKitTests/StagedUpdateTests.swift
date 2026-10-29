import XCTest
@testable import HerdrKit

/// Decode tests for the `server.staged_update` wire type, read only for the daemon's version line.
/// The JSON is built the way the daemon serializes `ResponseResult` — internally tagged with a
/// `type` key and snake_case fields — so a wrong CodingKey or a missed tag-ignore fails here rather
/// than on-device.
final class StagedUpdateTests: XCTestCase {

    private func decodeStaged(_ obj: [String: Any]) throws -> StagedUpdate {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(StagedUpdate.self, from: data)
    }

    /// The running version/protocol decode, snake_case → camelCase maps, and both the internally-
    /// tagged `type` key and a staged build an older server may still report are ignored.
    func testDecodesRunningVersionAndIgnoresAStagedBuild() throws {
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
        XCTAssertEqual(env.result.runningVersion, "0.8.0")
    }

    /// A command that returns `{ type: "ok" }` (e.g. `guest.revoke`); `OkAck` decodes it by ignoring
    /// the tag.
    func testOkAckDecodesAnOkResult() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "ok"])
        XCTAssertNoThrow(try JSONDecoder().decode(OkAck.self, from: data))
    }

    /// `running_sha` decodes to `runningSha` — the field that actually identifies the build (version
    /// is static). Omitted on an older daemon → nil.
    func testDecodesRunningSha() throws {
        let withSha = try decodeStaged([
            "type": "staged_update", "running_version": "0.8.0", "running_protocol": 20,
            "running_sha": "b3e34990",
        ])
        XCTAssertEqual(withSha.runningSha, "b3e34990")
        let without = try decodeStaged([
            "type": "staged_update", "running_version": "0.8.0", "running_protocol": 20,
        ])
        XCTAssertNil(without.runningSha, "an older daemon omits running_sha")
    }
}
