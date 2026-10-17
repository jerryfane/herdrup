#if DEBUG
import UIKit
import ObjectiveC

/// Diagnostic branch only. Logs delivery without changing hit testing or retrying input.
@MainActor
enum TabDeliveryTrace {
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        exchange(UIApplication.self, #selector(UIApplication.sendEvent(_:)), #selector(UIApplication.tabTraceSendEvent(_:)))
        exchange(UIControl.self, #selector(UIControl.sendAction(_:to:for:)), #selector(UIControl.tabTraceSendAction(_:to:for:)))
        exchange(UITabBar.self, #selector(setter: UITabBar.selectedItem), #selector(UITabBar.tabTraceSetSelectedItem(_:)))
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let first = class_getInstanceMethod(cls, original),
              let second = class_getInstanceMethod(cls, replacement) else {
            fatalError("Missing tab diagnostic method")
        }
        method_exchangeImplementations(first, second)
    }

    static func describe(_ view: UIView?) -> String {
        var current = view
        var chain: [String] = []
        while let node = current, chain.count < 12 {
            var detail = "\(type(of: node))@\(Unmanaged.passUnretained(node).toOpaque()) frame=\(node.frame) hidden=\(node.isHidden) alpha=\(node.alpha) interaction=\(node.isUserInteractionEnabled)"
            if let control = node as? UIControl {
                detail += " enabled=\(control.isEnabled) tracking=\(control.isTracking) highlighted=\(control.isHighlighted) selected=\(control.isSelected)"
            }
            if let bar = node as? UITabBar {
                detail += " selectedItem=\(bar.selectedItem?.title ?? "nil") items=\(bar.items?.map { $0.title ?? "nil" } ?? [])"
            }
            chain.append(detail)
            current = node.superview
        }
        return chain.joined(separator: " <- ")
    }
}

extension UIApplication {
    @objc fileprivate func tabTraceSendEvent(_ event: UIEvent) {
        let touches = event.allTouches ?? []
        for touch in touches where touch.phase == .began || touch.phase == .ended || touch.phase == .cancelled {
            NSLog("[TabTrace] before phase=\(touch.phase.rawValue) eventTime=\(event.timestamp) now=\(ProcessInfo.processInfo.systemUptime) point=\(touch.location(in: touch.window)) target=\(TabDeliveryTrace.describe(touch.view))")
        }
        tabTraceSendEvent(event)
        for touch in touches where touch.phase == .began || touch.phase == .ended || touch.phase == .cancelled {
            NSLog("[TabTrace] after phase=\(touch.phase.rawValue) target=\(TabDeliveryTrace.describe(touch.view))")
        }
    }
}

extension UIControl {
    @objc fileprivate func tabTraceSendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        NSLog("[TabTrace] action=\(NSStringFromSelector(action)) target=\(String(describing: target)) control=\(TabDeliveryTrace.describe(self))")
        tabTraceSendAction(action, to: target, for: event)
    }
}

extension UITabBar {
    @objc fileprivate func tabTraceSetSelectedItem(_ item: UITabBarItem?) {
        NSLog("[TabTrace] barSelection old=\(selectedItem?.title ?? "nil") new=\(item?.title ?? "nil")")
        tabTraceSetSelectedItem(item)
    }
}
#endif
