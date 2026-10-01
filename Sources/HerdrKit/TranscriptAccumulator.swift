import Foundation

/// Turns the stream of `SFSpeechRecognizer` results of one dictation session into a
/// transcript that never loses dictated text.
///
/// The recognizer hands back the CURRENT best transcription of a recognition task on
/// every callback, and that string is not monotonic:
/// - On-device (iOS 18+), after a pause the task starts a new utterance and
///   `bestTranscription` restarts from the new words, with no `isFinal` for the earlier
///   ones; its final result then holds only the last utterance.
/// - Otherwise, and in some finals, a result covers the whole task so far.
/// - The recognizer revises recent words as it goes, and a settled result can rewrite or
///   drop some of them.
/// - The driver rolls each task over before the ~1-minute ceiling: the rolled task still
///   owes its final (the tail it recognised after the swap) while the next one runs.
///
/// One invariant covers all of these: shown words are replaced only by a result that
/// demonstrably re-transcribes them; any other result is a new utterance and is appended.
/// Losing words is never acceptable; a rare repeat is the lesser harm.
///
/// The driver reports each recognition task as a segment (`begin`), every result for it
/// (`result`), a task that died without a final (`end`) and the session's end
/// (`finish`). Each segment holds its utterances in order; segments stay in dictation
/// order, so a rolled segment's late final lands in place.
///
/// Pure value type: no Speech/AVFoundation dependency, so it is unit-testable off-device.
public struct TranscriptAccumulator: Equatable, Sendable {
    /// Text of segments that are finished, and of every segment before them.
    private var done = ""
    /// Live segments in dictation order: the active one last, rolled ones before it.
    private var segments: [Segment] = []

    public init() {}

    /// The full transcript: finished text, then every live segment, single-spaced.
    public var text: String {
        Self.join([done] + segments.map(\.text))
    }

    /// A recognition task (segment `id`) begins. Earlier unfinished segments stay: they
    /// were rolled away from and still owe their final.
    public mutating func begin(segment id: Int) {
        segments.append(Segment(id: id))
    }

    /// A recognition result for segment `id`. `audio` is where the result's words sit in
    /// the task's audio (see `audio(ofSegments:)`), nil when unknown. Results for an
    /// unknown or finished segment are ignored.
    public mutating func result(
        _ text: String, segment id: Int, isFinal: Bool, audio: ClosedRange<TimeInterval>?
    ) {
        guard let i = segments.firstIndex(where: { $0.id == id }), !segments[i].finished else { return }
        segments[i].take(text.trimmingCharacters(in: .whitespacesAndNewlines), audio: audio)
        if isFinal { close(at: i) }
    }

