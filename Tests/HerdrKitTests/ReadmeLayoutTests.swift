import XCTest

/// Every path the README's layout NAMES must exist. It deliberately does not
/// check the reverse — see the test's own comment for why that claim was
/// dropped after four rounds of trying to make it correct.
///
/// WHY THIS IS A TEST AND NOT A SCRIPT: I described that block as "generated
/// from `ls`, and the generator fails if a file has no description" — and then
/// committed only its OUTPUT. The generator existed for one invocation in a
/// shell. Review added an undescribed source file, the warnings-as-errors build
/// compiled it, and nothing noticed: the safeguard I had claimed did not exist
/// in the repository at all.
///
/// A guard that lives in someone's terminal history is not a guard. This one
/// runs with `swift test`, so a file added without a README entry fails the
/// suite rather than silently narrowing an inventory that reads as exhaustive.
final class ReadmeLayoutTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HerdrKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    /// Every file the README NAMES must exist. It does not claim the reverse.
    ///
    /// THIS IS A DELIBERATE REVERSAL, and worth explaining because the previous
    /// direction cost four review rounds. I had the layout assert COMPLETENESS —
    /// every source file must appear — which meant the guard had to model
    /// SwiftPM's source graph to be correct: nested sources, targets with custom
    /// paths, and more than one Swift target. It could not, and each round found
    /// another way it was wrong. Worse, it would have FALSE-FAILED the moment
    /// the iOS app target lands, which is the next piece of work.
    ///
    /// Review offered this option in round four and I took the harder path. The
    /// README is a guide, not an inventory; making it claim exhaustiveness meant
    /// maintaining a second, worse copy of the package manifest. So the claim is
    /// dropped and the block says so, leaving the one property that is cheap,
    /// true, and useful: A NAME IN THE DOCS POINTS AT SOMETHING REAL. That is
    /// what actually rots — files get renamed and the prose does not follow.
    func testEveryFileTheReadmeNamesExists() throws {
        let root = repoRoot()
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        guard let open = readme.range(of: "Sources/"),
              let close = readme.range(of: "```", range: open.lowerBound..<readme.endIndex)
        else { return XCTFail("no layout block found in README.md") }
        let block = String(readme[open.lowerBound..<close.lowerBound])

        // UNRECOGNISED ROWS FAIL; they do not vanish. The previous parser skipped
        // anything whose first token it did not understand, so wrapping a name
        // in backticks silently removed it from the guard — the file could then
        // name something nonexistent and pass. A parser that ignores what it
        // cannot read is a filter, not a check, and the thing it filters out is
        // exactly the thing nobody looked at.
        //
        // I named this risk in my own review dispatch and shipped without
        // closing it. Twice, on this file.
        var named: [String] = []
        var unparsed: [String] = []
        for line in block.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let token = String(text.split(separator: " ").first ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "`*-+•│├└─"))
            if token.hasSuffix(".swift") { named.append("Sources/HerdrKit/" + token) }
            else if token.hasPrefix("Sources/"), token.hasSuffix("/") { named.append(String(token.dropLast())) }
            else { unparsed.append(text) }
        }
        XCTAssertTrue(unparsed.isEmpty,
                      "layout rows the guard cannot read, so it cannot check them: "
                      + unparsed.joined(separator: " | "))
        XCTAssertFalse(named.isEmpty, "no entries parsed from the layout; the check is vacuous")

        let missing = named.filter { !FileManager.default.fileExists(
            atPath: root.appendingPathComponent($0).path) }
        XCTAssertTrue(missing.isEmpty,
                      "the README names paths that do not exist: \(missing.joined(separator: ", "))")
    }
}
