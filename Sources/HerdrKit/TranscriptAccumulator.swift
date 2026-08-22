import Foundation

/// Keeps a dictation transcript MONOTONIC across the underlying recognizer's
/// segment boundaries.
///
/// `SFSpeechRecognizer` hands back the CURRENT segment's best transcription each
/// callback, and near its implicit ~1-minute ceiling it re-segments so that string
/// SHRINKS — dropping its head. If the field is set straight from that latest partial,
/// the earlier dictated text is lost. This type separates the finalized text
/// (`committed`) from the in-progress `partial`: the exposed transcript is
/// `committed` + `partial`, so it never falls below what was already committed. The
/// dictation driver commits a segment (on a final result or a rolling restart) before
/// the recognizer can drop it, then keeps going — making dictation effectively
/// unbounded and loss-free.
///
/// Pure value type: no Speech/AVFoundation dependency, so it is unit-testable off-device.
public struct TranscriptAccumulator: Equatable, Sendable {
    /// The finalized text so far this session. Only ever grows (until `reset`).
    public private(set) var committed: String = ""

    public init() {}

    /// The full transcript given the current in-progress `partial`: `committed`
    /// joined to `partial` by a single space, skipping the space when either side is
    /// empty. Never shorter than `committed`.
    public func text(withPartial partial: String) -> String {
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return p }
        if p.isEmpty { return committed }
        return committed + " " + p
    }

    /// Fold the current `partial` into `committed` (idempotent for an empty partial).
    /// After this, `text(withPartial: "")` returns the folded whole.
    public mutating func commit(_ partial: String) {
        committed = text(withPartial: partial)
    }

    /// Clear everything for a new dictation session.
    public mutating func reset() {
        committed = ""
    }
}
