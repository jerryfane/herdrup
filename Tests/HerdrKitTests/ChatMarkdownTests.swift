import XCTest
@testable import HerdrKit

final class ChatMarkdownTests: XCTestCase {

    func testSplitsAReplyIntoNativeBlocks() {
        let blocks = ChatMarkdown.blocks("""
        Done. Scrolling up now keeps loading, **500 lines at a time**.
        Second line of the same paragraph.

        ## Results

        - Tested on a real server: no gaps.
        - The app part is in `#477`;
          the server part is `#305`.
          - nested detail
        - [x] merged

        1. First
        2) Second

        | Metric | Q5 | Change |
        |---|:--:|---:|
        | Decode | 41.2 tok/s | +36% |
        | Prefill | 1,180 tok/s |

        ```swift
        let x = 1

        print(x)
        ```

        > quoted
        > twice

        ---
        Final words.
        """)
        XCTAssertEqual(blocks, [
            .paragraph("Done. Scrolling up now keeps loading, **500 lines at a time**.\nSecond line of the same paragraph."),
            .heading(level: 2, "Results"),
            .list(ordered: false, start: 1, items: [
                ChatMarkdownListItem(text: "Tested on a real server: no gaps."),
                ChatMarkdownListItem(text: "The app part is in `#477`;\nthe server part is `#305`."),
                ChatMarkdownListItem(text: "nested detail", depth: 1),
                ChatMarkdownListItem(text: "merged", checked: true),
            ]),
            .list(ordered: true, start: 1, items: [
                ChatMarkdownListItem(text: "First"),
                ChatMarkdownListItem(text: "Second"),
            ]),
            .table(header: ["Metric", "Q5", "Change"], rows: [
                ["Decode", "41.2 tok/s", "+36%"],
                ["Prefill", "1,180 tok/s", ""],
            ]),
            .code(language: "swift", "let x = 1\n\nprint(x)"),
            .quote("quoted\ntwice"),
            .rule,
            .paragraph("Final words."),
        ])
    }

    func testUnclosedFenceRunsToTheEndAndPlainTextIsOneParagraph() {
        XCTAssertEqual(ChatMarkdown.blocks("```\ncode"), [.code(language: nil, "code")])
        XCTAssertEqual(ChatMarkdown.blocks("just text"), [.paragraph("just text")])
        XCTAssertEqual(ChatMarkdown.blocks("#hashtag not a heading"), [.paragraph("#hashtag not a heading")])
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
    }

    func testOrderedListKeepsItsStartNumber() {
        XCTAssertEqual(ChatMarkdown.blocks("3. three\n4. four"), [
            .list(ordered: true, start: 3, items: [ChatMarkdownListItem(text: "three"), ChatMarkdownListItem(text: "four")]),
        ])
    }
}
