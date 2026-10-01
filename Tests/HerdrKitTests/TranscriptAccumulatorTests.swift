import XCTest
@testable import HerdrKit

/// Sequences shaped like the callbacks `SFSpeechRecognizer` delivers on device: partials
/// arrive a few hundred ms apart while speaking and none arrive during a pause. `at` is
/// when a result arrived; `audio` is where its words sit in the recognition task's audio.
final class TranscriptAccumulatorTests: XCTestCase {
    private var acc = TranscriptAccumulator()
    /// Whether results carry their words' timing; without it the words decide.
    private var timed = true

    override func setUp() {
        acc = TranscriptAccumulator()
        timed = true
    }

    /// Run a scenario with word timing (the normal path) and again without it (the
    /// fallback for results whose timing is missing).
    private func withAndWithoutTiming(_ scenario: () -> Void) {
        for t in [true, false] {
            timed = t
            acc = TranscriptAccumulator()
            scenario()
        }
    }

    private func expect(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(acc.text, text, timed ? "timed" : "untimed", file: file, line: line)
    }

    private func partial(
        _ text: String, _ segment: Int = 1, at time: TimeInterval,
        audio: ClosedRange<TimeInterval>?, ended: Bool = false
    ) {
        acc.result(text, segment: segment, isFinal: false, utteranceEnded: ended,
                   audio: timed ? audio : nil, at: time)
    }

    private func final(
        _ text: String, _ segment: Int = 1, at time: TimeInterval, audio: ClosedRange<TimeInterval>?
    ) {
        acc.result(text, segment: segment, isFinal: true, utteranceEnded: true,
                   audio: timed ? audio : nil, at: time)
    }

    // MARK: - Decided by timing, or by the words when timing is missing

