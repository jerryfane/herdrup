import XCTest
@testable import HerdrKit

final class AgentPresentationTests: XCTestCase {
    func testActivityRemovesOnlyLeadingDecoration() throws {
        let cases: [(String, String?)] = [
            ("π ⠇ Adjust captions", "Adjust captions"),
            ("π ⠙ Launch campaign", "Launch campaign"),
            ("π ⠹ Implement issue 405", "Implement issue 405"),
            ("π > Resume queued builds", "Resume queued builds"),
            ("✳ Implement a feature", "Implement a feature"),
            ("✶ Thinking", "Thinking"),
            ("restore-router-port-forwards", "restore-router-port-forwards"),
            ("Update names to codex-use | repos", "Update names to codex-use | repos"),
            ("Compute π and ⠇ inside  text", "Compute π and ⠇ inside  text"),
            ("προβολή", "προβολή"), ("> literal quote", "> literal quote"),
            ("", nil), ("π ⠂", nil), ("  ⠈ ⠁  ", nil)
        ]
        for (title, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: [
                "pane_id": "w1:p1", "terminal_title_stripped": title
            ])
            let agent = try JSONDecoder().decode(AgentInfo.self, from: data)
            XCTAssertEqual(agent.activityText, expected, title)
        }
    }

    func testInitialUsesTheFirstGraphemeOfTheName() {
        XCTAssertEqual(AgentPresentation.initial(for: "  keephair"), "K")
        XCTAssertEqual(AgentPresentation.initial(for: "joltra"), "J")
        XCTAssertEqual(AgentPresentation.initial(for: "Élodie"), "É")
        XCTAssertEqual(AgentPresentation.initial(for: "東京"), "東")
        XCTAssertEqual(AgentPresentation.initial(for: "👩🏽‍💻 coding"), "👩🏽‍💻")
        XCTAssertEqual(AgentPresentation.initial(for: " \n"), "?")
    }
}
