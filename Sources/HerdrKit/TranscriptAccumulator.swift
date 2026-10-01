import Foundation

/// Turns the stream of `SFSpeechRecognizer` results of one dictation session into a
/// transcript that never loses dictated text.
///
/// The recognizer hands back the CURRENT best transcription of a recognition task on
/// every callback, and that string is not monotonic:
/// - On-device (iOS 18+), after a pause the task starts a new utterance and
///   `bestTranscription` restarts from the new words, with no `isFinal` for the earlier
///   ones; its final result then holds only the last utterance. Taking the latest string
///   as the segment's text deletes everything said before the pause.
/// - The driver rolls each task over before the ~1-minute ceiling: the rolled task still
///   owes its final (the tail it recognised after the swap) while the next one runs.
/// - Within an utterance the recognizer revises recent words; those revisions must
///   REPLACE the earlier text, not repeat it.
///
/// The driver reports each recognition task as a segment (`begin`), every result for it
/// (`result`), a task that died without a final (`end`) and the session's end
/// (`finish`). Each segment keeps the utterances a restart superseded plus the current
/// one; segments stay in dictation order, so a rolled segment's late final replaces its
/// own provisional text in place.
///
/// Where a result's words sit in the task's audio decides what it replaces: it
/// transcribes everything from its first word on, so utterances that ended before that
/// stay and the rest give way to it. A cumulative result starts with the task's first
/// word; a restarted one starts after the pause. Only when timing is missing or
/// inconsistent do the words themselves decide (see `Words.startsNewUtterance`).
///
/// Pure value type: no Speech/AVFoundation dependency, so it is unit-testable off-device.
public struct TranscriptAccumulator: Equatable, Sendable {
    /// Silence (seconds since the current utterance's text last changed) after which a
    /// result that does not continue it is read as a new utterance rather than a revision.
    /// The recognizer only restarts after a pause, while it revises as words arrive.
    public static let pauseGap: TimeInterval = 1.0

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

    /// A recognition result for segment `id`. `utteranceEnded` is true when the recognizer
    /// marked this result as a complete utterance (it carries
    /// `speechRecognitionMetadata`); `audio` is where the result's words sit in the task's
    /// audio (see `audio(ofSegments:)`), nil when unknown; `time` is a monotonic clock
    /// reading in seconds. Results for an unknown or finished segment are ignored.
    public mutating func result(
        _ text: String, segment id: Int, isFinal: Bool, utteranceEnded: Bool,
        audio: ClosedRange<TimeInterval>?, at time: TimeInterval
    ) {
        guard let i = segments.firstIndex(where: { $0.id == id }), !segments[i].finished else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            segments[i].settle(final: t, audio: audio)
            close(at: i)
        } else {
            segments[i].observe(t, audio: audio, ended: utteranceEnded, at: time)
        }
    }

    /// The stretch of a task's audio a transcription covers, from its words' timing
    /// (`SFTranscriptionSegment.timestamp` and `duration`, seconds from the task's start):
    /// the first word's start to the last word's end. Nil when there are no words or the
    /// timing isn't real — the recognizer can leave it zeroed — so results without it fall
    /// back to comparing words.
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

    /// One recognition task's text: utterances a restart superseded, then the current one.
    struct Segment: Equatable, Sendable {
        struct Utterance: Equatable, Sendable {
            var text: String
            var audio: ClosedRange<TimeInterval>?
        }

        let id: Int
        var utterances: [Utterance] = []
        /// The current utterance's latest text, and where it sits in the task's audio.
        var partial = ""
        var partialAudio: ClosedRange<TimeInterval>?
        /// When `partial` last changed.
        var changedAt: TimeInterval = 0
        /// The recognizer marked `partial` as a complete utterance.
        var ended = false
        var finished = false

        var text: String { TranscriptAccumulator.join(utterances.map(\.text) + [partial]) }

        mutating func observe(
            _ t: String, audio: ClosedRange<TimeInterval>?, ended isEnd: Bool, at time: TimeInterval
        ) {
            if !t.isEmpty {
                let gap = time - changedAt
                if t != partial { changedAt = time }
                if !place(t, audio: audio) {
                    if Words.startsNewUtterance(after: partial, next: t, ended: ended, gap: gap) {
                        utterances.append(Utterance(text: partial, audio: partialAudio))
                    }
                    partial = t
                    partialAudio = audio
                }
            }
            // An empty result keeps the text it would otherwise erase.
            if !partial.isEmpty { ended = isEnd }
        }

        mutating func settle(final f: String, audio: ClosedRange<TimeInterval>?) {
            let fw = Words(f)
            // An empty final keeps what was shown.
            guard !fw.isEmpty else { return }
            defer { ended = true }
            if place(f, audio: audio) { return }
            // Without timing: a cumulative final (the whole task's text, as before iOS 18)
            // after a restart was taken for the earlier words: it supersedes them rather
            // than repeating them. Only a final that is every kept utterance followed by the
            // current one is one; a final holding just the last utterance leaves them be,
            // even when that utterance starts with the same words.
            let kept = Words(TranscriptAccumulator.join(utterances.map(\.text))).joined
            let current = Words(partial).words.first ?? ""
            if !kept.isEmpty, fw.joined.hasPrefix(kept),
               case let rest = fw.joined.dropFirst(kept.count), !rest.isEmpty, rest.hasPrefix(current) {
                utterances = []
            } else if ended, Words.startsNewUtterance(after: partial, next: f, ended: true, gap: 0) {
                // Otherwise the final is the settled text of the utterance on screen, however
                // much it rewrote it, unless that utterance was already marked complete.
                utterances.append(Utterance(text: partial, audio: partialAudio))
            }
            partial = f
            partialAudio = audio
        }

        /// Place a result by where its audio STARTS: it transcribes everything from its first
        /// word on, so it replaces the utterances that hadn't ended by then and keeps those
        /// before — however early it ends, since a settled result can drop trailing words.
        /// Returns false, deciding nothing, when the result or any utterance shown lacks
        /// timing, or when the clock may have restarted: a result starting with all the audio
        /// it would replace yet sharing none of its leading words is a new utterance timed
        /// from zero as far as anyone can tell, so the words decide.
        private mutating func place(_ t: String, audio: ClosedRange<TimeInterval>?) -> Bool {
            guard let audio else { return false }
            var shown = utterances
            if !partial.isEmpty { shown.append(Utterance(text: partial, audio: partialAudio)) }
            let spans = shown.compactMap(\.audio)
            guard spans.count == shown.count else { return false }
            let kept = spans.prefix(while: { $0.upperBound <= audio.lowerBound }).count
            if kept < spans.count, audio.lowerBound <= spans[kept].lowerBound {
                let replaced = Words(TranscriptAccumulator.join(shown[kept...].map(\.text)))
                guard Words(t).rewrites(replaced) else { return false }
            }
            utterances = Array(shown.prefix(kept))
            partial = t
            partialAudio = audio
            return true
        }
    }
}

