import XCTest
import UIKit

final class TerminalControlTests: TerminalInteractionTestCase {
    /// The UIKit-backed terminal reply editor. Its delegate owns Return submission,
    /// which SwiftUI's multiline TextField could not observe.
    private var reply: XCUIElement { app.textViews["terminal-reply-input"] }

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

    /// The reply path takes the keyboard first, from a fresh launch. Typing the chord
    /// is the observable focus check; this must not depend on a SwiftUI toolbar control
    /// because the reply editor is UIKit-backed.
    func testReplyFieldStillConsumesControl() throws {
        launch("control")
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
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

    /// PASTED, not typed. Return now submits instead of inserting, so `typeText("\n\n")`
    /// never reaches the buffer and a typing version of this test passed because newlines
    /// are uninsertable — not because `canSend` trims them. Pasting is the only route that
    /// still puts a newline-only string in the composer, so it is the route that pins the
    /// trimming rule.
    func testReplyContainingOnlyNewlinesIsNotSendable() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("newline-pasteboard")

        field.tap()
        field.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertEqual(field.value as? String, "\n\n",
                       "the newlines must actually reach the composer for this to test anything")
        XCTAssertFalse(app.buttons["terminal-send-button"].exists,
                       "a newline-only reply should stay unsendable")

        field.typeText("message")
        XCTAssertTrue(app.buttons["terminal-send-button"].waitForExistence(timeout: 5),
                      "visible text should make the reply sendable")
    }

    func testTypingKeepsReplyFocusedAcrossStateUpdates() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("w")
        field.typeText("ord")
        XCTAssertEqual(field.value as? String, "word")
    }

    func testCopiedPhotoOffersPasteAndSendsAttachment() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("photo-pasteboard")

        XCTAssertTrue(pasteIntoReply(field),
                      "a copied photo should offer Paste in the reply editor")

        let chip = replyAttachmentChip
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "pasting a photo should stage a visible attachment")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5),
                      "a photo should be sendable without caption text")
        send.tap()
        let sent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 15), .completed,
                       "the photo should upload, post to the agent, and clear after prompt delivery")
    }

    /// The SAME path with a non-image file (a PDF), because the composer only accepted
    /// images at first: "paste a photo" worked while "paste the file you just copied" was a
    /// silent no-op. Nothing in staging, upload or the prompt reference is image-specific,
    /// so this receipt exists to keep the type filter from narrowing back.
    func testCopiedFileOffersPasteAndSendsAttachment() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        command("file-pasteboard")

        XCTAssertTrue(pasteIntoReply(field),
                      "a copied file should offer Paste in the reply editor")

        let chip = replyAttachmentChip
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "pasting a file should stage a visible attachment")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5),
                      "a file should be sendable without caption text")
        send.tap()
        let sent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 15), .completed,
                       "the file should upload, post to the agent, and clear after prompt delivery")
    }

    /// TWO attachments in one reply. The composer used to hold a single one and a second
    /// paste REPLACED the first — silently, after deleting its staged bytes — so this
    /// pins the count through the whole path: both chips staged, both delivered, both
    /// cleared by the one prompt that names them.
    func testTwoPastedFilesAreBothStagedAndSentTogether() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // BY NAME, not by counting elements carrying the chip identifier: SwiftUI
        // propagates an identifier to every child of the chip, so a count there reports
        // glyph + label + remove button per attachment, not attachments.
        let photoChip = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "photo-")).firstMatch
        let fileChip = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "file-")).firstMatch

        command("photo-pasteboard")
        XCTAssertTrue(pasteIntoReply(field), "the photo should offer Paste")
        XCTAssertTrue(photoChip.waitForExistence(timeout: 10), "the photo should stage a chip")

        command("file-pasteboard")
        XCTAssertTrue(pasteIntoReply(field), "the file should offer Paste too")
        let note = app.staticTexts["terminal-action-note"]
        XCTAssertTrue(fileChip.waitForExistence(timeout: 10),
                      "the file should stage its own chip — note=\(note.exists ? note.label : "none")")
        XCTAssertTrue(photoChip.exists,
                      "a second paste must ADD an attachment, not replace the first")

        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        for chip in [photoChip, fileChip] {
            let cleared = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: chip)
            XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 20), .completed,
                           "both attachments should post and clear once the prompt is delivered")
        }
    }

    /// The staged-attachment chip. A container, so it is matched across element types
    /// rather than assumed to be an `otherElement`.
    private var replyAttachmentChip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "terminal-attachment").firstMatch
    }

    /// Long-press the reply field and tap Paste. Returns false when the menu never offered
    /// it, so the caller can fail with its own message.
    private func pasteIntoReply(_ field: XCUIElement) -> Bool {
        field.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        guard paste.waitForExistence(timeout: 5) else { return false }
        paste.tap()
        return true
    }

    func testReplyComposerGrowsUpwardThenScrollsWithoutMovingSend() {
        launch("control")
        let field = app.textViews["terminal-reply-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        field.tap()
        field.typeText("one")
        let send = app.buttons["terminal-send-button"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)
        let oneLine = field.frame
        let sendBottom = send.frame.maxY

        field.typeText(String(repeating: " wrapped", count: 60))
        Thread.sleep(forTimeInterval: 0.3)
        let threeLines = field.frame
        XCTAssertGreaterThan(threeLines.height, oneLine.height)
        XCTAssertEqual(threeLines.maxY, oneLine.maxY, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue(send.isHittable)

        field.typeText(String(repeating: " overflow", count: 20) + " tail-token")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(field.frame.height, threeLines.height, accuracy: 2)
        XCTAssertEqual(send.frame.maxY, sendBottom, accuracy: 2)
        XCTAssertTrue((field.value as? String)?.contains("tail-token") == true)
        let lower = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        field.typeText(" after-scroll")
        XCTAssertTrue((field.value as? String)?.contains("after-scroll") == true,
                      "scrolling overflow text should keep the composer focused and editable")
        command("reply-multiline-pasteboard")
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        end.tap()
        end.press(forDuration: 1)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Paste"))
            .firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertTrue((field.value as? String)?.contains("pasted-tail") == true,
                      "a multiline paste should remain in the scrolling composer")
        field.typeText(" after-paste")
        XCTAssertTrue((field.value as? String)?.hasSuffix("pasted-tail after-paste") == true,
                      "typing after a multiline paste should keep the caret at the end")
        XCTAssertTrue(send.isHittable)
    }
}
