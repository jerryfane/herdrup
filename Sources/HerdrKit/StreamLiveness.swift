import Foundation

/// Whether a pane's byte stream is actually ALIVE, as opposed to whether the app
/// happens to be in front.
///
/// ## Why scene phase cannot answer this
///
/// The live terminal reseeds itself when the app returns to the foreground, because
/// output produced while away would otherwise be missing (herdr#62). That reseed was
/// keyed on the scene going `.background` and back, which is a PROXY — and it is only
/// true on one platform.
///
/// On iOS the app is suspended: the stream really did stop, output really was lost, and
/// a reseed repairs a genuine gap. On a Mac the process keeps running while another
/// Space or app is front. Frames keep arriving, nothing is lost, and reseeding then
/// destroys a perfectly live terminal — the remount discards the reader's selection and
/// scroll position, which is precisely what a reader switched apps to use.
///
/// So this records the FACT the decision actually needs: when a frame last arrived. The
/// server pings every 20s, so a still-connected stream is never more than about that
/// stale, while the reader's own view of "dead" is the terminal's stuck-stream timeout.
/// Callers pass that timeout in rather than this type inventing a second one, so the
/// host and the reconnect watchdog cannot drift apart on what "dead" means.
///
/// Deliberately a plain reference type and NOT observable: the terminal writes to it on
/// every frame, and publishing at the firehose's rate would re-render the UI constantly.
/// The host reads it once, at the moment it has a decision to make.
public final class StreamLiveness {
    /// When a frame (data, ping, resize, reset) last arrived, or nil if none ever has.
    public private(set) var lastFrameAt: Date?

    public init(lastFrameAt: Date? = nil) { self.lastFrameAt = lastFrameAt }

    public func noteFrame(at moment: Date = Date()) { lastFrameAt = moment }

    /// True when the stream shows no sign of life within `timeout`.
    ///
    /// Never having received a frame counts as stale. That is the conservative answer
    /// and it is the right one here: a stream that has delivered nothing has no screen
    /// state worth preserving, so reseeding it costs the reader nothing.
    public func isStale(now: Date = Date(), timeout: TimeInterval) -> Bool {
        guard let lastFrameAt else { return true }
        return now.timeIntervalSince(lastFrameAt) > timeout
    }
}
