import XCTest
import UIKit

final class TerminalControlTests: TerminalInteractionTestCase {
    private var ctrl: XCUIElement { app.buttons["terminal-ctrl"].firstMatch }
    private var reply: XCUIElement { app.textFields["type a reply…"] }

    private func requireDirectInput() throws {
        let state = wait { $0["keyDriveEnabled"] != nil }
        if state["iPad"] as? Bool == true && state["keyDriveEnabled"] as? Bool == false {
            throw XCTSkip("iPad direct input requires an attached hardware keyboard; production keyDriveEnabled is false. No simulator bypass is installed; physical-keyboard receipt remains unverified.")
        }
        XCTAssertEqual(state["keyDriveEnabled"] as? Bool, true, "iPhone direct input must remain eligible")
    }

    private func focusTerminal() {
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        wait { ($0["focused"] as? Bool) == true }
    }

    private func chord(_ text: String) {
        ctrl.tap()
        // Deliberately no wait for a SwiftUI update between arming and typing.
        app.typeText(text)
    }

    private func input(_ expected: String, previous: Int? = nil) {
        let prompt = ("fixture> " + expected).trimmingCharacters(in: .whitespaces)
        wait {
            ($0["input"] as? String) == expected
                && (previous == nil || ($0["previous"] as? Int) == previous)
                && ($0["visible"] as? String ?? "").split(separator: "\n").contains {
                    $0.trimmingCharacters(in: .whitespaces) == prompt
                }
        }
    }

    func testLegacyPreviousIsOneEventThenOrdinaryCharacter() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        let draft = reply.value as? String
        chord("p")
        input("second-known-command", previous: 1)
        XCTAssertEqual(probe()["legacyPrevious"] as? Int, 1)
        XCTAssertEqual(probe()["kittyPrevious"] as? Int, 0)
        XCTAssertEqual(reply.value as? String, draft, "Direct input changed the reply draft")
        app.typeText("p")
        input("second-known-commandp", previous: 1)
        attach("legacy-one-shot-followed-by-literal-p")
        chord("p"); input("first-known-command", previous: 2)
        chord("n"); input("second-known-command", previous: 2)
        chord("c"); input("", previous: 2)
        XCTAssertEqual(probe()["next"] as? Int, 1)
        XCTAssertEqual(probe()["clears"] as? Int, 1)
        attach("legacy-history-next-and-clear")
    }

    func testKittyHistoryUsesNativeEnhancedEncodingOnce() throws {
        launch("control"); try requireDirectInput()
        command("kitty"); focusTerminal()
        chord("p"); input("second-known-command", previous: 1)
        XCTAssertEqual(probe()["kittyPrevious"] as? Int, 1)
        XCTAssertEqual(probe()["legacyPrevious"] as? Int, 0)
        app.typeText("p"); input("second-known-commandp", previous: 1)
        chord("n"); input("", previous: 1)
        chord("p"); input("second-known-command", previous: 2)
        chord("c"); input("", previous: 2)
        attach("kitty-native-chords-and-unmodified-next-key")
    }

    func testTwoTapsCancelAndReplyFieldStillConsumesControl() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        ctrl.tap(); ctrl.tap(); app.typeText("p")
        input("p", previous: 0)
        reply.tap()
        ctrl.tap(); reply.typeText("p")
        wait { ($0["input"] as? String) == "second-known-command" && ($0["previous"] as? Int) == 1 }
        XCTAssertFalse((reply.value as? String ?? "").hasSuffix("p"), "Reply chord leaked literal text into the draft")
        attach("reply-field-control-preserved")
    }

    func testDeleteNonASCIICompositionAndPasteDisarm() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        app.typeText("x")
        ctrl.tap(); app.typeText(XCUIKeyboardKey.delete.rawValue)
        input("", previous: 0)
        app.typeText("p"); input("p", previous: 0)
        chord("c"); input("")
        ctrl.tap(); app.typeText("é")
        input("é", previous: 0)
        app.typeText("p"); input("ép", previous: 0)
        chord("c"); input("")
        ctrl.tap(); command("ime-commit")
        input("日本", previous: 0)
        focusTerminal(); app.typeText("p"); input("日本p", previous: 0)
        chord("c"); input("")
        ctrl.tap(); command("paste-batch")
        input("paste-payload", previous: 0)
        focusTerminal(); app.typeText("p"); input("paste-payloadp", previous: 0)
        chord("c"); input("")
        ctrl.tap(); command("batch-insert")
        input("batch-payload", previous: 0)
        focusTerminal(); app.typeText("p"); input("batch-payloadp", previous: 0)
        attach("batch-composition-delete-and-next-key")
    }

    func testExplicitKeycapAndKeyboardDismissalDisarm() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        ctrl.tap()
        app.buttons["Tab"].tap()
        app.typeText("p"); input("p", previous: 0)
        chord("c"); input("")
        ctrl.tap()
        app.buttons["Collapse keyboard"].tap()
        wait { ($0["focused"] as? Bool) == false }
        focusTerminal(); app.typeText("p"); input("p", previous: 0)
        attach("explicit-key-and-keyboard-dismissal-no-leak")
    }

    func testDictationStartDisarmsEvenIfPermissionIsDenied() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        ctrl.tap()
        app.buttons["Dictate"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Permissions may already be settled by another case on this simulator.
        // Refuse recording when prompted; starting alone must consume armed Ctrl.
        for _ in 0..<2 {
            let deny = springboard.buttons["Don’t Allow"].firstMatch
            let asciiDeny = springboard.buttons["Don't Allow"].firstMatch
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            else if asciiDeny.exists { asciiDeny.tap() }
        }
        if app.buttons["Stop dictation"].exists { app.buttons["Stop dictation"].tap() }
        if app.alerts.firstMatch.exists { app.alerts.buttons["OK"].tap() }
        focusTerminal(); app.typeText("p"); input("p", previous: 0)
        attach("dictation-start-no-modifier-leak")
    }

    func testAppDeactivationDisarmsBeforeNextDirectKey() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        ctrl.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        focusTerminal(); app.typeText("p"); input("p", previous: 0)
        attach("app-deactivation-no-modifier-leak")
    }

    func testPaneSwitchAndTypingDuringCoverDoNotLeakOrRearm() throws {
        launch("resize"); try requireDirectInput(); focusTerminal()
        ctrl.tap(); command("switch")
        wait { ($0["pane"] as? String) == "ix:b" }
        focusTerminal(); app.typeText("p"); input("p", previous: 0)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        focusTerminal(); app.typeText("p"); input("p", previous: 0)
        command("delayed"); command("120x24")
        app.typeText("x")
        wait { ($0["covered"] as? Bool) == false && ($0["input"] as? String) == "px" }
        settled(cols: 120)
        input("px", previous: 0)
        attach("typing-cancels-cover-without-input-replay")
    }
}
