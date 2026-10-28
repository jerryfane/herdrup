import SwiftUI
import XCTest
@testable import Herdr

/// The app's colours and fonts moved from Swift literals into design/tokens.json, read
/// through the generated `DesignTokens` (owner decision 2026-10-28). The move changes
/// nothing on screen: every value below is the literal DesignSystem.swift and
/// ChatPalette.swift carried before the move (origin/main 8d637c6), written out by hand.
/// A token edited on purpose fails here, and the literal is updated with it.
final class DesignTokensTests: XCTestCase {
    func testPaletteIsUnchanged() {
        let before: [(String, Color, Color)] = [
            ("ground", Palette.ground, Color(hex: 0x13162A)),
            ("groundMachine", Palette.groundMachine, Color(hex: 0x0B0D1C)),
            ("surface", Palette.surface, Color(hex: 0x1D2038)),
            ("card", Palette.card, Color(hex: 0x1D2038)),
            ("surfaceRaised", Palette.surfaceRaised, Color(hex: 0x262A45)),
            ("hairline", Palette.hairline, Color(hex: 0x2E3358)),
            ("hairlineQuiet", Palette.hairlineQuiet, Color(hex: 0x232742)),
            ("text", Palette.text, Color(hex: 0xEEF0F7)),
            ("textDim", Palette.textDim, Color(hex: 0x99A0BC)),
            ("textFaint", Palette.textFaint, Color(hex: 0x666D91)),
            ("brand", Palette.brand, Color(hex: 0x7A6FF0)),
            ("onAccent", Palette.onAccent, Color.white),
            ("onAccentDim", Palette.onAccentDim, Color.white.opacity(0.82)),
            ("waiting", Palette.waiting, Color(hex: 0xE9A63C)),
            ("died", Palette.died, Color(hex: 0xE2584E)),
            ("working", Palette.working, Color(hex: 0x5B9BE8)),
            ("done", Palette.done, Color(hex: 0x5FB37F)),
        ]
        for (name, now, was) in before {
            assertSameColour(now, was, "Palette.\(name)")
        }
    }

    /// AgentGroup.color (HerdrKit's group, coloured in DesignSystem.swift) was needsYou and
    /// unrecognised Palette.waiting, stopped Palette.died, working Palette.working, idle
    /// Palette.textFaint. It now reads DesignTokens.Group, whose references must land there.
    func testGroupColoursAreUnchanged() {
        XCTAssertEqual(DesignTokens.Group.needsYou, 0xE9A63C)
        XCTAssertEqual(DesignTokens.Group.stopped, 0xE2584E)
        XCTAssertEqual(DesignTokens.Group.unrecognised, 0xE9A63C)
        XCTAssertEqual(DesignTokens.Group.working, 0x5B9BE8)
        XCTAssertEqual(DesignTokens.Group.idle, 0x666D91)
    }

    func testAgentGradientsAreUnchanged() {
        XCTAssertEqual(AgentIdentity.stops(for: "claude"), [0xCE58A4, 0xA32E77])
        XCTAssertEqual(AgentIdentity.stops(for: "codex"), [0xE8923C, 0xC5622A])
        XCTAssertEqual(AgentIdentity.stops(for: "gemini"), [0x4C6EF5, 0x2E44C4])
        XCTAssertEqual(AgentIdentity.stops(for: "omp"), [0x8B79F6, 0x5B44C9])
        XCTAssertEqual(AgentIdentity.stops(for: nil), [0x8B79F6, 0x5B44C9])

        // By name, through HerdrKit's AgentPresentation.colorIndex (FNV-1a, stable across
        // launches): index 0 violet, 1 magenta, 2 orange, else indigo. These four names hash
        // to indexes 0, 1, 2 and 3.
        XCTAssertEqual(AgentIdentity.stops(forName: "gemini"), [0x8B79F6, 0x5B44C9])
        XCTAssertEqual(AgentIdentity.stops(forName: "Bob"), [0xCE58A4, 0xA32E77])
        XCTAssertEqual(AgentIdentity.stops(forName: "Ada"), [0xE8923C, 0xC5622A])
        XCTAssertEqual(AgentIdentity.stops(forName: "x"), [0x4C6EF5, 0x2E44C4])
    }

    func testChatPalettesAreUnchanged() {
        XCTAssertEqual(ChatPalette.darkTokyoNight, ChatPalette(
            heading: 0xBB9AF7, toolTitle: 0xBB9AF7,
            codeText: 0xA9B1D6, codeBackground: 0x16161E, codeBorder: 0x363B54,
            keyword: 0xBB9AF7, string: 0x9ECE6A, comment: 0x51597D, function: 0x7AA2F7,
            number: 0xFF9E64, type: 0x0DB9D7, op: 0xA9B1D6,
            inserted: 0x9ECE6A, deleted: 0xF7768E))
        XCTAssertEqual(ChatPalette.lightTokyoNight, ChatPalette(
            heading: 0xB15C00, toolTitle: 0x3760BF,
            codeText: 0x6172B0, codeBackground: 0xE1E2E7, codeBorder: 0xB4B5B9,
            keyword: 0x7847BD, string: 0x587539, comment: 0x848CB5, function: 0x2E7DE9,
            number: 0xB15C00, type: 0x007197, op: 0x9854F1,
            inserted: 0x587539, deleted: 0xC64343))
        XCTAssertEqual(ChatPalette.current, ChatPalette.darkTokyoNight)
    }

    func testFontNamesAreUnchanged() {
        let geist: [(Font.Weight, String)] = [
            (.ultraLight, "Geist-Regular"), (.thin, "Geist-Regular"), (.light, "Geist-Regular"),
            (.regular, "Geist-Regular"), (.medium, "Geist-Medium"), (.semibold, "Geist-SemiBold"),
            (.bold, "Geist-Bold"), (.heavy, "Geist-Bold"), (.black, "Geist-Bold"),
        ]
        for (weight, name) in geist {
            XCTAssertEqual(Typography.geistName(weight), name, "\(weight)")
        }
        let plex: [(Font.Weight, String)] = [
            (.ultraLight, "IBMPlexMono"), (.thin, "IBMPlexMono"), (.light, "IBMPlexMono"),
            (.regular, "IBMPlexMono"), (.medium, "IBMPlexMono-Medm"), (.semibold, "IBMPlexMono-SmBld"),
            (.bold, "IBMPlexMono-Bold"), (.heavy, "IBMPlexMono-Bold"), (.black, "IBMPlexMono-Bold"),
        ]
        for (weight, name) in plex {
            XCTAssertEqual(Typography.plexMonoName(weight), name, "\(weight)")
        }
        // Typography.microLabel was `.custom("IBMPlexMono-SmBld", fixedSize: 11 * scale)`.
        XCTAssertEqual(DesignTokens.TypeRole.MicroLabel.postscript, "IBMPlexMono-SmBld")
        XCTAssertEqual(DesignTokens.TypeRole.MicroLabel.size, 11)
    }

    /// Two colours are the same on screen when they resolve to the same components and opacity.
    private func assertSameColour(_ now: Color, _ was: Color, _ name: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let a = components(now), b = components(was)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y, accuracy: 1e-6, "\(name): \(a) is not \(b)", file: file, line: line)
        }
    }

    private func components(_ colour: Color) -> [Float] {
        let resolved = colour.resolve(in: EnvironmentValues())
        return [resolved.red, resolved.green, resolved.blue, resolved.opacity]
    }
}
