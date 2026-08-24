import XCTest
@testable import HerdrKit

/// The two client calls the new-agent folder browser + harness picker add: listDir (fs.list_dir →
/// ResponseResult::DirList) and agentKinds (agent.kinds → ResponseResult::AgentKinds). Request
/// encoding and response decoding are pinned to herdr's actual wire shapes.
final class FolderAndKindsTests: XCTestCase {

    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var lastRequest = ""
        func roundTrip(_ requestLine: String) async throws -> String {
            lastRequest = requestLine
            if requestLine.contains("fs.list_dir") {
                return #"""
                {"id":"x","result":{"type":"dir_list","path":"/root/project",\#
                "entries":[{"name":"src","is_dir":true},{"name":"README.md","is_dir":false}]}}
                """#
            }
            if requestLine.contains("agent.kinds") {
                return #"""
                {"id":"x","result":{"type":"agent_kinds","kinds":[\#
                {"kind":"claude","installed":true},{"kind":"codex","installed":false}]}}
                """#
            }
            return #"{"id":"x","result":{}}"#
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testListDirSendsPathAndDecodesEntries() async throws {
        let t = CapturingTransport()
        let listing = try await HerdrClient(transport: t).listDir(path: "/root/project")

        XCTAssertTrue(t.lastRequest.contains(#""method":"fs.list_dir""#), "wrong method")
        XCTAssertTrue(t.lastRequest.contains("project"), "path was not sent")
        XCTAssertEqual(listing.path, "/root/project")
        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md"])
        XCTAssertEqual(listing.entries.first?.isDir, true, "is_dir must map to isDir")
        XCTAssertEqual(listing.entries.last?.isDir, false)
    }

    func testListDirOmitsPathWhenNil() async throws {
        let t = CapturingTransport()
        _ = try await HerdrClient(transport: t).listDir(path: nil)
        // A nil path must be omitted (not sent as null) so the daemon defaults to $HOME.
        XCTAssertFalse(t.lastRequest.contains("\"path\""), "nil path should be omitted")
    }

    func testAgentKindsDecodesInstalledFlags() async throws {
        let t = CapturingTransport()
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
        struct ErrorTransport: HerdrTransport {
            func roundTrip(_ r: String) async throws -> String {
                #"{"id":"x","error":{"code":"not_a_directory","message":"/etc/hosts is not a directory"}}"#
            }
            func stream(_ r: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        do {
            _ = try await HerdrClient(transport: ErrorTransport()).listDir(path: "/etc/hosts")
            XCTFail("a non-directory must throw")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "not_a_directory")
        }
    }
}