/// Normalized words for comparing recognizer results: case, punctuation and the
/// recognizer's formatting changes don't count as different words.
struct Words: Equatable {
    let words: [String]
    /// The words run together, so a result that extends a word or a script written
    /// without spaces still reads as a continuation.
    let joined: String

    init(_ s: String) {
        words = s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init)) }
            .filter { !$0.isEmpty }
        joined = words.joined()
    }

    var count: Int { words.count }
    var isEmpty: Bool { words.isEmpty }

    func commonPrefix(with other: Words) -> Int {
        zip(words, other.words).prefix(while: { $0 == $1 }).count
    }

    /// Whether `self` reads as a rewrite of `other` rather than different speech: it keeps
    /// the first word, or one run-together text starts with the other (scripts without
    /// spaces, where a whole phrase is one "word").
    func rewrites(_ other: Words) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return commonPrefix(with: other) >= 1 || joined.hasPrefix(other.joined) || other.joined.hasPrefix(joined)
    }

    /// Whether `next` starts a new utterance after `previous` (which must be kept) rather
    /// than continuing or revising it (which replaces it).
    static func startsNewUtterance(
        after previous: String, next: String, ended: Bool, gap: TimeInterval
    ) -> Bool {
        let p = Words(previous), n = Words(next)
        guard !p.isEmpty, !n.isEmpty else { return false }
        // Same words, or more words after them: the same utterance going on.
        if n.joined.hasPrefix(p.joined) { return false }
        // The recognizer said the previous utterance was complete.
        if ended { return true }
        let c = n.commonPrefix(with: p)
        // After a pause the recognizer only settles what it already has: it replaces the
        // last word or drops a stray one, keeping at least two words ahead of the change.
        // Anything else that doesn't continue the previous text is a new utterance — even
        // one starting with the same words — and keeping it costs at most a repeat, where
        // replacing would lose words.
        if gap >= TranscriptAccumulator.pauseGap {
            return !n.settlesTail(of: p, keeping: c)
        }
        // While speaking, only a clean break reads as a restart: a different first word
        // and either fewer words or none in common. A revision of the first word keeps
        // the rest.
        guard c == 0 else { return false }
        return n.count < p.count || (p.count >= 2 && Set(n.words).isDisjoint(with: p.words))
    }

    /// Whether `self` is `previous` with its tail settled: the first `kept` (≥ 2) words
    /// unchanged, then either the last word replaced at the same length or some of the
    /// tail's words dropped.
    private func settlesTail(of previous: Words, keeping kept: Int) -> Bool {
        guard kept >= 2, count <= previous.count else { return false }
        let old = previous.words[kept...], new = words[kept...]
        if count == previous.count, old.count == 1 { return true }
        var rest = old[...]
        for word in new {
            guard let i = rest.firstIndex(of: word) else { return false }
            rest = rest[(i + 1)...]
        }
        return true
    }
}
