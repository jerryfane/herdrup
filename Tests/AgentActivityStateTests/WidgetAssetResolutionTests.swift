import XCTest

/// Every raster the widget draws must exist, and must not out-resolve the slot it
/// is drawn in.
///
/// WHY THIS IS A TEST. Build 148 shipped `Image("AppLogo")` into a 26pt slot while
/// that asset was the 1024x1024 app icon — byte-identical to `AppIcon`'s
/// `icon-1024.png`. A Live Activity will not render an asset whose resolution
/// exceeds its presentation: iOS drew a flat grey square, with no build error, no
/// runtime log, and no crash. The owner found it on the Lock Screen.
///
/// NOTHING THE REPO ALREADY HAD COULD HAVE CAUGHT IT, and that is the point:
///  - the archive built and signed clean, because the asset compiled fine;
///  - `swift test` never looks at the widget's artwork;
///  - the UI receipt renders `LockScreenView` INSIDE THE APP, in-process, where the
///    limit does not apply — so the gallery screenshot showed the logo correctly
///    while the device showed grey. A green capture was read as proof of a surface
///    it structurally cannot observe.
///
/// So the guard is arithmetic over the asset catalogue, which is the part that was
/// actually wrong. It fails on build 148's tree (1024 > 78) and passes on this one.
/// It runs on Linux with `swift test`, needing no Xcode, simulator, or device.
final class WidgetAssetResolutionTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentActivityStateTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    /// `Image("Name")` paired with the `.frame(width:height:)` that bounds it.
    private struct Slot {
        let asset: String
        let points: Int
        let file: String
    }

    /// The widest pixel dimension across an imageset's PNGs, read from the IHDR
    /// rather than decoded: the test needs the number, not the picture.
    private func widestPixelDimension(ofImagesIn imageset: URL) throws -> (widest: Int, files: [String]) {
        let entries = try FileManager.default.contentsOfDirectory(at: imageset, includingPropertiesForKeys: nil)
        let pngs = entries.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var widest = 0
        for png in pngs {
            let bytes = try Data(contentsOf: png)
            // 8-byte signature, then a 4-byte length + "IHDR", then width, height.
            guard bytes.count >= 24, Array(bytes[12..<16]) == Array("IHDR".utf8) else {
                XCTFail("\(png.lastPathComponent) is not a PNG with a leading IHDR chunk")
                continue
            }
            func be32(_ offset: Int) -> Int {
                bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            }
            widest = max(widest, max(be32(16), be32(20)))
        }
        return (widest, pngs.map(\.lastPathComponent))
    }

    private func widgetSlots() throws -> [Slot] {
        let widgets = repoRoot().appendingPathComponent("HerdrWidgets")
        let sources = try FileManager.default
            .contentsOfDirectory(at: widgets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty, "no widget sources found — this guard would pass vacuously")

        // The asset name, then the first explicit square frame in the same chain.
        let image = try NSRegularExpression(pattern: #"Image\(\s*"([A-Za-z0-9_]+)"\s*\)"#)
        let frame = try NSRegularExpression(pattern: #"\.frame\(\s*width:\s*(\d+)\s*,\s*height:\s*(\d+)"#)

        var slots: [Slot] = []
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            let ns = text as NSString
            for match in image.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let asset = ns.substring(with: match.range(at: 1))
                // Look only at the modifier chain that follows, not the rest of the file.
                let tailStart = match.range.upperBound
                let tail = NSRange(location: tailStart, length: min(400, ns.length - tailStart))
                guard let bound = frame.firstMatch(in: text, range: tail) else {
                    XCTFail("""
                        Image("\(asset)") in \(source.lastPathComponent) has no explicit \
                        .frame(width:height:) within its chain, so this guard cannot bound its \
                        resolution. Bound the view, or teach the guard how this slot is sized — \
                        do not leave a widget raster unmeasured.
                        """)
                    continue
                }
                let points = max(Int(ns.substring(with: bound.range(at: 1))) ?? 0,
                                 Int(ns.substring(with: bound.range(at: 2))) ?? 0)
                slots.append(Slot(asset: asset, points: points, file: source.lastPathComponent))
            }
        }
        return slots
    }

    /// The property that failed on device: pixels must fit the presentation at 3x.
    func testWidgetRastersDoNotOutResolveTheSlotTheyAreDrawnIn() throws {
        let root = repoRoot()
        let slots = try widgetSlots()
        XCTAssertFalse(slots.isEmpty, "found no Image(\"…\") in the widget — this guard would pass vacuously")

        for slot in slots {
            // A widget compiles `Shared`; the app additionally compiles `App`. An asset
            // the widget draws must therefore resolve inside the shared catalogue — the
            // app's own catalogue is NOT in the extension bundle.
            let imageset = root
                .appendingPathComponent("Shared/Assets.xcassets/\(slot.asset).imageset")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imageset.path),
                """
                the widget draws Image("\(slot.asset)") but Shared/Assets.xcassets carries no \
                \(slot.asset).imageset. Only `Shared` is compiled into the extension, so an \
                asset that lives in App/Assets.xcassets renders as nothing on device.
                """)
            guard FileManager.default.fileExists(atPath: imageset.path) else { continue }

            let (widest, files) = try widestPixelDimension(ofImagesIn: imageset)
            XCTAssertFalse(files.isEmpty, "\(slot.asset).imageset carries no PNG at all")

            // 3x is the densest iPhone screen, so the slot's widest legitimate raster is
            // points * 3. Anything beyond that is resolution the Lock Screen refuses.
            let allowed = slot.points * 3
            XCTAssertLessThanOrEqual(
                widest, allowed,
                """
                \(slot.asset) is \(widest)px at its largest (\(files.joined(separator: ", "))) \
                but \(slot.file) draws it at \(slot.points)pt, whose 3x presentation is \
                \(allowed)px. This is build 148's defect exactly: the Live Activity renders a \
                grey square instead of the artwork. Downscale the asset to the slot.
                """)
        }
    }

    /// The catalogue must offer real 1x/2x/3x slots rather than one unscaled image.
    /// Apple's guidance for this failure is explicit about supplying the scales, and a
    /// single unscaled entry is what the shipped tree had when the device drew grey.
    func testWidgetImagesetsDeclareEveryScale() throws {
        let root = repoRoot()
        for slot in try widgetSlots() {
            let contents = root
                .appendingPathComponent("Shared/Assets.xcassets/\(slot.asset).imageset/Contents.json")
            guard let data = try? Data(contentsOf: contents) else {
                XCTFail("\(slot.asset).imageset has no Contents.json")
                continue
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let images = json?["images"] as? [[String: Any]] ?? []
            let scales = Set(images.compactMap { $0["scale"] as? String })
            XCTAssertEqual(
                scales, ["1x", "2x", "3x"],
                """
                \(slot.asset).imageset declares scales \(scales.sorted()) — the widget needs \
                1x, 2x and 3x so the system picks the raster that fits the screen it is on.
                """)
            for image in images {
                let filename = image["filename"] as? String ?? ""
                XCTAssertFalse(
                    filename.isEmpty,
                    "\(slot.asset).imageset declares a scale with no filename behind it")
            }
        }
    }
}
