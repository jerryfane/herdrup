import CoreText
import UIKit
import XCTest
@testable import Herdr

/// What the terminal's font cascade must and must not claim.
///
/// These run on a simulator (`-only-testing:HerdrFontTests` in ci.yml) because every
/// assertion here is Core Text answering a real query against the registered faces —
/// which is the only thing that can settle where a codepoint actually lands.
final class TerminalFontTests: XCTestCase {

    /// Codepoints SymbolsNerdFontMono maps OUTSIDE the private-use area, read from its
    /// cmap (format 4, platform 3/1). IBM Plex Mono covers none of them, so a cascade
    /// that puts the symbol font first wins all of them away from the system — which is
    /// what shipped until the ordering fix. U+26A1 is the expensive one: it has
    /// Emoji_Presentation=Yes, so it must stay Apple Color Emoji rather than becoming a
    /// monochrome Nerd glyph in agent output.
    private static let nonPrivateUseCodepointsInSymbolFont: [(scalar: UInt32, label: String)] = [
        (0x23FB, "power symbol ⏻"),
        (0x23FC, "power on/off ⏼"),
        (0x23FD, "power on ⏽"),
        (0x23FE, "power sleep ⏾"),
        (0x2630, "trigram ☰"),
        (0x2665, "heart ♥"),
        (0x26A1, "high voltage ⚡ (emoji presentation)"),
        // All six of U+276C-U+2771, not just the ends: each is a separate glyph id
        // (10-15) in the shipped cmap, verified by parsing it.
        (0x276C, "medium left angle bracket ❬"),
        (0x276D, "medium right angle bracket ❭"),
        (0x276E, "heavy left angle quote ❮"),
        (0x276F, "heavy right angle quote ❯"),
        (0x2770, "heavy left angle bracket ❰"),
        (0x2771, "heavy right angle bracket ❱"),
        (0x2B58, "heavy circle ⭘"),
    ]

    func testPrimaryTextKeepsIBMPlexAndPrivateUseGlyphsReachTheSymbolFont() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)

        XCTAssertEqual(postScriptName(resolvedFont(for: "A", from: font)), "IBMPlexMono")

        // The reason the font is bundled at all: powerline separator and two Font
        // Awesome glyphs, all private-use, none of which any system font claims.
        for scalar: UInt32 in [0xE0B0, 0xF07B, 0xF00C] {
            let face = resolvedFont(for: string(scalar), from: font)
            XCTAssertEqual(
                postScriptName(face), "SymbolsNFM",
                "U+\(String(scalar, radix: 16, uppercase: true)) must resolve to the symbol font")
            XCTAssertNotEqual(
                glyph(for: scalar, in: face), 0,
                "the symbol font must have a real glyph for U+\(String(scalar, radix: 16, uppercase: true))")
        }
    }

    /// The regression the ordering fix exists for. Each of these is a codepoint the
    /// symbol font really does map, so this cannot pass vacuously — the version of this
    /// test it replaces asserted U+263A, which SymbolsNerdFontMono does not map at all,
    /// and so held no matter where the font sat in the cascade.
    func testSymbolFontDoesNotHijackCodepointsTheSystemAlreadyRenders() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        guard let symbols = UIFont(name: "SymbolsNFM", size: 12.5) else {
            return XCTFail("SymbolsNFM is not registered; the rest of this test is vacuous without it")
        }

        for (scalar, label) in Self.nonPrivateUseCodepointsInSymbolFont {
            // Precondition: the symbol font DOES map it, so losing it to the system is a
            // real ordering outcome rather than an absent glyph.
            XCTAssertNotEqual(
                glyph(for: scalar, in: symbols as CTFont), 0,
                "\(label) is expected in SymbolsNFM's cmap; if upstream dropped it, drop it here too")

            let face = postScriptName(resolvedFont(for: string(scalar), from: font))
            XCTAssertNotEqual(
                face, "SymbolsNFM",
                "\(label) must keep its system face, not the bundled symbol font")
            XCTAssertNotEqual(
                face, "LastResort",
                "\(label) resolved to LastResort, so the cascade lost it entirely")
        }
    }

    func testCJKAndEmojiStillReachTheSystemCascade() {
        let font = LiveTerminalView.Coordinator.makePaneFont(size: 12.5)
        for text in ["漢", "\u{263a}\u{fe0f}", "\u{1f600}"] {
            let name = postScriptName(resolvedFont(for: text, from: font))
            XCTAssertNotEqual(name, "SymbolsNFM", "\(text) must not come from the symbol font")
            XCTAssertNotEqual(name, "LastResort", "\(text) must reach a real system face")
        }
    }

    /// SwiftTerm's hot-path gate is CTFont IDENTITY: `usesPrimaryFont` compares the run
    /// font against `fontSet.normal` with `CFEqual`, and returns early for ordinary text.
    /// The pane font is no longer a plain registered face but a descriptor carrying a
    /// cascade list, and CTFont equality is descriptor-based — so if Core Text hands back
    /// a normalised font for unsubstituted runs, that gate fails for ALL ordinary text and
    /// every primary glyph takes two metric calls per repaint. Nothing tested that.
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

    // MARK: - helpers

    private func string(_ scalar: UInt32) -> String {
        String(UnicodeScalar(scalar)!)
    }

    private func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
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
