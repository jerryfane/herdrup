import XCTest

extension XCUIApplication {
    /// The menu button identified `identifier`, or labelled `label`.
    ///
    /// ON iOS 27 A BUTTON INSIDE A MENU `Section` LOSES ITS ACCESSIBILITY IDENTIFIER. Run
    /// 40728450580 (Xcode 27.1, iOS 27.0 simulator) had the ⋯ menu open and listed
    /// `Button, label: 'Increase'` under "Text size" with no `terminal-font-increase` or
    /// `guest-font-increase`, while the same menu's top-level entries (`terminal-share`,
    /// `agent-avatar-edit`) kept theirs; on iOS 26 the identifier was there. The label is the
    /// entry's visible title, so it names the same entry.
    func menuEntry(_ identifier: String, label: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }
}
