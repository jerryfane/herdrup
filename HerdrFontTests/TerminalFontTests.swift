import CoreText
import UIKit
import XCTest
@testable import Herdr

/// What the terminal's font cascade must and must not claim.
///
/// These run on a simulator (`-only-testing:HerdrFontTests` in ci.yml) because every
/// assertion is Core Text answering a real query against the registered faces — the
/// only thing that can settle where a codepoint actually lands. Two opposite bugs got
/// here first, and both are pinned below.
final class TerminalFontTests: XCTestCase {

    private static let symbolFontName = "HerdrupSymbols"

    /// Codepoints the UPSTREAM Nerd Fonts artifact maps outside the private-use area.
    /// `Tools/subset-symbols-font.py` drops exactly these, so the shipped font cannot
    /// claim them from the system however the cascade is ordered. With upstream coverage
    /// and first position they were all hijacked, and U+26A1 — Emoji_Presentation=Yes —
    /// turned `⚡` in agent output into a monochrome glyph.
    private static let droppedNonPrivateUse: [(scalar: UInt32, label: String)] = [
        (0x23FB, "power symbol ⏻"),
        (0x23FC, "power on/off ⏼"),
        (0x23FD, "power on ⏽"),
        (0x23FE, "power sleep ⏾"),
        (0x2630, "trigram ☰"),
        (0x2665, "heart ♥"),
        (0x26A1, "high voltage ⚡ (emoji presentation)"),
        (0x276C, "medium left angle bracket ❬"),
        (0x276D, "medium right angle bracket ❭"),
        (0x276E, "heavy left angle quote ❮"),
        (0x276F, "heavy right angle quote ❯"),
        (0x2770, "heavy left angle bracket ❰"),
        (0x2771, "heavy right angle bracket ❱"),
        (0x2B58, "heavy circle ⭘"),
    ]

    /// Private-use codepoints Apple Color Emoji ALSO maps, through the legacy SoftBank
    /// block U+E001-U+E537 it has never dropped. These are the 170 glyphs that vanished
    /// behind emoji while the symbol font sat after the system fallbacks: ordering it
    /// first is what brings them back, and the subset is what makes first position safe.
    private static let softBankCollisions: [(scalar: UInt32, label: String)] = [
        (0xE001, "Seti/custom, start of U+E001-E00A"),
        (0xE00A, "Seti/custom, end of U+E001-E00A"),
        (0xE201, "Font Awesome Extension, start of U+E201-E253"),
        (0xE253, "Font Awesome Extension, end of U+E201-E253"),
        (0xE301, "Weather Icons, start of U+E301-E34D"),
        (0xE34D, "Weather Icons, end of U+E301-E34D"),
    ]

