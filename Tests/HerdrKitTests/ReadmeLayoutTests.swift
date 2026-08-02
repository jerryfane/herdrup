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

    /// Rows are PARSED and compared as sets, and EVERY entry under Sources/ is
    /// checked — not just HerdrKit's.
    ///
    /// Both corrections come from probes against my previous version:
    ///   - `block.contains(name)` searched the whole block, so deleting
    ///     Wire.swift's row passed as long as some OTHER row's description
    ///     mentioned "Wire.swift". A substring search cannot tell an inventory
    ///     entry from prose.
    ///   - the guard hardcoded Sources/HerdrKit, so replacing the Sources/CSSH
    ///     row with a nonexistent directory passed, and so did adding a whole
    ///     new target the layout never mentioned.
    ///
    /// I named that second gap in two consecutive review dispatches before
    /// closing it. Naming a gap is not closing it; it just makes the omission
    /// deliberate.
    func testTheReadmeLayoutMatchesTheRepositoryExactly() throws {
        let root = repoRoot()
        let fm = FileManager.default

        let sourcesDir = root.appendingPathComponent("Sources")
        let dirsOnDisk = Set(try fm.contentsOfDirectory(atPath: sourcesDir.path)
            .filter { name in
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: sourcesDir.appendingPathComponent(name).path,
                                  isDirectory: &isDir)
                return isDir.boolValue
            })
        XCTAssertFalse(dirsOnDisk.isEmpty, "no source directories found; the comparison is vacuous")

        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        guard let open = readme.range(of: "Sources/"),
              let close = readme.range(of: "```", range: open.lowerBound..<readme.endIndex)
        else { return XCTFail("no layout block found in README.md") }
        let block = String(readme[open.lowerBound..<close.lowerBound])

        // A row is its FIRST token. Anything after it is prose and is ignored,
        // which is the whole point of parsing rather than substring-searching.
        var dirsListed = Set<String>()
        var filesListed = Set<String>()
        for line in block.split(separator: "\n") {
            guard let token = line.split(separator: " ").first.map(String.init) else { continue }
            if token.hasPrefix("Sources/"), token.hasSuffix("/") {
                dirsListed.insert(String(token.dropFirst("Sources/".count).dropLast()))
            } else if token.hasSuffix(".swift") {
                filesListed.insert(token)
            }
        }

        XCTAssertEqual(dirsListed, dirsOnDisk,
                       "the layout's source directories do not match the repository: "
                       + "listed \(dirsListed.sorted()), on disk \(dirsOnDisk.sorted())")

        for dir in dirsOnDisk {
            let swift = Set(try fm.contentsOfDirectory(
                atPath: sourcesDir.appendingPathComponent(dir).path)
                .filter { $0.hasSuffix(".swift") })
            guard !swift.isEmpty else { continue }   // CSSH carries no Swift
            XCTAssertEqual(filesListed, swift,
                           "the layout's \(dir) files do not match the repository: "
                           + "listed \(filesListed.sorted()), on disk \(swift.sorted())")
        }
    }
}
