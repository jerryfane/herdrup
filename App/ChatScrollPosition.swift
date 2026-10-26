import UIKit

/// The scroll view owns the tail offset; row anchors remain ScrollViewReader's job.
/// A weak reference avoids retaining a kept-alive pane after its owner removes it.
@MainActor
final class ChatScrollPosition {
    weak var view: UIScrollView?

    private var bottomOffset: CGFloat? {
        guard let view else { return nil }
        return max(-view.adjustedContentInset.top,
                   view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    }

    var isAtBottom: Bool {
        guard let view, let bottomOffset else { return false }
        return view.contentOffset.y >= bottomOffset - 8
    }

    func jumpToLatest() {
        guard let view, let bottomOffset, abs(view.contentOffset.y - bottomOffset) > 0.5 else { return }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottomOffset), animated: false)
    }

    /// The jump button's glide to the tail. From more than two screens away it first snaps to
    /// one screen above the tail, so the glide is always one screen long. The model offset is
    /// final at once, so `isAtBottom` holds immediately and the per-tick `jumpToLatest` finds
    /// nothing to do instead of fighting the animation. Reduce Motion jumps.
    func animateToLatest() {
        guard let view, let bottomOffset, abs(view.contentOffset.y - bottomOffset) > 0.5 else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return jumpToLatest() }
        // Stops a fling still decelerating, which would otherwise carry on against the glide.
        view.setContentOffset(view.contentOffset, animated: false)
        if bottomOffset - view.contentOffset.y > 2 * view.bounds.height {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottomOffset - view.bounds.height), animated: false)
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: bottomOffset)
        }
    }
}
