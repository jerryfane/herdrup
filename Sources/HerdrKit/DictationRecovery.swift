import Foundation

/// What the dictation driver does after one recognition callback, and the cap on
/// error-driven rolls, so a PERSISTENT failure (asset evicted, dictation disabled
/// mid-session) stops with a note instead of churning new tasks forever.
///
/// Only the active segment's callbacks decide anything: a rolled segment's late final or
/// error neither starts a segment nor counts toward, or clears, the cap.
///
/// Pure value type: no Speech dependency, so it is unit-testable off-device.
public struct DictationRecovery: Equatable, Sendable {
    public enum Next: Equatable, Sendable {
        /// Keep listening on the current segment.
        case keepListening
        /// The active segment finalized on a pause: start the next one.
        case nextSegment
        /// The active task failed: roll to a fresh segment.
        case roll
        /// Too many failures in a row: stop dictation.
        case stop
    }

    /// Consecutive failed active tasks after which dictation stops.
    public static let maxErrorRolls = 3

    /// Consecutive failed active tasks with no active result since.
    public private(set) var errorRolls = 0

    public init() {}

    /// Decide after a callback for a segment. A callback can carry a result AND an error;
    /// the error wins, since the task is over either way.
    public mutating func after(activeSegment: Bool, hasResult: Bool, isFinal: Bool, failed: Bool) -> Next {
        guard activeSegment else { return .keepListening }
        if failed {
            errorRolls += 1
            return errorRolls >= Self.maxErrorRolls ? .stop : .roll
        }
        guard hasResult else { return .keepListening }
        errorRolls = 0   // the active task is making progress
        return isFinal ? .nextSegment : .keepListening
    }
}
