import XCTest
@testable import HerdrKit

/// Sequences shaped like the callbacks `SFSpeechRecognizer` delivers on device: partials
/// arrive a few hundred ms apart while speaking, and none arrive during a pause.
final class TranscriptAccumulatorTests: XCTestCase {
    private var acc = TranscriptAccumulator()

    override func setUp() {
        acc = TranscriptAccumulator()
    }

    private func partial(_ text: String, _ segment: Int = 1, at time: TimeInterval, ended: Bool = false) {
        acc.result(text, segment: segment, isFinal: false, utteranceEnded: ended, at: time)
    }

    private func final(_ text: String, _ segment: Int = 1, at time: TimeInterval) {
        acc.result(text, segment: segment, isFinal: true, utteranceEnded: true, at: time)
    }

    /// iOS 18 on-device: after a pause `bestTranscription` restarts from the new words with
    /// no final for the earlier ones, and the final holds only the last utterance.
    func testPauseResetKeepsEarlierUtterance() {
        acc.begin(segment: 1)
        partial("hello", at: 0.0)
        partial("hello world", at: 0.4)
        partial("how are", at: 2.0)
        XCTAssertEqual(acc.text, "hello world how are")
        partial("how are you", at: 2.3)
        XCTAssertEqual(acc.text, "hello world how are you")
        final("How are you?", at: 3.5)
        XCTAssertEqual(acc.text, "hello world How are you?")
    }

    /// A new utterance that begins with the previous one's first word is still new.
    func testPauseResetWithSameFirstWord() {
        acc.begin(segment: 1)
        partial("I", at: 0.0)
        partial("I went home", at: 0.5)
        partial("I", at: 2.2)
        partial("I ate", at: 2.5)
        XCTAssertEqual(acc.text, "I went home I ate")
    }

    /// The recognizer flags the utterance it completed (speechRecognitionMetadata), so the
    /// next utterance is kept apart however soon its first words land.
    func testUtteranceEndFlagSeparatesUtterances() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0)
        partial("Hello world", at: 0.3, ended: true)
        partial("how", at: 0.6)
        XCTAssertEqual(acc.text, "Hello world how")
    }

    func testRevisionsReplaceRatherThanDuplicate() {
        acc.begin(segment: 1)
        partial("Eye", at: 0.0)
        partial("I want", at: 0.3)
        partial("I want to to", at: 0.6)
        partial("I want to go", at: 0.9)
        partial("I want to go to the store", at: 1.4)
        XCTAssertEqual(acc.text, "I want to go to the store")
        // The recognizer settles the utterance after the speaker stops.
        partial("I want to go to the store.", at: 2.6)
        XCTAssertEqual(acc.text, "I want to go to the store.")
        final("I want to go to the store.", at: 3.0)
        XCTAssertEqual(acc.text, "I want to go to the store.")
    }

    /// A rewrite arriving after a pause that keeps most of the words is a revision.
    func testLateRevisionAfterSilenceReplaces() {
        acc.begin(segment: 1)
        partial("I want to to go", at: 0.0)
        partial("I want to go", at: 1.4)
        XCTAssertEqual(acc.text, "I want to go")
    }

    /// Before iOS 18 a task's text keeps growing across pauses, even past a result flagged
    /// as an utterance end, and its final is the whole task's text.
    func testCumulativeRecognizerDoesNotDuplicate() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0, ended: true)
        partial("hello world how are you", at: 2.0)
        XCTAssertEqual(acc.text, "hello world how are you")
        final("Hello world, how are you?", at: 3.0)
        XCTAssertEqual(acc.text, "Hello world, how are you?")
    }

    /// Partials restarted after the pause, but the final covers the whole task.
    func testWholeTaskFinalAfterRestartDoesNotDuplicate() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0)
        partial("how are you", at: 2.0)
        final("Hello world how are you.", at: 3.0)
        XCTAssertEqual(acc.text, "Hello world how are you.")
    }

    /// A task finalizes holding only its last utterance; dictation goes on in a new task.
    func testFinalThenNewUtterance() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0)
        partial("Hello world", at: 0.4, ended: true)
        partial("how are", at: 1.5)
        final("How are you?", at: 2.0)
        XCTAssertEqual(acc.text, "Hello world How are you?")
        acc.begin(segment: 2)
        partial("fine", 2, at: 3.0)
        partial("fine thanks", 2, at: 3.3)
        XCTAssertEqual(acc.text, "Hello world How are you? fine thanks")
    }

    /// Rolling to a new task before the ~1-minute ceiling: the rolled task's late final
    /// (with the words it recognised after the swap) lands before the new task's text.
    /// The rolled task had restarted after a pause, so its final holds only its last
    /// utterance.
    func testRollBoundaryLateFinalLandsInOrder() {
        acc.begin(segment: 1)
        partial("one two", at: 0.0)
        partial("three four", at: 1.6)
        acc.begin(segment: 2)
        partial("six", 2, at: 2.0)
        XCTAssertEqual(acc.text, "one two three four six")
        final("three four five", 1, at: 2.2)
        XCTAssertEqual(acc.text, "one two three four five six")
        // The retired task says nothing more.
        partial("zzz", 1, at: 2.3)
        XCTAssertEqual(acc.text, "one two three four five six")
    }

    /// The new task finalizes on a pause before the rolled one does.
    func testActiveFinalBeforeRolledFinalKeepsOrder() {
        acc.begin(segment: 1)
        partial("one two", at: 0.0)
        acc.begin(segment: 2)
        partial("four five", 2, at: 0.3)
        final("Four five.", 2, at: 0.6)
        acc.begin(segment: 3)
        final("one two three", 1, at: 0.9)
        partial("six", 3, at: 1.2)
        XCTAssertEqual(acc.text, "one two three Four five. six")
    }

    /// A task that errors keeps what it showed, through the next roll's final too.
    func testErroredSegmentKeepsTextThroughNextRoll() {
        acc.begin(segment: 1)
        partial("one two", at: 0.0)
        acc.end(segment: 1)
        acc.begin(segment: 2)
        partial("three", 2, at: 0.5)
        acc.begin(segment: 3)
        final("three four", 2, at: 0.8)
        partial("five", 3, at: 1.0)
        XCTAssertEqual(acc.text, "one two three four five")
    }

    func testEmptyResultsKeepText() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0)
        partial("", at: 1.5)
        XCTAssertEqual(acc.text, "hello world")
        final("", at: 2.0)
        XCTAssertEqual(acc.text, "hello world")
    }

    func testStopAfterPauseKeepsEverything() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.0)
        partial("how are", at: 1.8)
        acc.begin(segment: 2)
        partial("you", 2, at: 2.2)
        acc.finish()
        XCTAssertEqual(acc.text, "hello world how are you")
        // Callbacks racing the stop don't change it.
        final("How", 1, at: 2.5)
        partial("bye", 2, at: 2.6)
        XCTAssertEqual(acc.text, "hello world how are you")
    }

    /// Scripts written without spaces still read growth as a continuation.
    func testUnspacedScriptGrowthAfterPause() {
        acc.begin(segment: 1)
        partial("你好", at: 0.0)
        partial("你好吗", at: 1.5)
        XCTAssertEqual(acc.text, "你好吗")
    }
}
