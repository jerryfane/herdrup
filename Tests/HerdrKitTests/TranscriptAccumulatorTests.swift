import XCTest
@testable import HerdrKit

/// Recognizer callback sequences shaped like what `SFSpeechRecognizer` delivers on device,
/// each run with word timing (`audio`: where a result's words sit in the task's audio)
/// and, unless only timing can decide it, again with the timing stripped.
final class TranscriptAccumulatorTests: XCTestCase {
    private enum Event {
        case begin(Int)
        /// `restart`: the recognizer began a new utterance here (what was said, not
        /// something the accumulator is told), so the previous result's words must stay.
        case partial(String, segment: Int, audio: ClosedRange<TimeInterval>?, restart: Bool)
        case final(String, segment: Int, audio: ClosedRange<TimeInterval>?)
        case end(Int)
        case finish
        /// The transcript at this point, in either run.
        case expect(String)
    }

    private struct Scenario {
        let name: String
        let events: [Event]
        /// The transcript at the end, with timing.
        let expected: String
        /// The transcript at the end without timing; nil when only timing can decide.
        let untimed: String?
    }

    private static func p(
        _ text: String, _ audio: ClosedRange<TimeInterval>?, seg: Int = 1, restart: Bool = false
    ) -> Event {
        .partial(text, segment: seg, audio: audio, restart: restart)
    }

    private static func f(_ text: String, _ audio: ClosedRange<TimeInterval>?, seg: Int = 1) -> Event {
        .final(text, segment: seg, audio: audio)
    }

    private static func both(_ name: String, _ expected: String, _ events: [Event]) -> Scenario {
        Scenario(name: name, events: [.begin(1)] + events, expected: expected, untimed: expected)
    }

    private static func timedOnly(_ name: String, _ expected: String, _ events: [Event]) -> Scenario {
        Scenario(name: name, events: [.begin(1)] + events, expected: expected, untimed: nil)
    }

