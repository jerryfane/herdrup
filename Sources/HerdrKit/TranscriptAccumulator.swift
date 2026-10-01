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
    /// `speechRecognitionMetadata`); `time` is a monotonic clock reading in seconds.
    /// Results for an unknown or finished segment are ignored.
    public mutating func result(
        _ text: String, segment id: Int, isFinal: Bool, utteranceEnded: Bool, at time: TimeInterval
    ) {
        guard let i = segments.firstIndex(where: { $0.id == id }), !segments[i].finished else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            segments[i].settle(final: t)
            close(at: i)
        } else {
            segments[i].observe(t, ended: utteranceEnded, at: time)
        }
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
        let id: Int
        var utterances: [String] = []
        /// The current utterance's latest text.
        var partial = ""
        /// When `partial` last changed.
        var changedAt: TimeInterval = 0
        /// The recognizer marked `partial` as a complete utterance.
        var ended = false
        var finished = false

        var text: String { TranscriptAccumulator.join(utterances + [partial]) }

        mutating func observe(_ t: String, ended isEnd: Bool, at time: TimeInterval) {
            if !t.isEmpty {
                if Words.startsNewUtterance(after: partial, next: t, ended: ended, gap: time - changedAt) {
                    utterances.append(partial)
                }
                if t != partial { changedAt = time }
                partial = t
            }
            // An empty result keeps the text it would otherwise erase.
            if !partial.isEmpty { ended = isEnd }
        }

        mutating func settle(final f: String) {
            let fw = Words(f)
            // An empty final keeps what was shown.
            guard !fw.isEmpty else { return }
            // A cumulative final (the whole task's text, as before iOS 18) after a restart
            // was taken for the earlier words: it supersedes them rather than repeating them.
            // Only a final that is every kept utterance followed by the current one is one; a
            // final holding just the last utterance leaves them be, even when that utterance
            // starts with the same words.
            let kept = Words(TranscriptAccumulator.join(utterances)).joined
            let current = Words(partial).words.first ?? ""
            if !kept.isEmpty, fw.joined.hasPrefix(kept),
               case let rest = fw.joined.dropFirst(kept.count), !rest.isEmpty, rest.hasPrefix(current) {
                utterances = []
                partial = f
                return
            }
            // Otherwise the final is the settled text of the utterance on screen, however much
            // it rewrote it, unless that utterance was already marked complete.
            if ended, Words.startsNewUtterance(after: partial, next: f, ended: true, gap: 0) {
                utterances.append(partial)
            }
            partial = f
            ended = true
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
        // After a pause, keeping less than half of the previous words is a new utterance; a
        // late revision keeps most of them.
        if gap >= TranscriptAccumulator.pauseGap {
            return Double(c) < max(1, Double(p.count) / 2)
        }
        // While speaking, only a clean break reads as a restart: a different first word
        // and either fewer words or none in common. A revision of the first word keeps
        // the rest.
        guard c == 0 else { return false }
        return n.count < p.count || (p.count >= 2 && Set(n.words).isDisjoint(with: p.words))
    }
}
