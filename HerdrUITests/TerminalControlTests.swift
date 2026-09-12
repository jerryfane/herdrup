import XCTest
import UIKit

final class TerminalControlTests: TerminalInteractionTestCase {
    /// The pane's only text field. Matched positionally rather than by placeholder:
    /// the placeholder match can resolve to the label rather than the editable field,
    /// and a tap on that does not move focus.
    private var reply: XCUIElement { app.textFields.firstMatch }

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
        // FOCUS IS READ FROM THE APP, NOT FROM `app.keyboards`. The simulator may have
        // the host hardware keyboard attached, in which case iOS shows no software
        // keyboard for a focused field at all and the keyboard query is simply wrong.
        // The production chevron is gated on `replyFocused`, so its presence is the
        // app's own statement that this field owns the input.
        for attempt in 0..<3 {
            // Tap INSIDE the text, not at the element's centre: the centre of a SwiftUI
            // TextField row can land on padding that does not begin editing.
            reply.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            if onscreen("Collapse keyboard", timeout: 5) != nil { break }
            XCTAssertNotEqual(attempt, 2,
                              "the reply field never took focus. \(elementDump()) \(fieldDump())")
        }
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
        // THE CHEVRON IS PHONE-ONLY BY DESIGN: its gate is
        // `replyFocused || (terminalInputFocused && idiom == .phone)`, because the iPad
        // terminal's input view is zero-frame, so there is no keyboard to collapse and
        // the control would be dead. Asserting it on iPad tested a decision the product
        // deliberately made the other way.
        if probe()["iPad"] as? Bool != true {
            XCTAssertNotNil(onscreen("Collapse keyboard", timeout: 5),
                            "the keyboard chevron must be present while direct input holds the keyboard")
            onscreen("Collapse keyboard")?.tap()
            wait { ($0["focused"] as? Bool) == false }
        } else {
            XCTAssertNil(onscreen("Collapse keyboard", timeout: 2),
                         "iPad must not offer a dismissal for a keyboard it never shows")
            // NOTHING HAS CANCELLED THE ARM ON THIS PATH, and the previous version of
            // this branch expected the next key to be ordinary anyway: the fixture duly
            // received 70 03 10 — the final p arrived as ^P, exactly as a live one-shot
            // should encode it. iPad has no keyboard to dismiss, so cancel the way iPad
            // actually can, with a second tap, and keep the no-leak assertion honest.
            cap("terminal-ctrl").tap()
            XCTAssertFalse(armed, "a second tap must cancel the one-shot")
        }
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
        // DICTATION MUST ACTUALLY HAVE STARTED for its disarm to be owed: production
        // clears the one-shot in MicButton's `onStart`, and `replyDictating` disables
        // the reply field while the mic is live. A simulator with no audio input never
        // starts it, and asserting the disarm there would fail on a state the app was
        // never in.
        let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in self?.reply.isEnabled == false },
            object: nil)], timeout: 5)
        guard started == .completed || !armed else {
            throw XCTSkip("dictation never started in this environment (no audio input), so no disarm is owed. \(elementDump())")
        }
        // STARTING dictation is what must disarm, and the production cap's own label is
        // the observable for it. Asserting it here rather than only through a later
        // keystroke matters: a denied-permission session can leave the phone with no
        // keyboard at all, and then "no character arrived" says nothing about the
        // modifier.
        XCTAssertFalse(armed, "starting dictation must consume the armed one-shot")
        attach("dictation-start-disarmed")
        // The ordinary-key half needs an input path, and a dictation attempt can leave
        // the phone with no keyboard: `focusTerminal` restores the responder, but iOS
        // does not always bring the keyboard back. The disarm above is the receipt this
        // case exists for; deliver a key too whenever the environment still can, rather
        // than failing on a keyboard the app does not control.
        focusTerminal()
        guard canTypeDirectly else {
            attach("dictation-no-input-path-after-permission-flow")
            return
        }
        typeDirect("p"); input("p", previous: 0)
        attach("dictation-start-no-modifier-leak")
    }

        func testAppDeactivationDisarmsBeforeNextDirectKey() throws {
        launch("control"); try requireDirectInput(); focusTerminal()
        cap("terminal-ctrl").tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        // WAIT FOR THE APP TO BE SERVING SNAPSHOTS AGAIN before any query. The first
        // (cold) iPad run failed here with "Failed to get matching snapshots: Timed out
        // while evaluating UI query" — the accessibility hierarchy is not ready the
        // instant `activate()` returns, and the retry passed, which is exactly the
        // shape of failure the workflow refuses to let a warm rerun hide.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "the app did not return to the foreground")
        XCTAssertTrue(app.staticTexts["terminal-interaction-probe"].waitForExistence(timeout: 30),
                      "the probe never came back after reactivation")
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

    func testReplyContainingOnlyNewlinesIsNotSendable() {
        launch("control")
        let field = app.textFields["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("\n\n")
        XCTAssertFalse(app.buttons["terminal-send-button"].exists,
                       "a newline-only reply should stay empty and unsendable")

        field.typeText("message")
        XCTAssertTrue(app.buttons["terminal-send-button"].waitForExistence(timeout: 5),
                      "visible text should make the reply sendable")
    }

    func testReplyComposerGrowsUpwardThenScrollsWithoutMovingSend() {
        launch("control")
        let field = app.textFields["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("one")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)
        let oneLine = field.frame
        let sendBottom = send.frame.maxY

        field.typeText("\ntwo\nthree")
        Thread.sleep(forTimeInterval: 0.3)
        let threeLines = field.frame
        XCTAssertGreaterThan(threeLines.height, oneLine.height)
        XCTAssertEqual(threeLines.maxY, oneLine.maxY, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue(send.isHittable)

        field.typeText("\nfour")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(field.frame.height, threeLines.height, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("four") == true)
        XCTAssertTrue(send.isHittable)
    }
}
