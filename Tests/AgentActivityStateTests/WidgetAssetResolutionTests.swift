import XCTest

/// Every raster the widget draws must exist, and must not out-resolve the slot it
/// is drawn in.
///
/// WHY THIS IS A TEST. Build 148 shipped `Image("AppLogo")` into a 26pt slot while
/// that asset was the 1024x1024 app icon — byte-identical to `AppIcon`'s
/// `icon-1024.png`. The device drew a flat grey square, with no build error, no
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
/// WHAT IT DOES AND DOES NOT PROVE. The guard is arithmetic over the asset
/// catalogue: it pins the sizes, not the rendering. The exact mechanism — whether
/// iOS rejected the over-resolution, the single unscaled entry, or both — is NOT
/// established by this file, because the fix moved both variables at once and no
/// Linux test can observe a Lock Screen. Only a device receipt closes that. What
/// this file does prove is that the catalogue can no longer hold either condition:
/// it fails on build 148's tree (1024px > 78px, scales `[]`) and passes here,
/// needing no Xcode, simulator, or device.
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

    /// A PNG's pixel dimensions, read from the IHDR rather than decoded: the test
    /// needs the numbers, not the picture.
    private func pixelSize(of png: URL) throws -> (width: Int, height: Int) {
        let bytes = try Data(contentsOf: png)
        guard bytes.count >= 24, Array(bytes[12..<16]) == Array("IHDR".utf8) else {
            XCTFail("\(png.lastPathComponent) is not a PNG with a leading IHDR chunk")
            return (0, 0)
        }
        func be32(_ offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (be32(16), be32(20))
    }

    /// EVERY widget source, at any depth. A single-level listing would quietly stop
    /// covering a view the moment one moved into `HerdrWidgets/Views/`, and the
    /// non-empty check below cannot notice a subdirectory it never walked.
    private func widgetSources() throws -> [URL] {
        let widgets = repoRoot().appendingPathComponent("HerdrWidgets")
        guard let walk = FileManager.default.enumerator(at: widgets, includingPropertiesForKeys: nil)
        else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private func widgetSlots() throws -> [Slot] {
        let sources = try widgetSources()
        XCTAssertFalse(sources.isEmpty, "no widget sources found — this guard would pass vacuously")

        // EVERY `Image(` IS CLASSIFIED, not just the shape this repo happens to use.
        // A regex that only knows `Image("Name")` reports zero slots — and zero
        // failures — for `Image(decorative:)`, `Image(uiImage:)`, `Image(name, bundle:)`
        // or a variable asset name, so a raster could return by any of those doors.
        let anyImage = try NSRegularExpression(pattern: #"\bImage\s*\("#)
        let bareLiteral = try NSRegularExpression(pattern: #"^\s*"([A-Za-z0-9_]+)"\s*\)"#)
        let sfSymbol = try NSRegularExpression(pattern: #"^\s*(systemName|_internalSystemName)\s*:"#)
        let frame = try NSRegularExpression(pattern: #"\.frame\(\s*width:\s*(\d+)\s*,\s*height:\s*(\d+)"#)

        var slots: [Slot] = []
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            let ns = text as NSString
            let calls = anyImage.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (index, call) in calls.enumerated() {
                let argsStart = call.range.upperBound
                let classify = NSRange(location: argsStart, length: min(160, ns.length - argsStart))

                // SF Symbols are vectors drawn at the point size asked for; they carry no
                // raster resolution to exceed, so they are out of scope by nature.
                if sfSymbol.firstMatch(in: text, range: classify) != nil { continue }

                guard let literal = bareLiteral.firstMatch(in: text, range: classify) else {
                    XCTFail("""
                        \(source.lastPathComponent) builds an Image the guard cannot measure: \
                        "\(ns.substring(with: classify).prefix(60))…". Only Image("Name") and \
                        Image(systemName:) are understood. A raster reaching the widget by any \
                        other initialiser is exactly how build 148's grey square shipped — name \
                        the asset literally, or teach this guard the new form.
                        """)
                    continue
                }
                let asset = ns.substring(with: literal.range(at: 1))

                // Bound the frame search by the NEXT Image call, so an unframed image
                // cannot silently borrow the bound of the view that follows it.
                let chainEnd = index + 1 < calls.count
                    ? calls[index + 1].range.lowerBound
                    : ns.length
                let window = NSRange(location: argsStart,
                                     length: max(0, min(chainEnd, argsStart + 400) - argsStart))
                guard let bound = frame.firstMatch(in: text, range: window) else {
                    XCTFail("""
                        Image("\(asset)") in \(source.lastPathComponent) has no explicit \
                        .frame(width:height:) in its own chain, so this guard cannot bound its \
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

    private func imageset(_ asset: String) -> URL {
        repoRoot().appendingPathComponent("Shared/Assets.xcassets/\(asset).imageset")
    }

    /// The property that failed on device: no raster in the set may out-resolve the slot.
    func testWidgetRastersDoNotOutResolveTheSlotTheyAreDrawnIn() throws {
        let slots = try widgetSlots()
        XCTAssertFalse(slots.isEmpty, "found no Image(\"…\") in the widget — this guard would pass vacuously")

        for slot in slots {
            // A widget compiles `Shared`; the app additionally compiles `App`. An asset
            // the widget draws must therefore resolve inside the shared catalogue — the
            // app's own catalogue is NOT in the extension bundle.
            let set = imageset(slot.asset)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: set.path),
                """
                the widget draws Image("\(slot.asset)") but Shared/Assets.xcassets carries no \
                \(slot.asset).imageset. Only `Shared` is compiled into the extension, so an \
                asset that lives in App/Assets.xcassets renders as nothing on device.
                """)
            guard FileManager.default.fileExists(atPath: set.path) else { continue }

            let pngs = try FileManager.default
                .contentsOfDirectory(at: set, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertFalse(pngs.isEmpty, "\(slot.asset).imageset carries no PNG at all")

            // 3x is the densest iPhone screen, so the slot's widest legitimate raster is
            // points * 3. Every PNG in the set is measured, including one no scale claims.
            let allowed = slot.points * 3
            for png in pngs {
                let size = try pixelSize(of: png)
                XCTAssertLessThanOrEqual(
                    max(size.width, size.height), allowed,
                    """
                    \(slot.asset)'s \(png.lastPathComponent) is \(size.width)x\(size.height)px \
                    but \(slot.file) draws it at \(slot.points)pt, whose 3x presentation is \
                    \(allowed)px. This is build 148's defect exactly: the Live Activity drew a \
                    grey square instead of the artwork. Downscale the asset to the slot.
                    """)
            }
        }
    }

    /// Each declared scale must carry the raster that scale MEANS — the check that
    /// makes the ceiling above meaningful rather than merely satisfiable.
    ///
    /// The ceiling cannot be tightened: 78px IS 26pt at 3x, with no slack. So the
    /// hole left by a maximum-only assertion is a set whose every slot holds the same
    /// 78px image: under the ceiling, declaring all three scales, and wrong at 1x and
    /// 2x, where the system would draw a 78px raster into 26 or 52 points. That is the
    /// same wrong-size class of defect the grey square came from, so it is asserted
    /// per scale, exactly, rather than as a bound.
    func testEveryDeclaredScaleCarriesARasterOfExactlyThatSize() throws {
        for slot in try widgetSlots() {
            let contents = imageset(slot.asset).appendingPathComponent("Contents.json")
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
                guard let scale = image["scale"] as? String,
                      let factor = Int(scale.dropLast())          // "2x" -> 2
                else {
                    XCTFail("\(slot.asset).imageset declares an unreadable scale \(image)")
                    continue
                }
                guard let filename = image["filename"] as? String, !filename.isEmpty else {
                    XCTFail("\(slot.asset).imageset declares \(scale) with no filename behind it")
                    continue
                }
                let png = imageset(slot.asset).appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: png.path) else {
                    XCTFail("\(slot.asset).imageset declares \(scale) as \(filename), which does not exist")
                    continue
                }
                let expected = slot.points * factor
                let size = try pixelSize(of: png)
                XCTAssertEqual(
                    [size.width, size.height], [expected, expected],
                    """
                    \(filename) is \(size.width)x\(size.height)px but it is the \(scale) slot of a \
                    \(slot.points)pt view, so it must be exactly \(expected)x\(expected)px. A set \
                    whose scales all hold the same raster passes a maximum-only check and still \
                    draws the wrong size on any screen that is not 3x.
                    """)
            }
        }
    }
}
