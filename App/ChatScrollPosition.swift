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
}
