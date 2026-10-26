/// The rows a collapsed to-do card shows: the work at hand, not the whole plan.
public enum TranscriptPlanWindow {
    /// Indices into `items`, ascending, of at most `limit` rows. The window starts at the
    /// first in-progress item, else the first item not done; it fills forward with the
    /// items after that start that are not done, then back-fills with the done items
    /// nearest before the start. Empty when every item is done: the card shows only its
    /// header.
    public static func visible(_ items: [TranscriptPlanItem], limit: Int = 3) -> [Int] {
        guard limit > 0,
              let start = items.firstIndex(where: { $0.status == .inProgress })
                ?? items.firstIndex(where: { !$0.done })
        else { return [] }
        var shown = [start]
        for index in (start + 1)..<items.count where shown.count < limit && !items[index].done {
            shown.append(index)
        }
        for index in (0..<start).reversed() where shown.count < limit && items[index].done {
            shown.append(index)
        }
        return shown.sorted()
    }
}