    /// The stretch of a task's audio a transcription covers, from its words' timing
    /// (`SFTranscriptionSegment.timestamp` and `duration`, seconds from the task's start):
    /// the first word's start to the last word's end. Nil when there are no words or the
    /// timing isn't real — the recognizer can leave it zeroed.
    public static func audio(
        ofSegments words: [(timestamp: TimeInterval, duration: TimeInterval)]
    ) -> ClosedRange<TimeInterval>? {
        guard let first = words.first, let last = words.last else { return nil }
        // Each word starts after the one before it; zeroed timing has them all at 0.
        guard zip(words, words.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else { return nil }
        let end = last.timestamp + last.duration
        return end > first.timestamp ? first.timestamp...end : nil
    }

    /// Segment `id`'s task ended without a final (an error or cancel): keep its text.
    public mutating func end(segment id: Int) {
        guard let i = segments.firstIndex(where: { $0.id == id }), !segments[i].finished else { return }
        close(at: i)
    }

    /// The session stops: keep everything shown and ignore any later results.
    public mutating func finish() {
        done = text
        segments = []
    }

    /// Clear everything for a new dictation session.
    public mutating func reset() {
        done = ""
        segments = []
    }

    /// Segment `i` is complete: later results for it are ignored. Finished segments at the
    /// head fold into `done`; one that finishes before an earlier rolled segment waits in
    /// place, so that segment's late final still lands before it.
    private mutating func close(at i: Int) {
        segments[i].finished = true
        let n = segments.prefix(while: \.finished).count
        done = Self.join([done] + segments[..<n].map(\.text))
        segments.removeFirst(n)
    }

    static func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// One recognition task's utterances, in order.
    struct Segment: Equatable, Sendable {
        struct Utterance: Equatable, Sendable {
            let text: String
            let words: [String]
            let audio: ClosedRange<TimeInterval>?
        }

        let id: Int
        var utterances: [Utterance] = []
        var finished = false

        var text: String { TranscriptAccumulator.join(utterances.map(\.text)) }

        /// Take a result: it replaces the utterances it re-transcribes, or follows them.
        mutating func take(_ text: String, audio: ClosedRange<TimeInterval>?) {
            let words = Words.normalized(text)
            // An empty result keeps the text it would otherwise erase.
            guard !words.isEmpty else { return }
            let from = retranscribed(by: words, audio: audio)
            utterances.replaceSubrange(from..., with: [Utterance(text: text, words: words, audio: audio)])
        }

        /// The first of the utterances a result re-transcribes; `utterances.count` when it
        /// re-transcribes none.
        ///
        /// A result always starts at an utterance's start, so the candidates are the runs
        /// from each utterance to the last. A run is re-transcribed when the result starts
        /// with the run's first word, brings back at least one of its words unchanged, and
        /// in order re-transcribes at least 2/3 of its words (`Words.aligned`): a settled
        /// result rewrites or drops a few. When timing shows the result starting with the
        /// run's audio, half (and at least two words) is enough. The best-agreeing run is
        /// replaced, the longer one on a tie.
        ///
        /// Timing only ever keeps words: a run whose first utterance ended before the
        /// result's first word began is not re-transcribed by it, whatever its words.
        func retranscribed(by result: [String], audio: ClosedRange<TimeInterval>?) -> Int {
            var best = utterances.count
            var bestAligned = 0, bestCount = 1
            for k in utterances.indices {
                var startsWithRun = false
                if let audio, let first = utterances[k].audio {
                    if first.upperBound <= audio.lowerBound { continue }
                    startsWithRun = audio.lowerBound <= first.lowerBound
                }
                let run = utterances[k...].flatMap(\.words)
                guard let aligned = Words.aligned(run, with: result) else { continue }
                let agrees = aligned * 3 >= run.count * 2
                    || (startsWithRun && aligned >= 2 && aligned * 2 >= run.count)
                guard agrees else { continue }
                if best == utterances.count || aligned * bestCount > bestAligned * run.count {
                    best = k
                    bestAligned = aligned
                    bestCount = run.count
                }
            }
            return best
        }
    }
}

/// Words compared across recognizer results: case, punctuation and formatting don't
/// count, and a word the recognizer revised to a similar one still lines up.
enum Words {
    static func normalized(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init)) }
            .filter { !$0.isEmpty }
    }

    /// How many of `run`'s words `result` re-transcribes, in order, or nil when it doesn't
    /// start with the run's first word, or when nothing but slips line up: a result
    /// re-transcribes words only if at least one of them comes back as the same word.
    static func aligned(_ run: [String], with result: [String]) -> Int? {
        guard let a = run.first, let b = result.first, similar(a, b),
              run.contains(where: { w in result.contains { same(w, $0) } }) else { return nil }
        return 1 + commonSubsequence(run.dropFirst(), result.dropFirst())
    }

    /// Length of the longest common subsequence of similar words.
    static func commonSubsequence(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Int {
        let b = Array(b)
        guard !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = similar(x, b[j]) ? diagonal + 1 : max(above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Whether the recognizer could have revised one word into the other: the same word
    /// (see `same`) or a slip of a letter or two ("want"/"wont", "halo"/"hello").
    static func similar(_ a: String, _ b: String) -> Bool {
        if same(a, b) { return true }
        let x = Array(a), y = Array(b)
        let short = min(x.count, y.count), long = max(x.count, y.count)
        let limit = short >= 4 ? 2 : long >= 3 ? 1 : 0
        return long - short <= limit && distance(x, y) <= limit
    }

    /// The same word as the recognizer writes it: identical, a homophone, or one cut short
    /// ("hel"/"hello"; a phrase in a script written without spaces is one word, so
    /// "你好"/"你好吗").
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let group = homophones[a], group == homophones[b] { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return long.hasPrefix(short) && short.count >= (short.allSatisfy(\.isASCII) ? 3 : 1)
    }

    /// Words the recognizer swaps for one another as it settles.
    private static let homophones: [String: Int] = {
        let groups = [
            ["i", "eye", "aye"], ["to", "too", "two"], ["for", "four"], ["there", "their", "theyre"],
            ["your", "youre"], ["no", "know"], ["right", "write"], ["hear", "here"],
            ["by", "buy", "bye"], ["one", "won"], ["new", "knew"], ["ate", "eight"],
        ]
        var map: [String: Int] = [:]
        for (i, group) in groups.enumerated() { for word in group { map[word] = i } }
        return map
    }()

    /// Levenshtein distance between two words' characters.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = x == y ? diagonal : 1 + min(diagonal, above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }
}
