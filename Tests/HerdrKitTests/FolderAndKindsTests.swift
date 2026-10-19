import XCTest
@testable import HerdrKit

/// The two client calls the new-agent folder browser + harness picker add: listDir (fs.list_dir →
/// ResponseResult::DirList) and agentKinds (agent.kinds → ResponseResult::AgentKinds). Request
/// encoding and response decoding are pinned to herdr's actual wire shapes.
final class FolderAndKindsTests: XCTestCase {

    /// Answers fs.list_dir and agent.kinds with one canned listing each.
    private static func host() -> RecordingTransport {
        RecordingTransport(replies: [
            "fs.list_dir": #"""
                {"id":"x","result":{"type":"dir_list","path":"/root/project",\#
                "entries":[{"name":"src","is_dir":true},{"name":"README.md","is_dir":false}]}}
                """#,
            "agent.kinds": #"""
                {"id":"x","result":{"type":"agent_kinds","kinds":[\#
                {"kind":"claude","installed":true},{"kind":"codex","installed":false}]}}
                """#,
        ])
    }

    func testListDirSendsPathAndDecodesEntries() async throws {
        let t = Self.host()
        let listing = try await HerdrClient(transport: t).listDir(path: "/root/project")

        XCTAssertTrue(t.lastRequest.contains(#""method":"fs.list_dir""#), "wrong method")
        XCTAssertTrue(t.lastRequest.contains("project"), "path was not sent")
        XCTAssertEqual(listing.path, "/root/project")
        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md"])
        XCTAssertEqual(listing.entries.first?.isDir, true, "is_dir must map to isDir")
        XCTAssertEqual(listing.entries.last?.isDir, false)
    }

    func testListDirOmitsPathWhenNil() async throws {
        let t = Self.host()
        _ = try await HerdrClient(transport: t).listDir(path: nil)
        // A nil path must be omitted (not sent as null) so the daemon defaults to $HOME.
        XCTAssertFalse(t.lastRequest.contains("\"path\""), "nil path should be omitted")
    }

    func testAgentKindsDecodesInstalledFlags() async throws {
        let t = Self.host()
        let kinds = try await HerdrClient(transport: t).agentKinds()

        XCTAssertTrue(t.lastRequest.contains(#""method":"agent.kinds""#), "wrong method")
        XCTAssertEqual(kinds.map(\.kind), ["claude", "codex"])
        XCTAssertEqual(kinds.first?.installed, true)
        XCTAssertEqual(kinds.last?.installed, false)
        XCTAssertEqual(kinds.filter(\.installed).map(\.kind), ["claude"], "the picker filters to installed")
    }

    /// AXIS: a non-directory surfaces as a thrown APIError (`not_a_directory`) so the browser can
    /// show the reason instead of failing silently.
    func testListDirNonDirectorySurfacesAsAPIError() async throws {
        let transport = RecordingTransport.error(code: "not_a_directory", message: "/etc/hosts is not a directory")
        do {
            _ = try await HerdrClient(transport: transport).listDir(path: "/etc/hosts")
            XCTFail("a non-directory must throw")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "not_a_directory")
        }
    }
}