    func testPrimaryTextKeepsIBMPlexAndPrivateUseGlyphsReachTheSymbolFont() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)

        XCTAssertEqual(postScriptName(resolvedFont(for: "A", from: font)), "IBMPlexMono")

        // Why the font is bundled: the powerline separator and two Font Awesome glyphs.
        for scalar: UInt32 in [0xE0B0, 0xF07B, 0xF00C] {
            let face = resolvedFont(for: string(scalar), from: font)
            XCTAssertEqual(
                postScriptName(face), Self.symbolFontName,
                "U+\(hex(scalar)) must resolve to the symbol font")
            XCTAssertNotEqual(
                glyph(for: scalar, in: face), 0,
                "the symbol font must have a real glyph for U+\(hex(scalar))")
        }
    }

    /// The bug the FIRST fix introduced, and the reason the font is subset rather than
    /// merely reordered. If these regress, the symbol font has been pushed behind Apple
    /// Color Emoji again and 170 shipped glyphs are unreachable.
    func testSoftBankPrivateUseGlyphsBeatAppleColorEmoji() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        guard let symbols = UIFont(name: Self.symbolFontName, size: 12.5) else {
            return XCTFail("\(Self.symbolFontName) is not registered; the rest is vacuous without it")
        }

        for (scalar, label) in Self.softBankCollisions {
            XCTAssertNotEqual(
                glyph(for: scalar, in: symbols as CTFont), 0,
                "U+\(hex(scalar)) (\(label)) must exist in the subset, or this test proves nothing")
            XCTAssertEqual(
                postScriptName(resolvedFont(for: string(scalar), from: font)), Self.symbolFontName,
                """
                U+\(hex(scalar)) (\(label)) resolved elsewhere — Apple Color Emoji maps the \
                legacy SoftBank block, so the symbol font must precede it in the cascade.
                """)
        }
    }

    /// The bug that SHIPPED. Asserted two ways so neither the subset nor the ordering can
    /// regress silently: the font must not map these at all, and they must not resolve to
    /// it. The version of this test that came before asserted U+263A, which neither font
    /// maps, so it held wherever the symbol font sat.
    func testDroppedCodepointsKeepTheirSystemFace() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        guard let symbols = UIFont(name: Self.symbolFontName, size: 12.5) else {
            return XCTFail("\(Self.symbolFontName) is not registered; the rest is vacuous without it")
        }

        for (scalar, label) in Self.droppedNonPrivateUse {
            XCTAssertEqual(
                glyph(for: scalar, in: symbols as CTFont), 0,
                """
                \(label) is still in the shipped font's cmap — rerun \
                Tools/subset-symbols-font.py, because first position will hijack it.
                """)
            let face = postScriptName(resolvedFont(for: string(scalar), from: font))
            XCTAssertNotEqual(face, Self.symbolFontName, "\(label) must keep its system face")
            XCTAssertNotEqual(face, "LastResort", "\(label) resolved to LastResort, so the cascade lost it")
        }
    }

    func testCJKAndEmojiStillReachTheSystemCascade() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        for text in ["漢", "\u{263a}\u{fe0f}", "\u{1f600}"] {
            let name = postScriptName(resolvedFont(for: text, from: font))
            XCTAssertNotEqual(name, Self.symbolFontName, "\(text) must not come from the symbol font")
            XCTAssertNotEqual(name, "LastResort", "\(text) must reach a real system face")
        }
    }

    /// SwiftTerm's hot-path gate is CTFont IDENTITY: `usesPrimaryFont` compares the run
    /// font against `fontSet.normal` with `CFEqual` and returns early for ordinary text.
    /// The pane font is a descriptor carrying a cascade list, and CTFont equality is
    /// descriptor-based — so if Core Text hands back a normalised font for unsubstituted
    /// runs, that gate fails for ALL ordinary text and every primary glyph pays two metric
    /// calls per repaint.
    func testCoreTextReturnsTheCascadeBearingFontForUnsubstitutedRuns() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "plain ascii", attributes: [.font: font]))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        XCTAssertEqual(runs.count, 1, "unsubstituted ASCII should not be split into runs")

        guard let run = runs.first else { return }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let runFont = attributes[kCTFontAttributeName as String] as? CTFont else {
            return XCTFail("the run carries no font attribute")
        }
        XCTAssertTrue(
            CFEqual(runFont, font as CTFont),
            """
            Core Text returned a font that is not identical to the pane font, so \
            SwiftTerm's usesPrimaryFont gate fails for ordinary text and the fit path \
            runs on every primary glyph. Compare against fontSet.normal instead of \
            assuming identity.
            """)
    }

    /// Size changes must still produce distinct metrics, since the cascade is now built
    /// once at a reference size and resized per call.
    func testResizingTheCachedDescriptorStillChangesMetrics() {
        let small = LiveTerminalView.Coordinator.makePaneFont(size: 9)
        let large = LiveTerminalView.Coordinator.makePaneFont(size: 24)
        XCTAssertEqual(small.pointSize, 9)
        XCTAssertEqual(large.pointSize, 24)
        // A REAL glyph, measured. Passing a zero count returns 0 for both fonts, which
        // is a tautology dressed as a metric check — that is what this line used to do.
        XCTAssertGreaterThan(
            advanceOfCapitalA(large), advanceOfCapitalA(small),
            "a resized pane font must carry the larger advance, not the reference size's")
        // The cascade must survive the resize, or private-use glyphs stop resolving.
        XCTAssertEqual(
            postScriptName(resolvedFont(for: string(0xE0B0), from: large)), Self.symbolFontName)
    }

    /// SwiftTerm derives bold and italic from the base font and `usesPrimaryFont` gates
    /// on all four faces, so a cascade that survives only on `normal` would leave bold
    /// terminal output with no symbol coverage — and the fit path would then treat those
    /// runs as non-primary. Derived here the same way a trait-based derivation does.
    func testTheCascadeSurvivesIntoDerivedBoldAndItalicFaces() {
        let base = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        for (trait, label) in [(UIFontDescriptor.SymbolicTraits.traitBold, "bold"),
                               (UIFontDescriptor.SymbolicTraits.traitItalic, "italic")] {
            guard let descriptor = base.fontDescriptor.withSymbolicTraits(trait) else {
                return XCTFail("could not derive the \(label) face from the pane font")
            }
            let derived = UIFont(descriptor: descriptor, size: 12.5)
            XCTAssertEqual(
                postScriptName(resolvedFont(for: string(0xE0B0), from: derived)),
                Self.symbolFontName,
                "the \(label) face lost the cascade, so private-use glyphs stop resolving in it")
        }
    }

    // MARK: - helpers

    private func hex(_ scalar: UInt32) -> String {
        String(scalar, radix: 16, uppercase: true)
    }

    private func string(_ scalar: UInt32) -> String {
        String(UnicodeScalar(scalar)!)
    }

    private func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private func advanceOfCapitalA(_ font: UIFont) -> CGFloat {
        var g = glyph(for: 0x41, in: font as CTFont)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &g, &advance, 1)
        return advance.width
    }

    private func glyph(for scalar: UInt32, in font: CTFont) -> CGGlyph {
        var utf16 = Array(String(UnicodeScalar(scalar)!).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        return glyphs.first ?? 0
    }

    private func resolvedFont(for text: String, from font: UIFont) -> CTFont {
        CTFontCreateForString(
            font as CTFont,
            text as CFString,
            CFRange(location: 0, length: (text as NSString).length)
        )
    }
}