    private static let scenarios: [Scenario] = [
        // iOS 18 on-device: after a pause `bestTranscription` restarts from the new words
        // with no final for the earlier ones, and the final holds only the last utterance.
        both("pause reset keeps the earlier utterance", "hello world How are you?", [
            p("hello", 0.0...0.4), p("hello world", 0.0...0.9),
            p("how are", 2.4...2.9, restart: true), .expect("hello world how are"),
            p("how are you", 2.4...3.2), .expect("hello world how are you"),
            f("How are you?", 2.4...3.3),
        ]),
        both("a new utterance with the previous one's first word is still new", "I went home I ate", [
            p("I", 0.0...0.2), p("I went home", 0.0...0.9),
            p("I", 2.5...2.7, restart: true), p("I ate", 2.5...3.0),
        ]),
        both("a completed utterance is kept apart from the next", "Hello world how", [
            p("hello world", 0.0...0.8), p("Hello world", 0.0...0.8), p("how", 1.3...1.5, restart: true),
        ]),
        both("revisions replace rather than duplicate", "I want to go to the store.", [
            p("Eye", 0.0...0.2), p("I want", 0.0...0.5), p("I want to to", 0.0...0.8),
            p("I want to go", 0.0...0.9), p("I want to go to the store", 0.0...1.5),
            .expect("I want to go to the store"),
            // The recognizer settles the utterance after the speaker stops.
            p("I want to go to the store.", 0.0...1.5), .expect("I want to go to the store."),
            f("I want to go to the store.", 0.0...1.5),
        ]),
        both("a late revision dropping a stuttered word replaces", "I want to go", [
            p("I want to to go", 0.0...1.2), p("I want to go", 0.0...1.2),
        ]),
        both("a late revision of the last word replaces", "I saw that", [
            p("I saw it", 0.0...0.8), p("I saw that", 0.0...0.8),
        ]),
        both("a restart sharing the first word keeps the earlier utterance", "I want I ate", [
            p("I want", 0.0...0.5), p("I ate", 2.0...2.5, restart: true),
        ]),
        both("a restart sharing most leading words keeps the earlier utterance", "I want to go home I want to eat", [
            p("I want to go home", 0.0...1.4), p("I want to eat", 3.0...3.9, restart: true),
        ]),
        // Before iOS 18 a task's text keeps growing across pauses, and its final is the
        // whole task's text.
        both("a cumulative recognizer doesn't duplicate", "Hello world, how are you?", [
            p("hello world", 0.0...0.8), p("hello world how are you", 0.0...2.8),
            .expect("hello world how are you"), f("Hello world, how are you?", 0.0...2.8),
        ]),
        both("a whole-task final after a restart doesn't duplicate", "Hello world how are you.", [
            p("hello world", 0.0...0.8), p("how are you", 2.0...2.8, restart: true),
            f("Hello world how are you.", 0.0...2.8),
        ]),
        both("a last-utterance final sharing the kept first word keeps it", "I saw I ate a lot", [
            p("I saw", 0.0...0.5), p("I ate", 2.0...2.4, restart: true), f("I ate a lot", 2.0...2.9),
        ]),
        both("a last-utterance final after a completed utterance keeps it", "I went I walked home", [
            p("I", 0.0...0.2), p("I went", 0.0...0.5),
            p("I walked", 2.0...2.5, restart: true), f("I walked home", 2.0...2.9),
        ]),
        both("a last-utterance final settling on the kept word keeps both", "Hello Hello there.", [
            p("Hello", 0.0...0.4), p("Halo there", 2.0...2.6, restart: true), f("Hello there.", 2.0...2.6),
        ]),
        both("a final, then a new task", "Hello world How are you? fine thanks", [
            p("hello world", 0.0...0.8), p("Hello world", 0.0...0.8),
            p("how are", 1.6...2.0, restart: true), f("How are you?", 1.6...2.4),
            .expect("Hello world How are you?"),
            .begin(2), p("fine", 0.3...0.6, seg: 2), p("fine thanks", 0.3...0.9, seg: 2),
        ]),
        // The rolled task had restarted, so its final holds only its last utterance. Each
        // task's timing counts from its own start.
        both("a rolled task's late final lands in order", "one two three four five six", [
            p("one two", 0.0...0.6), p("three four", 2.0...2.6, restart: true),
            .begin(2), p("six", 0.2...0.5, seg: 2), .expect("one two three four six"),
            f("three four five", 2.0...3.1), .expect("one two three four five six"),
            // The retired task says nothing more.
            p("zzz", 3.2...3.3),
        ]),
        both("the new task finalizing before the rolled one keeps order", "one two three Four five. six", [
            p("one two", 0.0...0.6),
            .begin(2), p("four five", 0.1...0.6, seg: 2), f("Four five.", 0.1...0.6, seg: 2),
            .begin(3), f("one two three", 0.0...1.0), p("six", 0.2...0.4, seg: 3),
        ]),
        both("an errored task keeps its text through the next roll", "one two three four five", [
            p("one two", 0.0...0.6), .end(1),
            .begin(2), p("three", 0.1...0.4, seg: 2),
            .begin(3), f("three four", 0.1...0.9, seg: 2), p("five", 0.1...0.4, seg: 3),
        ]),
        both("empty results keep the text", "hello world", [
            p("hello world", 0.0...0.8), p("", nil), .expect("hello world"), f("", nil),
        ]),
        // Callbacks racing the stop don't change it.
        both("stop after a pause keeps everything", "hello world how are you", [
            p("hello world", 0.0...0.8), p("how are", 2.0...2.5, restart: true),
            .begin(2), p("you", 0.1...0.3, seg: 2), .finish,
            f("How", 2.0...2.2), p("bye", 0.5...0.8, seg: 2),
        ]),
        both("a script without spaces grows as one word", "你好吗", [
            p("你好", 0.0...0.5), p("你好吗", 0.0...0.8),
        ]),

        // Only timing can decide these: the same words, different audio.
        timedOnly("a last-utterance final repeating the kept phrase keeps it", "I saw I saw I went", [
            p("I saw", 0.0...0.5), p("I", 2.0...2.2, restart: true),
            p("I saw I went", 2.0...3.0), f("I saw I went", 2.0...3.0),
        ]),
        timedOnly("a cumulative final starting with the kept phrase replaces it", "I saw I went", [
            p("I saw", 0.0...0.5), p("I went", 2.0...2.4, restart: true), f("I saw I went", 0.0...2.4),
        ]),
        both("a cumulative final correcting a first word replaces the kept utterance", "Hello world who are you", [
            p("Hello world", 0.0...0.8), p("How are", 2.0...2.5, restart: true),
            f("Hello world who are you", 0.0...3.0),
        ]),
        // The speaker said "hello world" again after the pause. "How are" shares no
        // leading word with the final, so it stays too: a repeat, never a loss.
        timedOnly("a last-utterance final repeating the kept utterance keeps it", "Hello world How are Hello world who are you", [
            p("Hello world", 0.0...0.8), p("How are", 2.0...2.5, restart: true),
            f("Hello world who are you", 2.0...3.6),
        ]),
        timedOnly("words after the previous audio are a new utterance", "I want I ate", [
            p("I want", 0.0...0.5), p("I ate", 0.9...1.2, restart: true),
        ]),
        timedOnly("words over the previous audio revise it", "I won't go", [
            p("I want to go home", 0.0...1.4), p("I won't go", 0.0...1.4),
        ]),
        // A cumulative final that drops trailing words; without timing it can't be told
        // from a new utterance, so the earlier text stays.
        Scenario(name: "a shorter cumulative final replaces the kept utterance", events: [
            .begin(1), p("Hello world", 0.0...0.8), p("How are you", 2.0...3.0, restart: true),
            f("Hello world who are", 0.0...2.6),
        ], expected: "Hello world who are", untimed: "Hello world How are you Hello world who are"),
        both("a completed utterance settled shorter is replaced", "I want to", [
            p("I want to go", 0.0...1.0), f("I want to", 0.0...0.7),
        ]),
        // If the recognizer's clock restarted with the new utterance, its timing would
        // claim it covers the earlier one; the words say otherwise.
        both("a restarted clock keeps the earlier utterance", "hello world how are", [
            p("hello world", 0.0...0.8), p("how are", 0.0...0.4, restart: true),
        ]),
        both("a restarted clock outrunning the shown audio keeps the earlier utterance",
             "hello world how are you doing today", [
            p("hello world", 0.0...0.8), p("how are you doing today", 0.0...1.4, restart: true),
        ]),

        // Review repros, each of which once lost or repeated text.
        both("review 1: last-utterance final after a restart", "I saw I ate a lot", [
            p("I saw", nil), p("I ate", nil, restart: true), f("I ate a lot", nil),
        ]),
        both("review 1: last-utterance final after a revised utterance", "I went I walked home", [
            p("I", nil), p("I went", nil), p("I walked", nil, restart: true), f("I walked home", nil),
        ]),
        both("review 1: restart keeping half the words", "I want I ate", [
            p("I want", nil), p("I ate", nil, restart: true),
        ]),
        timedOnly("review 2: last-utterance final repeating the kept phrase", "I saw I saw I went", [
            p("I saw", 0.0...0.5), p("I", 2.0...2.2, restart: true), p("I saw I went", 2.0...3.0),
            f("I saw I went", 2.0...3.0),
        ]),
        both("review 2: cumulative final correcting the first word", "Hello world who are you", [
            p("Hello world", nil), p("How are", nil, restart: true), f("Hello world who are you", nil),
        ]),
        timedOnly("review 3: shorter cumulative final", "Hello world who are", [
            p("Hello world", 0.0...0.8), p("How are you", 2.0...3.0, restart: true),
            f("Hello world who are", 0.0...2.6),
        ]),
        both("review 3: completed utterance settled shorter", "I want to", [
            p("I want to go", 0.0...1.0), f("I want to", 0.0...0.7),
        ]),
        both("review 4: restarted clock starting after zero", "hello world how are", [
            p("hello world", 0.0...0.8), p("how are", 0.1...0.4, restart: true),
        ]),
        both("review 4: final correcting a completed utterance's first word", "I want to go", [
            p("Eye want to go", 0.0...1.0), f("I want to go", 0.0...1.0),
        ]),
    ]

