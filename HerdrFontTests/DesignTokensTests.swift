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

    /// The agent list and sidebar read space, radius and size from the tokens. Each value is
    /// the literal its call site carried before (origin/main 42f8cf9), written out by hand.
    func testLayoutIsUnchanged() {
        let before: [(String, CGFloat, CGFloat)] = [
            // HerdrApp card / disclosureRow, AgentFolderRow: leading inset and avatar gap.
            ("space.rowLead", DesignTokens.Space.rowLead, 20),
            ("space.rowLeadIndented", DesignTokens.Space.rowLeadIndented, 44),
            ("space.avatarGap", DesignTokens.Space.avatarGap, 12),
            ("space.rowTrail", DesignTokens.Space.rowTrail, 16),
            // SectionTopBar, search field, needs-you pill, archived/terminal cards.
            ("space.screenInset", DesignTokens.Space.screenInset, 16),
            ("space.stackTight", DesignTokens.Space.stackTight, 2),
            ("space.stackSmall", DesignTokens.Space.stackSmall, 6),
            ("space.stackMedium", DesignTokens.Space.stackMedium, 8),
            ("space.stackLarge", DesignTokens.Space.stackLarge, 12),
            ("radius.selection", DesignTokens.Radius.selection, 12),
            ("radius.card", DesignTokens.Radius.card, 14),
            ("radius.group", DesignTokens.Radius.group, 18),
            ("radius.tile", DesignTokens.Radius.tile, 10),
            ("radius.badgeSquare", DesignTokens.Radius.badgeSquare, 6),
            ("size.agentRow", DesignTokens.Size.agentRow, 80),
            ("size.agentRowPhone", DesignTokens.Size.agentRowPhone, 86),
            ("size.disclosureRow", DesignTokens.Size.disclosureRow, 48),
            ("size.avatarSidebar", DesignTokens.Size.avatarSidebar, 44),
            ("size.avatarPhone", DesignTokens.Size.avatarPhone, 52),
            ("size.avatarGlyphSidebar", DesignTokens.Size.avatarGlyphSidebar, 19),
            ("size.avatarGlyphPhone", DesignTokens.Size.avatarGlyphPhone, 22),
            ("size.statusBadge", DesignTokens.Size.statusBadge, 22),
            ("size.statusBadgeStroke", DesignTokens.Size.statusBadgeStroke, 2.5),
            ("size.statusBadgeOffset", DesignTokens.Size.statusBadgeOffset, 4),
            ("size.selectionInset", DesignTokens.Size.selectionInset, 6),
            ("size.topBar", DesignTokens.Size.topBar, 50),
            ("size.topBarRow", DesignTokens.Size.topBarRow, 44),
            ("size.searchField", DesignTokens.Size.searchField, 42),
            ("size.needsYouPill", DesignTokens.Size.needsYouPill, 44),
            ("size.needsYouAvatar", DesignTokens.Size.needsYouAvatar, 32),
            ("size.tabBar", DesignTokens.Size.tabBar, 62),
            ("size.tabBarMaxWidth", DesignTokens.Size.tabBarMaxWidth, 320),
            ("size.sidebarMin", DesignTokens.Size.sidebarMin, 320),
            ("size.sidebarMax", DesignTokens.Size.sidebarMax, 460),
            ("size.rail", DesignTokens.Size.rail, 64),
            ("size.hairline", DesignTokens.Size.hairline, 1),
        ]
        for (name, now, was) in before {
            XCTAssertEqual(now, was, name)
        }
        // AgentAvatar's defaults were `diameter: CGFloat = 52`, `glyphSize: CGFloat = 22`.
        let avatar = AgentAvatar(name: "a", badge: .offline, badgeLabel: "offline")
        XCTAssertEqual(avatar.diameter, 52)
        XCTAssertEqual(avatar.glyphSize, 22)
    }

    /// The text roles the agent list and sidebar read: family (Typography.app = "app",
    /// Typography.machine = "machine", `.system(size:)` = "system"), size at scale 1 and
    /// weight, each the literal its call site carried before (origin/main 42f8cf9).
    func testTextRolesAreUnchanged() {
        typealias T = DesignTokens.Text
        let before: [(String, String, CGFloat, Font.Weight, String, CGFloat, Font.Weight)] = [
            ("barTitle", T.BarTitle.font, T.BarTitle.size, T.BarTitle.weight, "app", 17, .semibold),
            ("rowName", T.RowName.font, T.RowName.size, T.RowName.weight, "system", 16, .semibold),
            ("rowNamePhone", T.RowNamePhone.font, T.RowNamePhone.size, T.RowNamePhone.weight,
             "system", 17, .semibold),
            ("rowPreview", T.RowPreview.font, T.RowPreview.size, T.RowPreview.weight, "system", 14, .regular),
            ("rowPreviewPhone", T.RowPreviewPhone.font, T.RowPreviewPhone.size, T.RowPreviewPhone.weight,
             "system", 15, .regular),
            ("rowAge", T.RowAge.font, T.RowAge.size, T.RowAge.weight, "app", 14, .regular),
            ("rowAgePhone", T.RowAgePhone.font, T.RowAgePhone.size, T.RowAgePhone.weight, "app", 15, .regular),
            ("accountLabel", T.AccountLabel.font, T.AccountLabel.size, T.AccountLabel.weight,
             "machine", 11, .regular),
            ("markerPill", T.MarkerPill.font, T.MarkerPill.size, T.MarkerPill.weight, "app", 11, .semibold),
            ("disclosureTitle", T.DisclosureTitle.font, T.DisclosureTitle.size, T.DisclosureTitle.weight,
             "app", 17, .regular),
            ("disclosureCount", T.DisclosureCount.font, T.DisclosureCount.size, T.DisclosureCount.weight,
             "app", 15, .regular),
            ("search", T.Search.font, T.Search.size, T.Search.weight, "app", 16, .regular),
            ("pillName", T.PillName.font, T.PillName.size, T.PillName.weight, "app", 15, .semibold),
            ("pillDetail", T.PillDetail.font, T.PillDetail.size, T.PillDetail.weight, "app", 14, .regular),
            ("countPill", T.CountPill.font, T.CountPill.size, T.CountPill.weight, "app", 13, .bold),
            ("cardTitle", T.CardTitle.font, T.CardTitle.size, T.CardTitle.weight, "app", 16, .semibold),
            ("cardSubtitle", T.CardSubtitle.font, T.CardSubtitle.size, T.CardSubtitle.weight,
             "machine", 12, .regular),
            ("tabLabel", T.TabLabel.font, T.TabLabel.size, T.TabLabel.weight, "system", 10, .semibold),
            ("badgeCount", T.BadgeCount.font, T.BadgeCount.size, T.BadgeCount.weight, "system", 11, .semibold),
            ("placeholder", T.Placeholder.font, T.Placeholder.size, T.Placeholder.weight, "app", 15, .medium),
            ("empty", T.Empty.font, T.Empty.size, T.Empty.weight, "app", 15, .regular),
            ("microLabel", T.MicroLabel.font, T.MicroLabel.size, T.MicroLabel.weight, "machine", 11, .semibold),
        ]
        for (name, font, size, weight, wasFont, wasSize, wasWeight) in before {
            XCTAssertEqual(font, wasFont, "\(name).font")
            XCTAssertEqual(size, wasSize, "\(name).size")
            XCTAssertEqual(weight, wasWeight, "\(name).weight")
        }
        // The Terminals header and section labels carried `.tracking(1.2)`.
        XCTAssertEqual(T.MicroLabel.tracking, 1.2)
        // type.microLabel (Typography.microLabel) still reads the same values via text.microLabel.
        XCTAssertEqual(DesignTokens.TypeRole.MicroLabel.font, T.MicroLabel.font)
        XCTAssertEqual(CGFloat(DesignTokens.TypeRole.MicroLabel.size), T.MicroLabel.size)
        // San Francisco stays the system font (owner decision 2026-10-28).
        XCTAssertEqual(DesignTokens.Font.System.family, "system")
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
