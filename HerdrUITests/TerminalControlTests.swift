import XCTest
import UIKit

final class TerminalControlTests: TerminalInteractionTestCase {
    private var reply: XCUIElement { app.textFields["type a reply…"] }

    /// Whether the ctrl one-shot is armed, read from the production cap's own
    /// accessibility label. Idiom-independent, and the only observable that survives a
    /// state where no keyboard is available at all.
    private var armed: Bool {
        cap("terminal-ctrl").label == "control armed"
    }

    private func chord(_ text: String) {
        cap("terminal-ctrl").tap()
        // Deliberately no wait for a SwiftUI update between arming and typing.
        app.typeText(text)
    }

    /// The accepted line, plus the PAINTED prompt when the fixture actually paints one
    /// in the viewport. The control fixture shows nothing but the prompt, so its paint
    /// is the receipt; the resize fixture seeds a hundred history records and its
    /// prompt is legitimately scrolled out, so demanding it there asserted the
    /// viewport, not the input path.
    private func input(_ expected: String, previous: Int? = nil) {
        let prompt = ("fixture> " + expected).trimmingCharacters(in: .whitespaces)
        let paintExpected = fixtureMode == "control"
        wait {
            ($0["input"] as? String) == expected
                && (previous == nil || ($0["previous"] as? Int) == previous)
                && (!paintExpected || ($0["visible"] as? String ?? "").split(separator: "\n").contains {
                    $0.trimmingCharacters(in: .whitespaces) == prompt
                })
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
        typeDirect("p")
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
        typeDirect("p"); input("second-known-commandp", previous: 1)
        chord("n"); input("", previous: 1)
        chord("p"); input("second-known-command", previous: 2)
        chord("c"); input("", previous: 2)
        attach("kitty-native-chords-and-unmodified-next-key")
    }

    func testTwoTapsCancelInDirectInput() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap()
        XCTAssertTrue(armed, "one tap must arm the one-shot")
        cap("terminal-ctrl").tap()
        XCTAssertFalse(armed, "a second tap must cancel it without sending anything")
        typeDirect("p")
        input("p", previous: 0)
        attach("two-taps-cancel-without-input")
    }

    /// The reply path takes the keyboard FIRST, from a fresh launch.
    ///
    /// Handing the responder over from an already-focused terminal does not reliably
    /// move SwiftUI focus in the simulator, and typing then fails with "neither element
    /// nor any descendant has keyboard focus" — a harness limitation, not a product
    /// one. Ordering the case this way exercises the same production path
    /// (`handleReplyChange`) without depending on that handover.
    func testReplyFieldStillConsumesControl() throws {
        launch("control")
        reply.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10),
                      "the reply field must hold the keyboard. \(elementDump())")
        let draft = reply.value as? String
        cap("terminal-ctrl").tap(); reply.typeText("p")
        wait { ($0["input"] as? String) == "second-known-command" && ($0["previous"] as? Int) == 1 }
        XCTAssertEqual(reply.value as? String, draft, "the reply chord leaked literal text into the draft")
        XCTAssertFalse(armed, "the reply path must consume the one-shot")
        attach("reply-field-control-preserved")
    }

    func testDeleteNonASCIICompositionAndPasteDisarm() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        typeDirect("x")
        cap("terminal-ctrl").tap(); typeDirect(XCUIKeyboardKey.delete.rawValue)
        input("", previous: 0)
        typeDirect("p"); input("p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); typeDirect("é")
        input("é", previous: 0)
        typeDirect("p"); input("ép", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("ime-commit")
        input("日本", previous: 0)
        focusTerminal(); typeDirect("p"); input("日本p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("paste-batch")
        input("paste-payload", previous: 0)
        focusTerminal(); typeDirect("p"); input("paste-payloadp", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap(); command("batch-insert")
        input("batch-payload", previous: 0)
        focusTerminal(); typeDirect("p"); input("batch-payloadp", previous: 0)
        attach("batch-composition-delete-and-next-key")
    }

    func testExplicitKeycapAndKeyboardDismissalDisarm() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap()
        cap("Tab").tap()
        typeDirect("p"); input("p", previous: 0)
        chord("c"); input("")
        cap("terminal-ctrl").tap()
        XCTAssertNotNil(onscreen("Collapse keyboard", timeout: 5),
                        "the keyboard chevron must be present while direct input holds the keyboard")
        onscreen("Collapse keyboard")?.tap()
        wait { ($0["focused"] as? Bool) == false }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        attach("explicit-key-and-keyboard-dismissal-no-leak")
    }

func testDictationStartDisarmsEvenIfPermissionIsDenied() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap()
        XCTAssertTrue(armed)
        onscreen("Dictate", timeout: 5)?.tap()
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
        // STARTING dictation is what must disarm, and the production cap's own label is
        // the observable for it. Asserting it here rather than only through a later
        // keystroke matters: a denied-permission session can leave the phone with no
        // keyboard at all, and then "no character arrived" says nothing about the
        // modifier.
        XCTAssertFalse(armed, "starting dictation must consume the armed one-shot")
        attach("dictation-start-disarmed")
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        attach("dictation-start-no-modifier-leak")
    }

        func testAppDeactivationDisarmsBeforeNextDirectKey() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        attach("app-deactivation-no-modifier-leak")
    }

    func testPaneSwitchAndTypingDuringCoverDoNotLeakOrRearm() throws {
        launch("resize"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap(); command("switch")
        wait { ($0["pane"] as? String) == "ix:b" }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        command("switch")
        wait { ($0["pane"] as? String) == "ix:a" }
        focusTerminal(); typeDirect("p"); input("p", previous: 0)
        command("delayed"); command("120x24")
        typeDirect("x")
        wait { ($0["covered"] as? Bool) == false && ($0["input"] as? String) == "px" }
        settled(cols: 120)
        input("px", previous: 0)
        attach("typing-cancels-cover-without-input-replay")
    }
}