    /// iOS 18 on-device: after a pause `bestTranscription` restarts from the new words with
    /// no final for the earlier ones, and the final holds only the last utterance.
    func testPauseResetKeepsEarlierUtterance() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello", at: 0.5, audio: 0.0...0.4)
            partial("hello world", at: 0.9, audio: 0.0...0.9)
            partial("how are", at: 3.0, audio: 2.4...2.9)
            expect("hello world how are")
            partial("how are you", at: 3.3, audio: 2.4...3.2)
            expect("hello world how are you")
            final("How are you?", at: 4.5, audio: 2.4...3.3)
            expect("hello world How are you?")
        }
    }

    /// A new utterance that begins with the previous one's first word is still new.
    func testPauseResetWithSameFirstWord() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I", at: 0.3, audio: 0.0...0.2)
            partial("I went home", at: 1.0, audio: 0.0...0.9)
            partial("I", at: 2.8, audio: 2.5...2.7)
            partial("I ate", at: 3.1, audio: 2.5...3.0)
            expect("I went home I ate")
        }
    }

    /// The recognizer flags the utterance it completed (speechRecognitionMetadata), so the
    /// next utterance is kept apart however soon its first words land.
    func testUtteranceEndFlagSeparatesUtterances() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8)
            partial("Hello world", at: 1.2, audio: 0.0...0.8, ended: true)
            partial("how", at: 1.5, audio: 1.3...1.5)
            expect("Hello world how")
        }
    }

    func testRevisionsReplaceRatherThanDuplicate() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("Eye", at: 0.2, audio: 0.0...0.2)
            partial("I want", at: 0.5, audio: 0.0...0.5)
            partial("I want to to", at: 0.8, audio: 0.0...0.8)
            partial("I want to go", at: 0.9, audio: 0.0...0.9)
            partial("I want to go to the store", at: 1.6, audio: 0.0...1.5)
            expect("I want to go to the store")
            // The recognizer settles the utterance after the speaker stops.
            partial("I want to go to the store.", at: 2.6, audio: 0.0...1.5)
            expect("I want to go to the store.")
            final("I want to go to the store.", at: 3.0, audio: 0.0...1.5)
            expect("I want to go to the store.")
        }
    }

    /// A rewrite arriving after a pause that drops a stuttered word is a revision.
    func testLateRevisionAfterSilenceReplaces() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I want to to go", at: 1.3, audio: 0.0...1.2)
            partial("I want to go", at: 2.7, audio: 0.0...1.2)
            expect("I want to go")
        }
    }

    /// So is one that settles the last word, keeping the rest.
    func testLateLastWordRevisionAfterSilenceReplaces() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I saw it", at: 0.9, audio: 0.0...0.8)
            partial("I saw that", at: 2.4, audio: 0.0...0.8)
            expect("I saw that")
        }
    }

    /// After a pause a result that starts like the previous one but doesn't continue it is
    /// a new utterance, even keeping half its words.
    func testPauseRestartSharingLeadingWordsKeepsEarlierUtterance() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I want", at: 0.6, audio: 0.0...0.5)
            partial("I ate", at: 2.6, audio: 2.0...2.5)
            expect("I want I ate")
        }
    }

    func testPauseRestartSharingMostLeadingWordsKeepsEarlierUtterance() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I want to go home", at: 1.5, audio: 0.0...1.4)
            partial("I want to eat", at: 4.0, audio: 3.0...3.9)
            expect("I want to go home I want to eat")
        }
    }

    /// Before iOS 18 a task's text keeps growing across pauses, even past a result flagged
    /// as an utterance end, and its final is the whole task's text.
    func testCumulativeRecognizerDoesNotDuplicate() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8, ended: true)
            partial("hello world how are you", at: 2.9, audio: 0.0...2.8)
            expect("hello world how are you")
            final("Hello world, how are you?", at: 3.9, audio: 0.0...2.8)
            expect("Hello world, how are you?")
        }
    }

    /// Partials restarted after the pause, but the final covers the whole task.
    func testWholeTaskFinalAfterRestartDoesNotDuplicate() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8)
            partial("how are you", at: 2.9, audio: 2.0...2.8)
            final("Hello world how are you.", at: 3.9, audio: 0.0...2.8)
            expect("Hello world how are you.")
        }
    }

    /// A final holding only the last utterance supersedes nothing, even when it shares the
    /// kept utterance's first word and is about as long as everything shown.
    func testLastUtteranceFinalSharingFirstWordKeepsEarlierUtterance() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I saw", at: 0.6, audio: 0.0...0.5, ended: true)
            partial("I ate", at: 2.5, audio: 2.0...2.4)
            final("I ate a lot", at: 3.5, audio: 2.0...2.9)
            expect("I saw I ate a lot")
        }
    }

    func testLastUtteranceFinalAfterFlaggedUtteranceKeepsIt() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("I", at: 0.3, audio: 0.0...0.2)
            partial("I went", at: 0.6, audio: 0.0...0.5, ended: true)
            partial("I walked", at: 2.6, audio: 2.0...2.5)
            final("I walked home", at: 3.5, audio: 2.0...2.9)
            expect("I went I walked home")
        }
    }

    /// The last utterance's final settles on the kept utterance's words: it still holds
    /// only itself, so both stay.
    func testLastUtteranceFinalRepeatingKeptWordsKeepsBoth() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("Hello", at: 0.5, audio: 0.0...0.4, ended: true)
            partial("Halo there", at: 2.7, audio: 2.0...2.6)
            final("Hello there.", at: 3.5, audio: 2.0...2.6)
            expect("Hello Hello there.")
        }
    }

    /// A task finalizes holding only its last utterance; dictation goes on in a new task.
    func testFinalThenNewUtterance() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8)
            partial("Hello world", at: 1.3, audio: 0.0...0.8, ended: true)
            partial("how are", at: 2.1, audio: 1.6...2.0)
            final("How are you?", at: 2.6, audio: 1.6...2.4)
            expect("Hello world How are you?")
            acc.begin(segment: 2)
            partial("fine", 2, at: 3.0, audio: 0.3...0.6)
            partial("fine thanks", 2, at: 3.3, audio: 0.3...0.9)
            expect("Hello world How are you? fine thanks")
        }
    }

    /// The rolled task had restarted after a pause, so its final holds only its last
    /// utterance. Each task's timing counts from its own start.
    func testRollBoundaryLateFinalLandsInOrder() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("one two", at: 0.7, audio: 0.0...0.6)
            partial("three four", at: 2.7, audio: 2.0...2.6)
            acc.begin(segment: 2)
            partial("six", 2, at: 3.0, audio: 0.2...0.5)
            expect("one two three four six")
            final("three four five", 1, at: 3.2, audio: 2.0...3.1)
            expect("one two three four five six")
            // The retired task says nothing more.
            partial("zzz", 1, at: 3.3, audio: 3.2...3.3)
            expect("one two three four five six")
        }
    }

    /// The new task finalizes on a pause before the rolled one does.
    func testActiveFinalBeforeRolledFinalKeepsOrder() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("one two", at: 0.7, audio: 0.0...0.6)
            acc.begin(segment: 2)
            partial("four five", 2, at: 1.0, audio: 0.1...0.6)
            final("Four five.", 2, at: 1.3, audio: 0.1...0.6)
            acc.begin(segment: 3)
            final("one two three", 1, at: 1.6, audio: 0.0...1.0)
            partial("six", 3, at: 1.9, audio: 0.2...0.4)
            expect("one two three Four five. six")
        }
    }

    /// A task that errors keeps what it showed, through the next roll's final too.
    func testErroredSegmentKeepsTextThroughNextRoll() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("one two", at: 0.7, audio: 0.0...0.6)
            acc.end(segment: 1)
            acc.begin(segment: 2)
            partial("three", 2, at: 1.0, audio: 0.1...0.4)
            acc.begin(segment: 3)
            final("three four", 2, at: 1.3, audio: 0.1...0.9)
            partial("five", 3, at: 1.5, audio: 0.1...0.4)
            expect("one two three four five")
        }
    }

    func testEmptyResultsKeepText() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8)
            partial("", at: 2.4, audio: nil)
            expect("hello world")
            final("", at: 3.0, audio: nil)
            expect("hello world")
        }
    }

    func testStopAfterPauseKeepsEverything() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("hello world", at: 0.9, audio: 0.0...0.8)
            partial("how are", at: 2.6, audio: 2.0...2.5)
            acc.begin(segment: 2)
            partial("you", 2, at: 3.0, audio: 0.1...0.3)
            acc.finish()
            expect("hello world how are you")
            // Callbacks racing the stop don't change it.
            final("How", 1, at: 3.2, audio: 2.0...2.2)
            partial("bye", 2, at: 3.3, audio: 0.5...0.8)
            expect("hello world how are you")
        }
    }

    /// Scripts written without spaces still read growth as a continuation.
    func testUnspacedScriptGrowthAfterPause() {
        withAndWithoutTiming {
            acc.begin(segment: 1)
            partial("你好", at: 0.6, audio: 0.0...0.5)
            partial("你好吗", at: 2.1, audio: 0.0...0.8)
            expect("你好吗")
        }
    }

    // MARK: - Decided only by timing: the same words, different audio

    /// The speaker said "I saw", paused, then "I saw I went": the final holds only the
    /// second utterance, so the first stays even though the final starts with its words.
    func testLastUtteranceFinalRepeatingKeptPhraseKeepsIt() {
        acc.begin(segment: 1)
        partial("I saw", at: 0.6, audio: 0.0...0.5, ended: true)
        partial("I", at: 2.3, audio: 2.0...2.2)
        partial("I saw I went", at: 3.1, audio: 2.0...3.0)
        final("I saw I went", at: 4.0, audio: 2.0...3.0)
        expect("I saw I saw I went")
    }

    /// The same words, but the final covers the whole task: "I saw", pause, "I went".
    func testCumulativeFinalStartingWithKeptPhraseReplacesIt() {
        acc.begin(segment: 1)
        partial("I saw", at: 0.6, audio: 0.0...0.5, ended: true)
        partial("I went", at: 2.5, audio: 2.0...2.4)
        final("I saw I went", at: 3.4, audio: 0.0...2.4)
        expect("I saw I went")
    }

    /// A cumulative final that corrects the current utterance's first word ("How" was
    /// "who") still covers the kept utterance: it replaces it rather than repeating it.
    func testCumulativeFinalCorrectingFirstWordReplacesKept() {
        acc.begin(segment: 1)
        partial("Hello world", at: 0.9, audio: 0.0...0.8, ended: true)
        partial("How are", at: 2.6, audio: 2.0...2.5)
        final("Hello world who are you", at: 3.6, audio: 0.0...3.0)
        expect("Hello world who are you")
    }

    /// The same words, but the speaker said "hello world" again after the pause: the final
    /// holds only that utterance, so the kept one stays.
    func testLastUtteranceFinalRepeatingKeptUtteranceKeepsIt() {
        acc.begin(segment: 1)
        partial("Hello world", at: 0.9, audio: 0.0...0.8, ended: true)
        partial("How are", at: 2.6, audio: 2.0...2.5)
        final("Hello world who are you", at: 3.6, audio: 2.0...3.6)
        expect("Hello world Hello world who are you")
    }

    /// Words that start after the previous partial's audio ended are a new utterance, even
    /// arriving with no pause between callbacks.
    func testPartialAfterPreviousAudioIsNewUtterance() {
        acc.begin(segment: 1)
        partial("I want", at: 0.6, audio: 0.0...0.5)
        partial("I ate", at: 1.3, audio: 0.9...1.2)
        expect("I want I ate")
    }

    /// Words over the previous partial's audio revise it, even after a pause and sharing
    /// one word.
    func testPartialOverPreviousAudioIsRevision() {
        acc.begin(segment: 1)
        partial("I want to go home", at: 1.5, audio: 0.0...1.4)
        partial("I won't go", at: 2.8, audio: 0.0...1.4)
        expect("I won't go")
    }

    /// A cumulative final that drops trailing words ends before the audio already shown,
    /// but it starts with that audio and rewrites its words: it replaces everything shown.
    func testShorterCumulativeFinalReplacesKept() {
        acc.begin(segment: 1)
        partial("Hello world", at: 0.9, audio: 0.0...0.8)
        partial("How are you", at: 3.1, audio: 2.0...3.0)
        final("Hello world who are", at: 4.0, audio: 0.0...2.6)
        expect("Hello world who are")
    }

    /// A completed utterance the recognizer settles shorter is revised, not repeated.
    func testShorterSettledUtteranceReplacesIt() {
        acc.begin(segment: 1)
        partial("I want to go", at: 1.1, audio: 0.0...1.0, ended: true)
        final("I want to", at: 1.5, audio: 0.0...0.7)
        expect("I want to")
    }

    /// If the recognizer's clock restarted with the new utterance, its timing would claim
    /// it covers the earlier one. A result starting with the audio it would replace but
    /// sharing none of its words isn't trusted, and the words keep the earlier utterance.
    func testTimingRunningBackwardsKeepsEarlierUtterance() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.9, audio: 0.0...0.8)
        partial("how are", at: 2.5, audio: 0.0...0.4)
        expect("hello world how are")
    }

    /// The same, when the restarted utterance runs past the audio already shown.
    func testRestartedClockOutrunningShownAudioKeepsEarlierUtterance() {
        acc.begin(segment: 1)
        partial("hello world", at: 0.9, audio: 0.0...0.8)
        partial("how are you doing today", at: 3.5, audio: 0.0...1.4)
        expect("hello world how are you doing today")
    }

    // MARK: - Audio from word timing

    func testAudioSpansFirstWordStartToLastWordEnd() {
        let audio = TranscriptAccumulator.audio(ofSegments: [(2.0, 0.25), (2.5, 0.25), (2.75, 0.5)])
        XCTAssertEqual(audio, 2.0...3.25)
    }

    /// Zeroed timing would make every result look like it covers the whole task.
    func testZeroedTimingIsNoAudio() {
        XCTAssertNil(TranscriptAccumulator.audio(ofSegments: []))
        XCTAssertNil(TranscriptAccumulator.audio(ofSegments: [(0, 0), (0, 0)]))
        XCTAssertNil(TranscriptAccumulator.audio(ofSegments: [(0, 0.3), (0, 0.2)]))
    }
}