    private func run(_ scenario: Scenario, timed: Bool) -> String {
        var acc = TranscriptAccumulator()
        for (step, event) in scenario.events.enumerated() {
            switch event {
            case .begin(let id): acc.begin(segment: id)
            case let .partial(text, segment, audio, _):
                acc.result(text, segment: segment, isFinal: false, audio: timed ? audio : nil)
            case let .final(text, segment, audio):
                acc.result(text, segment: segment, isFinal: true, audio: timed ? audio : nil)
            case .end(let id): acc.end(segment: id)
            case .finish: acc.finish()
            case .expect(let text):
                XCTAssertEqual(acc.text, text, "\(scenario.name), step \(step), \(timed ? "timed" : "untimed")")
            }
        }
        return acc.text
    }

    private func runs(_ scenario: Scenario) -> [(timed: Bool, expected: String)] {
        [(true, scenario.expected)] + (scenario.untimed.map { [(false, $0)] } ?? [])
    }

    func testScenarios() {
        for scenario in Self.scenarios {
            for (timed, expected) in runs(scenario) {
                XCTAssertEqual(run(scenario, timed: timed), expected, "\(scenario.name), \(timed ? "timed" : "untimed")")
            }
        }
    }

    /// No dictated word is lost: every word of every final, and of every result the
    /// recognizer moved on from by starting a new utterance, is still in the transcript.
    func testNoDictatedWordIsLost() {
        for scenario in Self.scenarios {
            var sources: [String] = []
            var last: [Int: String] = [:]
            // Results after the stop are ignored by design.
            events: for event in scenario.events {
                switch event {
                case let .partial(text, segment, _, restart):
                    if restart, let previous = last[segment] { sources.append(previous) }
                    last[segment] = text
                case let .final(text, segment, _):
                    sources.append(text)
                    last[segment] = nil
                case .begin, .end, .expect: continue
                case .finish: break events
                }
            }
            for (timed, _) in runs(scenario) {
                let have = Self.counts(run(scenario, timed: timed))
                for source in sources {
                    for (word, n) in Self.counts(source) where have[word, default: 0] < n {
                        XCTFail("\(scenario.name), \(timed ? "timed" : "untimed"): lost \"\(word)\" of \"\(source)\"")
                    }
                }
            }
        }
    }

    private static func counts(_ text: String) -> [String: Int] {
        Words.normalized(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
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
