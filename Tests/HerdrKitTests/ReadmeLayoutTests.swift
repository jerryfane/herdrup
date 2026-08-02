import XCTest

/// The README's layout block must list every source file, and only real ones.
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

    func testTheReadmeLayoutListsEverySourceFile() throws {
        let root = repoRoot()
        let sources = root.appendingPathComponent("Sources/HerdrKit")
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(onDisk.isEmpty, "no sources found; the comparison would be vacuous")

        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        guard let start = readme.range(of: "Sources/HerdrKit/"),
              let end = readme.range(of: "```", range: start.upperBound..<readme.endIndex)
        else { return XCTFail("no layout block found in README.md") }
        let block = String(readme[start.upperBound..<end.lowerBound])

        let missing = onDisk.filter { !block.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "README layout omits \(missing.joined(separator: ", ")) — it reads as an "
                      + "inventory, so a silent omission is a false claim about the repository")

        // The other direction: a name in the README that no longer exists is the
        // same defect pointing backwards, and it is how a layout goes stale
        // without anyone deleting anything.
        let listed = block.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let name = t.split(separator: " ").first, name.hasSuffix(".swift") else { return nil }
            return String(name)
        }
        let vanished = listed.filter { !onDisk.contains($0) }
        XCTAssertTrue(vanished.isEmpty,
                      "README layout lists files that do not exist: \(vanished.joined(separator: ", "))")
    }
}
