import UIKit

/// DEBUG mock knob `HERDR_REDRAW_ON_TOUCH` (mock modes only): every touch-down in the app
/// posts `touchDown`, and the Agents home redraws on it, as a roster poll landing mid-tap
/// would. It makes the dropped-menu-tap race (a long-press menu rebuilt under the finger
/// swallowed the tap) happen on every tap, so the UI tests catch a menu that is rebuilt by
/// unrelated redraws. Release builds compile it out.
enum DebugTouchRedraw {
    static let touchDown = Notification.Name("herdr.debugTouchDown")

    /// Watches every window of the app's scenes; idempotent, so call it on appear.
    @MainActor static func installIfEnabled() {
        #if DEBUG
        guard ScreenshotMock.mode != nil,
              ProcessInfo.processInfo.environment["HERDR_REDRAW_ON_TOUCH"] != nil else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows
            where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchDownProbe }) {
                window.addGestureRecognizer(TouchDownProbe())
            }
        }
        #endif
    }
}

#if DEBUG
/// Never recognizes and never delays or cancels a touch: it only reports touch-downs.
private final class TouchDownProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        NotificationCenter.default.post(name: DebugTouchRedraw.touchDown, object: nil)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
