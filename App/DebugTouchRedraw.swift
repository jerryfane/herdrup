import UIKit

/// DEBUG mock knob `HERDR_REDRAW_ON_TOUCH` (mock modes only): every touch-down in the app
/// posts `touchDown`, and the Agents home and Gram redraw on it, as a roster or Gram poll
/// landing mid-tap would. It makes the dropped-menu-tap race (a long-press menu rebuilt under
/// the finger swallowed the tap) happen on every tap, so the UI tests catch a menu that is
/// rebuilt by unrelated redraws. Release builds compile it out.
enum DebugTouchRedraw {
    static let touchDown = Notification.Name("herdr.debugTouchDown")
    #if DEBUG
    static var searchTrace = ""
    static func traceSearch(_ message: String) {
        guard ProcessInfo.processInfo.environment["HERDR_TRACE_SEARCH"] == "1" else { return }
        searchTrace += message + "\n"
    }
    #endif

    /// Watches every window of the app's scenes; idempotent, so call it on appear.
    @MainActor static func installIfEnabled() {
        #if DEBUG
        guard ScreenshotMock.mode != nil,
              ProcessInfo.processInfo.environment["HERDR_REDRAW_ON_TOUCH"] != nil
                || ProcessInfo.processInfo.environment["HERDR_TRACE_SEARCH"] == "1" else { return }
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
        if ProcessInfo.processInfo.environment["HERDR_TRACE_SEARCH"] == "1",
           let touch = touches.first {
            var chain: [String] = []
            var current = touch.view
            while let view = current {
                chain.append("\(type(of: view)) frame=\(NSCoder.string(for: view.frame)) hidden=\(view.isHidden)")
                current = view.superview
            }
            DebugTouchRedraw.traceSearch("touch \(NSCoder.string(for: touch.location(in: touch.window))) " + chain.joined(separator: " > "))
            if let window = touch.window { recordEditors(window, in: window) }
        }
        if ProcessInfo.processInfo.environment["HERDR_REDRAW_ON_TOUCH"] != nil {
            NotificationCenter.default.post(name: DebugTouchRedraw.touchDown, object: nil)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    private func recordEditors(_ view: UIView, in window: UIWindow) {
        if let field = view as? UITextField {
            let frame = field.convert(field.bounds, to: window)
            let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
            DebugTouchRedraw.traceSearch("field placeholder=\(field.placeholder ?? "") text=\(field.text ?? "") frame=\(NSCoder.string(for: frame)) hidden=\(field.isHidden) first=\(field.isFirstResponder) centreHit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        for child in view.subviews { recordEditors(child, in: window) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
