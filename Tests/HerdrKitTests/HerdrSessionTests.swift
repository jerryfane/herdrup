import XCTest
import Foundation
@testable import HerdrKit

/// #347: `herdr session list --json` as herdr prints it (`session::SessionInfo`), and the
/// names the app will put after `--session` in a shell command.
final class HerdrSessionTests: XCTestCase {

    func testDecodeListKeepsSafeNamesWithDefaultLast() throws {
        let json = #"""
        {"sessions":[
          {"name":"default","default":true,"running":true,"socket_path":"/h/.config/herdr/herdr.sock","session_dir":"/h/.config/herdr"},
          {"name":"work","default":false,"running":true,"socket_path":"/h/s/work/herdr.sock","session_dir":"/h/s/work"},
          {"name":"bad name;rm","default":false,"running":true,"socket_path":"x","session_dir":"x"},
          {"name":"personal","default":false,"running":false,"connection_error":"refused","socket_path":"y","session_dir":"y"}
        ]}
        """#
        let sessions = try HerdrSession.decodeList(Data(json.utf8))
        XCTAssertEqual(sessions, [
            HerdrSession(name: "personal", running: false, default: false),
            HerdrSession(name: "work", running: true, default: false),
            HerdrSession(name: "default", running: true, default: true),
        ])
    }

    func testOnlyHerdrSessionNamesReachTheCommandLine() throws {
        for name in ["work", "a", "work.2_b-c", String(repeating: "x", count: 64)] {
            XCTAssertTrue(CitadelTransport.isSessionName(name), name)
            XCTAssertTrue(try CitadelTransport.bridgeCommand(for: "{}", session: name)
                .contains(#"exec "$HERDR" --session \#(name) api-bridge "$*""#), name)
        }
        for name in ["", ".", "..", "has space", "semi;colon", "quote'", "$(id)", "ünï",
                     String(repeating: "x", count: 65)] {
            XCTAssertFalse(CitadelTransport.isSessionName(name), name)
            XCTAssertFalse(try CitadelTransport.bridgeCommand(for: "{}", session: name).contains("--session"), name)
        }
        XCTAssertFalse(try CitadelTransport.bridgeCommand(for: "{}", session: "default").contains("--session"))
        XCTAssertFalse(try CitadelTransport.bridgeCommand(for: "{}", session: nil).contains("--session"))
    }
}
