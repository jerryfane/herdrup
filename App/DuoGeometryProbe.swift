import SwiftUI
import UIKit

// TEMPORARY diagnostic for the iPhone Duo screenshot workflow: what the system reports for
// the safe area, the container corners and the reserved regions in each pose, written to
// Documents/duo-probe.json, which Tools/ci/duo-screenshots.sh copies next to each capture.
// Only under the DEBUG screenshot mock; a no-op otherwise and in Release.

extension View {
    @ViewBuilder
    func duoProbe(_ name: String, _ extra: [String: String] = [:]) -> some View {
        #if DEBUG
        if ScreenshotMock.mode != nil {
            background { DuoGeometryProbeReader(name: name, extra: extra) }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
enum DuoGeometryProbe {
    private static var entries: [String: Any] = [:]
    private static var scheduled = false

    static func record(_ name: String, _ value: [String: Any]) {
        entries[name] = value
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            scheduled = false
            entries["window"] = windowSnapshot()
            write()
        }
    }

    private static func write() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              JSONSerialization.isValidJSONObject(entries),
              let data = try? JSONSerialization.data(withJSONObject: entries,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appendingPathComponent("duo-probe.json"), options: .atomic)
    }

    private static func windowSnapshot() -> [String: Any] {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return [:] }
        let t = window.traitCollection
        var out: [String: Any] = [
            "bounds": rect(window.bounds),
            "safeArea": insets(window.safeAreaInsets),
            "idiom": t.userInterfaceIdiom.rawValue,
            "hSizeClass": t.horizontalSizeClass.rawValue,
            "vSizeClass": t.verticalSizeClass.rawValue,
        ]
        var splits: [[String: Any]] = []
        func walk(_ vc: UIViewController) {
            if let s = vc as? UISplitViewController {
                var d: [String: Any] = [
                    "displayMode": s.displayMode.rawValue,
                    "preferredDisplayMode": s.preferredDisplayMode.rawValue,
                    "splitBehavior": s.splitBehavior.rawValue,
                    "preferredSplitBehavior": s.preferredSplitBehavior.rawValue,
                    "isCollapsed": s.isCollapsed,
                    "primaryColumnWidth": s.primaryColumnWidth,
                    "minimumPrimaryColumnWidth": s.minimumPrimaryColumnWidth,
                    "maximumPrimaryColumnWidth": s.maximumPrimaryColumnWidth,
                    "preferredPrimaryColumnWidth": s.preferredPrimaryColumnWidth,
                    "viewWidth": s.view.bounds.width,
                ]
                if #available(iOS 26.0, *) {
                    d["minimumSecondaryColumnWidth"] = s.minimumSecondaryColumnWidth
                    d["preferredSecondaryColumnWidth"] = s.preferredSecondaryColumnWidth
                }
                for (name, col) in [("primary", UISplitViewController.Column.primary),
                                    ("secondary", .secondary)] {
                    if let v = s.viewController(for: col)?.view, v.window != nil {
                        d[name + "Frame"] = rect(v.convert(v.bounds, to: nil))
                    }
                }
                splits.append(d)
            }
            vc.children.forEach(walk)
        }
        if let root = window.rootViewController { walk(root) }
        out["splitViews"] = splits
        var scrolls: [[String: Any]] = []
        func walkViews(_ v: UIView) {
            if let s = v as? UIScrollView, !s.isHidden, s.bounds.height > 100, scrolls.count < 24 {
                scrolls.append([
                    "class": String(describing: type(of: s)),
                    "id": s.accessibilityIdentifier ?? "",
                    "frame": rect(s.convert(s.bounds, to: nil)),
                    "contentSize": ["w": s.contentSize.width, "h": s.contentSize.height],
                    "contentOffsetY": s.contentOffset.y,
                    "adjustedContentInset": insets(s.adjustedContentInset),
                    "safeArea": insets(s.safeAreaInsets),
                ])
            }
            v.subviews.forEach(walkViews)
        }
        walkViews(window)
        out["scrollViews"] = scrolls
        return out
    }

    nonisolated static func rect(_ r: CGRect) -> [String: CGFloat] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }

    nonisolated static func insets(_ e: UIEdgeInsets) -> [String: CGFloat] {
        ["top": e.top, "left": e.left, "bottom": e.bottom, "right": e.right]
    }
}

private struct DuoGeometryProbeReader: View {
    let name: String
    let extra: [String: String]
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    var body: some View {
        GeometryReader { geometry in
            let snapshot = snapshot(geometry)
            Color.clear
                .onChange(of: String(describing: snapshot), initial: true) {
                    DuoGeometryProbe.record(name, snapshot)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func snapshot(_ g: GeometryProxy) -> [String: Any] {
        let s = g.safeAreaInsets
        let safeArea: [String: CGFloat] = ["top": s.top, "leading": s.leading,
                                           "bottom": s.bottom, "trailing": s.trailing]
        var out: [String: Any] = [
            "frameGlobal": DuoGeometryProbe.rect(g.frame(in: .global)),
            "safeArea": safeArea,
            "hSizeClass": hSizeClass.map { String(describing: $0) } ?? "nil",
            "vSizeClass": vSizeClass.map { String(describing: $0) } ?? "nil",
            "extra": extra,
        ]
        if #available(iOS 26.0, *) {
            let c = g.containerCornerInsets
            func size(_ v: CGSize) -> [String: CGFloat] { ["w": v.width, "h": v.height] }
            let corners: [String: [String: CGFloat]] = [
                "topLeading": size(c.topLeading), "topTrailing": size(c.topTrailing),
                "bottomLeading": size(c.bottomLeading), "bottomTrailing": size(c.bottomTrailing)]
            out["cornerInsets"] = corners
        }
        if #available(iOS 27.1, *) {
            func regions(_ kind: ReservedRegion.Kind) -> [[String: Any]] {
                g.reservedRegions(kind: kind, options: .includeInactive).map { r in
                    let m = r.margins
                    let margins: [String: CGFloat] = ["top": m.top, "leading": m.leading,
                                                      "bottom": m.bottom, "trailing": m.trailing]
                    let entry: [String: Any] = [
                        "id": String(describing: r.id), "kind": String(describing: r.kind),
                        "active": r.isActive, "frame": DuoGeometryProbe.rect(r.frame),
                        "margins": margins]
                    return entry
                }
            }
            out["occlusions"] = regions(.occlusion)
            out["divisions"] = regions(.division)
        }
        return out
    }
}
#endif
