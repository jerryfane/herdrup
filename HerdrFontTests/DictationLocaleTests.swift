import XCTest
@testable import Herdr

/// Which speech-recognition locales dictation tries, in order. A phone whose region and
/// language disagree (English UI, Italian region: "en_IT") is not itself a supported
/// recognizer locale, and treating it as one reported "not available for your language".
final class DictationLocaleTests: XCTestCase {
    private let supported: Set<Locale> = Set(
        ["en-US", "en-GB", "en-AU", "it-IT", "it-CH", "fr-FR"].map(Locale.init(identifier:)))

    func testMismatchedRegionStillFindsTheLanguage() {
        let ranked = DictationLocale.ranked(Locale(identifier: "en_IT"), in: supported).map(\.identifier)
        XCTAssertEqual(Set(ranked), ["en-US", "en-GB", "en-AU"],
                       "every supported English locale is a candidate for en_IT")
    }

    func testSameRegionComesFirst() {
        let ranked = DictationLocale.ranked(Locale(identifier: "it_CH"), in: supported).map(\.identifier)
        XCTAssertEqual(ranked.first, "it-CH")
        XCTAssertEqual(Set(ranked), ["it-CH", "it-IT"])
    }

    func testUnsupportedLanguageHasNoCandidates() {
        XCTAssertTrue(DictationLocale.ranked(Locale(identifier: "ja_JP"), in: supported).isEmpty)
    }

    @MainActor
    func testCandidatesStartWithTheRegionLocaleAndHaveNoDuplicates() {
        let candidates = DictationLocale.candidates().map(\.identifier)
        XCTAssertEqual(candidates.first, Locale.current.identifier)
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }
}
