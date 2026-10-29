import XCTest

/// Scratch-only runtime receipt for PR #577. Uses the production pane, Chat switch,
/// terminal renderer and ordered geometry path; only the remote peer is the existing fixture.
final class ChatHiddenTerminalSmokeTests: TerminalInteractionTestCase {
    func testStreamingAndResizeWhileChatCoversTerminalPreservesFirstVisibleFrame() {
        launch("resize", environment: ["HERDR_CHAT_HIDDEN_RECEIPT": "1", "HERDR_STEADY_CARET": "1"])
        command("history")
        anchor()
        let initial = probe()
        XCTAssertEqual(initial["opens"] as? Int, 1)
        XCTAssertEqual(initial["cols"] as? Int, 80)
        XCTAssertTrue(app.buttons["chat-switch-terminal"].isSelected)
        receipt("before-chat")

        let chat = app.descendants(matching: .any)["chat-view"].firstMatch
        app.buttons["chat-switch-chat"].tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat-switch-chat"].isSelected)
        wait { ($0["chatHidden"] as? Bool) == true }
        command("busy")
        wait { ($0["appended"] as? Int ?? 0) >= 3 }
        command("120x24", until: fixtureFit("120x24"))
        command("keyboard-show")
        let hidden = wait {
            let live = $0["live"] as? [String: Any] ?? [:]
            return ($0["chatHidden"] as? Bool) == true
                && ($0["effectiveCols"] as? Int) == 120
                && (live["cols"] as? Int) == 120
                && ($0["keyboardSpacer"] as? Int ?? 0) > 0
        }
        XCTAssertGreaterThan(hidden["appended"] as? Int ?? 0, initial["appended"] as? Int ?? 0)
        XCTAssertEqual(hidden["opens"] as? Int, 1, "Chat and geometry must retain the same stream")
        XCTAssertTrue(chat.exists, "Chat must still cover the terminal during the resize")
        receipt("streaming-and-resized-under-chat")
        command("quiet")

        app.buttons["chat-switch-terminal"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 10))
        let revealed = wait {
            ($0["chatHidden"] as? Bool) == false
                && ($0["covered"] as? Bool) == false
                && $0["firstChatRevealedPaint"] != nil
        }
        let first = revealed["firstChatRevealedPaint"] as? [String: Any] ?? [:]
        XCTAssertEqual(first["complete"] as? Bool, true, "The first uncovered terminal draw must be complete")
        XCTAssertEqual(first["cols"] as? Int, 120)
        XCTAssertEqual(first["rows"] as? Int, 24)
        XCTAssertEqual(first["markerRow"] as? Int, 0, "The reading anchor must survive the hidden resize")
        XCTAssertEqual(first["tail"] as? Bool, false, "Output under Chat must not pull a history reader to the tail")
        XCTAssertTrue((first["top"] as? String ?? "").hasPrefix("ANCHOR020"))
        anchor()
        let complete = wait {
            ($0["appendedRecords"] as? [Int])?.last == ($0["appended"] as? Int)
        }
        let appended = complete["appended"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(appended, 3)
        XCTAssertEqual(complete["records"] as? [Int], Array(0..<100))
        XCTAssertEqual(complete["appendedRecords"] as? [Int], Array(1...max(1, appended)),
                       "Hidden stream output must be neither lost nor replayed")
        XCTAssertEqual(complete["opens"] as? Int, 1)
        receipt("returned-to-terminal-first-paint-and-scroll")
    }

    private func receipt(_ name: String) {
        let state = XCTAttachment(string: app.staticTexts["terminal-interaction-probe"].label)
        state.name = name + "-state"
        state.lifetime = .keepAlways
        add(state)
        attach(name)
    }
}
