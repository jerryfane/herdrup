import Foundation

/// The conversation column's width on iPad and Mac, shared by Chat and Gram (#523 items 2 and
/// 12, #541): the reader drags either edge of the column to resize it around its centre,
/// between `minimum` and the whole width the conversation has (Full), with snap points at
/// Readable, Wide and Full. The composer takes the same width.
///
/// One width for both, remembered per device under `storageKey`: resizing Chat resizes Gram
/// and the other way round. A window narrower than the stored width shows the window's width
/// (`displayed`) and leaves the stored width alone, so widening the window again brings the
/// chosen width back.
public enum ConversationColumnWidth {
    public static let storageKey = "conversation.columnWidth"
    /// Where the width lived while only Chat had it. `migrate(_:)` moves it to `storageKey`.
    public static let legacyChatStorageKey = "chat.columnWidth"

    /// Moves a width stored under `legacyChatStorageKey` to `storageKey`, so a reader who sized
    /// Chat keeps that width (now Gram's too). A width already under `storageKey` wins. Run at
    /// launch, before any view reads the width.
    public static func migrate(_ defaults: UserDefaults) {
        guard let legacy = defaults.object(forKey: legacyChatStorageKey) else { return }
        if defaults.object(forKey: storageKey) == nil, let width = (legacy as? NSNumber)?.doubleValue {
            defaults.set(width, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyChatStorageKey)
    }

    public static let minimum: Double = 560
    public static let readable: Double = 720
    public static let wide: Double = 1000
    /// What Full stores: wider than any window, so it always shows as the whole width the
    /// conversation has, in this window and in a wider one.
    public static let full: Double = 100_000
    public static let defaultWidth = wide
    /// How close (in points) a dragged width must come to a snap point to land on it.
    public static let snapDistance: Double = 12
    /// One accessibility increment or decrement.
    public static let step: Double = 40

    public enum Edge: Sendable, Equatable {
        case leading, trailing
    }

    public enum Snap: String, Sendable, Equatable {
        case readable = "Readable"
        case wide = "Wide"
        case full = "Full"
    }

    public struct SnapPoint: Sendable, Equatable {
        public let width: Double
        public let snap: Snap
    }

    /// A stored value made safe to lay out: an unusable one (not finite, not positive) is the
    /// default; any other is held between `minimum` and `full`.
    public static func sanitized(_ stored: Double) -> Double {
        guard stored.isFinite, stored > 0 else { return defaultWidth }
        return min(full, max(minimum, stored))
    }

    /// The width the column shows: the stored width, or all of `available` when that is
    /// narrower. Never written back.
    public static func displayed(stored: Double, available: Double) -> Double {
        min(sanitized(stored), max(0, available))
    }

    /// `width` held between `minimum` and `available`. A conversation narrower than the minimum
    /// is shown whole.
    public static func clamped(_ width: Double, available: Double) -> Double {
        min(max(0, available), max(minimum, width))
    }

    /// The snap points that fit in `available`, in label order: Readable, Wide, then Full
    /// (the whole width).
    public static func snapPoints(available: Double) -> [SnapPoint] {
        var points: [SnapPoint] = []
        if readable <= available { points.append(SnapPoint(width: readable, snap: .readable)) }
        if wide <= available { points.append(SnapPoint(width: wide, snap: .wide)) }
        points.append(SnapPoint(width: max(0, available), snap: .full))
        return points
    }

    /// `width` moved onto the nearest snap point within `snapDistance`, else unchanged.
    public static func snapped(_ width: Double, available: Double) -> Double {
        let nearest = snapPoints(available: available).min { abs($0.width - width) < abs($1.width - width) }
        guard let nearest, abs(nearest.width - width) <= snapDistance else { return width }
        return nearest.width
    }

    /// The width after dragging `edge` by `translation` points (positive is rightwards) from a
    /// column `start` wide. Both edges move, so the column stays centred and its width changes
    /// by twice the drag: wider when an edge moves outwards. Rounded to whole points, held
    /// between `minimum` and `available`, then snapped.
    public static func dragged(from start: Double, translation: Double, edge: Edge, available: Double) -> Double {
        let outwards = edge == .trailing ? translation : -translation
        return snapped(clamped((start + 2 * outwards).rounded(), available: available), available: available)
    }

    /// What to store for a width the reader chose in a conversation `available` wide: Readable and
    /// Wide as themselves, the whole width as `full` (so a wider window widens it too), any
    /// other width as it is.
    public static func stored(for width: Double, available: Double) -> Double {
        if abs(width - readable) < 0.5 { return readable }
        if abs(width - wide) < 0.5 { return wide }
        if width >= available - 0.5 { return full }
        return width
    }

    /// What a reset stores: Wide. A conversation narrower than Wide shows it as Full.
    public static let resetWidth = wide

    /// The snap point `width` sits on, if any.
    public static func snap(at width: Double, available: Double) -> Snap? {
        snapPoints(available: available).first { abs($0.width - width) < 0.5 }?.snap
    }

    /// The readout shown while dragging: "820 pt", or "720 pt · Readable" on a snap point.
    public static func readout(_ width: Double, available: Double) -> String {
        let points = "\(Int(width.rounded())) pt"
        guard let snap = snap(at: width, available: available) else { return points }
        return points + " · " + snap.rawValue
    }

    /// A handle's accessibility value: "820 points", or "720 points, Readable" on a snap point.
    public static func accessibilityValue(_ width: Double, available: Double) -> String {
        let points = "\(Int(width.rounded())) points"
        guard let snap = snap(at: width, available: available) else { return points }
        return points + ", " + snap.rawValue
    }

    /// One accessibility increment: `step` points wider, stopping on a snap point on the way,
    /// held to `available`.
    public static func incremented(_ width: Double, available: Double) -> Double {
        let target = width + step
        let crossed = snapPoints(available: available).map(\.width)
            .filter { $0 > width + 0.5 && $0 < target - 0.5 }.min()
        return clamped(crossed ?? target, available: available)
    }

    /// One accessibility decrement: `step` points narrower, stopping on a snap point on the
    /// way, held to `minimum`.
    public static func decremented(_ width: Double, available: Double) -> Double {
        let target = width - step
        let crossed = snapPoints(available: available).map(\.width)
            .filter { $0 < width - 0.5 && $0 > target + 0.5 }.max()
        return clamped(crossed ?? target, available: available)
    }
}
