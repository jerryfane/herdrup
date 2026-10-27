import XCTest
@testable import HerdrKit

final class CodeHighlighterTests: XCTestCase {
    /// The kind of each run whose text is exactly `text` (trimmed), in order.
    private func kinds(_ spans: [CodeSpan], of text: String) -> [CodeTokenKind?] {
        spans.filter { $0.text.trimmingCharacters(in: .whitespaces) == text }.map(\.kind)
    }

    private func kind(_ spans: [CodeSpan], of text: String,
                      file: StaticString = #filePath, line: UInt = #line) -> CodeTokenKind? {
        let found = kinds(spans, of: text)
        XCTAssertFalse(found.isEmpty, "no run is exactly \(text): \(spans)", file: file, line: line)
        return found.first ?? nil
    }

    private func assertRoundTrips(_ code: String, _ spans: [CodeSpan],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(spans.map(\.text).joined(), code, "the spans must join back to the code", file: file, line: line)
    }

    func testSwiftKeywordsStringsCommentsAndCalls() throws {
        let code = """
        // Keep the visible row anchored
        let anchor = rows.first { $0.visible }
        func resort(_ rows: [Row]) -> [Row] {
            return rows.sorted(by: rank) /* stable */
        }
        let label = "Agents \\(count)"
        let limit = 42
        """
        let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: "swift"))
        assertRoundTrips(code, spans)
        XCTAssertEqual(kind(spans, of: "// Keep the visible row anchored"), .comment)
        XCTAssertEqual(kind(spans, of: "/* stable */"), .comment)
        XCTAssertEqual(kinds(spans, of: "let"), [.keyword, .keyword, .keyword])
        XCTAssertEqual(kind(spans, of: "func"), .keyword)
        XCTAssertEqual(kind(spans, of: "return"), .keyword)
        XCTAssertEqual(kind(spans, of: "\"Agents \\(count)\""), .string)
        XCTAssertEqual(kind(spans, of: "42"), .number)
        XCTAssertEqual(kind(spans, of: "sorted"), .function)
        XCTAssertEqual(kind(spans, of: "first"), .function, "a trailing-closure call is a call")
        XCTAssertEqual(kinds(spans, of: "Row"), [.type, .type])
        XCTAssertEqual(kind(spans, of: "->"), .op)
        // Plain names stay plain, and a keyword inside a word is not a keyword.
        XCTAssertEqual(kind(spans, of: "anchor"), nil)
        XCTAssertEqual(kind(spans, of: "limit"), nil)
    }

    func testSwiftKeywordsInsideStringsAndCommentsStayThere() throws {
        let code = "let s = \"let x = 1 // not a comment\" // let y"
        let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: "swift"))
        assertRoundTrips(code, spans)
        XCTAssertEqual(kinds(spans, of: "let"), [.keyword])
        XCTAssertEqual(kind(spans, of: "\"let x = 1 // not a comment\""), .string)
        XCTAssertEqual(kind(spans, of: "// let y"), .comment)
    }

    func testRustKeywordsStringsCommentsLifetimesAndMacros() throws {
        let code = """
        // Count the rows
        pub fn count<'a>(rows: &'a [Row]) -> usize {
            let name = "herdr";
            let sep = ',';
            println!("{name}");
            rows.len() + 0x1F
        }
        """
        let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: "rs"))
        assertRoundTrips(code, spans)
        XCTAssertEqual(kind(spans, of: "// Count the rows"), .comment)
        XCTAssertEqual(kind(spans, of: "pub"), .keyword)
        XCTAssertEqual(kind(spans, of: "fn"), .keyword)
        XCTAssertEqual(kinds(spans, of: "let"), [.keyword, .keyword])
        XCTAssertEqual(kind(spans, of: "\"herdr\""), .string)
        XCTAssertEqual(kind(spans, of: "','"), .string, "a char literal is a string")
        XCTAssertEqual(kind(spans, of: "count"), .function)
        XCTAssertEqual(kind(spans, of: "println"), .function, "a macro call is a call")
        XCTAssertEqual(kind(spans, of: "len"), .function)
        XCTAssertEqual(kind(spans, of: "usize"), .type)
        XCTAssertEqual(kind(spans, of: "Row"), .type)
        XCTAssertEqual(kind(spans, of: "0x1F"), .number)
        // A lifetime does not open a string that swallows the rest of the line.
        XCTAssertFalse(spans.contains { $0.kind == .string && $0.text.contains("rows") }, "\(spans)")
    }

    func testBashCommandsKeywordsStringsCommentsAndVariables() throws {
        let code = """
        # Run the checks
        if [ -n "$HOME" ]; then
          git status --short | wc -l
          echo 'done' $USER 3
        fi
        """
        let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: "sh"))
        assertRoundTrips(code, spans)
        XCTAssertEqual(kind(spans, of: "# Run the checks"), .comment)
        XCTAssertEqual(kind(spans, of: "if"), .keyword)
        XCTAssertEqual(kind(spans, of: "then"), .keyword)
        XCTAssertEqual(kind(spans, of: "fi"), .keyword)
        XCTAssertEqual(kind(spans, of: "\"$HOME\""), .string)
        XCTAssertEqual(kind(spans, of: "'done'"), .string)
        XCTAssertEqual(kind(spans, of: "git"), .function, "a command's first word is the command")
        XCTAssertEqual(kind(spans, of: "wc"), .function, "a pipe starts a new command")
        XCTAssertEqual(kind(spans, of: "echo"), .function)
        XCTAssertEqual(kind(spans, of: "$USER"), .type)
        XCTAssertEqual(kind(spans, of: "3"), .number)
        XCTAssertFalse(spans.contains { $0.kind != nil && $0.text.contains("status") },
                       "an argument is not a command: \(spans)")
        XCTAssertEqual(kind(spans, of: "|"), .op)
    }

    func testBashHashInsideAWordIsNotAComment() throws {
        let code = "echo a#b"
        let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: "bash"))
        assertRoundTrips(code, spans)
        XCTAssertFalse(spans.contains { $0.kind == .comment }, "\(spans)")
    }

    func testUnknownOrMissingLanguagesStayPlain() {
        XCTAssertNil(CodeHighlighter.spans("let x = 1", language: nil))
        XCTAssertNil(CodeHighlighter.spans("let x = 1", language: ""))
        XCTAssertNil(CodeHighlighter.spans("let x = 1", language: "text"))
        XCTAssertNil(CodeHighlighter.spans("graph TD\n  A --> B", language: "mermaid"))
        XCTAssertNil(CodeHighlighter.spans("SELECT 1", language: "brainfudge"))
    }

    func testFenceAliasesNameTheirLanguage() {
        XCTAssertEqual(CodeLanguage(fence: "TS"), .javascript)
        XCTAssertEqual(CodeLanguage(fence: "tsx"), .javascript)
        XCTAssertEqual(CodeLanguage(fence: "py"), .python)
        XCTAssertEqual(CodeLanguage(fence: "zsh"), .bash)
        XCTAssertEqual(CodeLanguage(fence: "yml"), .yaml)
        XCTAssertEqual(CodeLanguage(fence: "golang"), .go)
        XCTAssertEqual(CodeLanguage(fence: "patch"), .diff)
    }

    func testTypeScriptPythonGoJsonYamlAndDiff() throws {
        let ts = "const n: number = await load(`a ${b}`) // done"
        let tsSpans = try XCTUnwrap(CodeHighlighter.spans(ts, language: "ts"))
        assertRoundTrips(ts, tsSpans)
        XCTAssertEqual(kind(tsSpans, of: "const"), .keyword)
        XCTAssertEqual(kind(tsSpans, of: "number"), .type)
        XCTAssertEqual(kind(tsSpans, of: "load"), .function)
        XCTAssertEqual(kind(tsSpans, of: "`a ${b}`"), .string)
        XCTAssertEqual(kind(tsSpans, of: "// done"), .comment)

        let py = "def f(x):\n    \"\"\"Doc\"\"\"\n    return None  # nothing"
        let pySpans = try XCTUnwrap(CodeHighlighter.spans(py, language: "python"))
        assertRoundTrips(py, pySpans)
        XCTAssertEqual(kind(pySpans, of: "def"), .keyword)
        XCTAssertEqual(kind(pySpans, of: "\"\"\"Doc\"\"\""), .string)
        XCTAssertEqual(kind(pySpans, of: "None"), .keyword)
        XCTAssertEqual(kind(pySpans, of: "# nothing"), .comment)

        let go = "func main() { fmt.Println(\"hi\", 3.5) }"
        let goSpans = try XCTUnwrap(CodeHighlighter.spans(go, language: "go"))
        assertRoundTrips(go, goSpans)
        XCTAssertEqual(kind(goSpans, of: "func"), .keyword)
        XCTAssertEqual(kind(goSpans, of: "Println"), .function)
        XCTAssertEqual(kind(goSpans, of: "3.5"), .number)

        let json = "{\"name\": \"herdr\", \"n\": 2, \"ok\": true}"
        let jsonSpans = try XCTUnwrap(CodeHighlighter.spans(json, language: "json"))
        assertRoundTrips(json, jsonSpans)
        XCTAssertEqual(kind(jsonSpans, of: "\"name\""), .function, "a key")
        XCTAssertEqual(kind(jsonSpans, of: "\"herdr\""), .string)
        XCTAssertEqual(kind(jsonSpans, of: "2"), .number)
        XCTAssertEqual(kind(jsonSpans, of: "true"), .keyword)

        let yaml = "theme:\n  dark: dark-tokyo-night # owner's\n  on: true"
        let yamlSpans = try XCTUnwrap(CodeHighlighter.spans(yaml, language: "yaml"))
        assertRoundTrips(yaml, yamlSpans)
        XCTAssertEqual(kind(yamlSpans, of: "theme"), .function)
        XCTAssertEqual(kind(yamlSpans, of: "dark"), .function)
        XCTAssertEqual(kind(yamlSpans, of: "# owner's"), .comment)
        XCTAssertFalse(yamlSpans.contains { $0.kind != nil && $0.text.contains("tokyo") },
                       "a plain value stays plain, dashes and all: \(yamlSpans)")

        let diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same"
        let diffSpans = try XCTUnwrap(CodeHighlighter.spans(diff, language: "diff"))
        assertRoundTrips(diff, diffSpans)
        XCTAssertEqual(kind(diffSpans, of: "-old"), .deleted)
        XCTAssertEqual(kind(diffSpans, of: "+new"), .inserted)
        XCTAssertEqual(kind(diffSpans, of: "@@ -1 +1 @@"), .function)
    }

    func testUnterminatedStringsAndCommentsEndCleanly() throws {
        for (code, language) in [("let s = \"open", "swift"), ("/* open", "rust"), ("echo \"open", "bash"),
                                 ("x = '''open", "python"), ("", "swift")] {
            let spans = try XCTUnwrap(CodeHighlighter.spans(code, language: language))
            assertRoundTrips(code, spans)
        }
    }
}
