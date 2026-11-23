import HaloDomain
import Testing

@Suite("ArticleMarkdown (D101)")
struct ArticleMarkdownTests {
    @Test("inline formats wrap the selection, insert empty markers at the cursor, and unwrap when applied again")
    func inline() {
        let bold = ArticleMarkdown.apply(.bold, to: "say hi now", selection: 4..<6)
        #expect(bold.text == "say **hi** now" && bold.selection == 6..<8)
        let unbold = ArticleMarkdown.apply(.bold, to: bold.text, selection: bold.selection)
        #expect(unbold.text == "say hi now" && unbold.selection == 4..<6)
        let empty = ArticleMarkdown.apply(.italic, to: "ab", selection: 1..<1)
        #expect(empty.text == "a__b" && empty.selection == 2..<2)
        #expect(ArticleMarkdown.apply(.strikethrough, to: "x", selection: 0..<1).text == "~~x~~")
        #expect(ArticleMarkdown.apply(.code, to: "x", selection: 0..<1).text == "`x`")
    }

    @Test("a link keeps the selected text as its label and selects the address placeholder")
    func link() {
        let result = ArticleMarkdown.apply(.link, to: "see docs", selection: 4..<8)
        #expect(result.text == "see [docs](https://)")
        let chars = Array(result.text)
        #expect(String(chars[result.selection]) == "https://")
        #expect(ArticleMarkdown.apply(.link, to: "", selection: 0..<0).text == "[link](https://)")
    }

    @Test("line formats prefix every touched line and toggle off; numbered lists count")
    func lines() {
        let text = "one\ntwo\nthree"
        #expect(ArticleMarkdown.apply(.bulletList, to: text, selection: 1..<6).text == "- one\n- two\nthree")
        #expect(ArticleMarkdown.apply(.numberedList, to: text, selection: 0..<13).text == "1. one\n2. two\n3. three")
        let heading = ArticleMarkdown.apply(.heading, to: text, selection: 5..<5)
        #expect(heading.text == "one\n## two\nthree" && heading.selection == 8..<8)
        #expect(ArticleMarkdown.apply(.heading, to: heading.text, selection: heading.selection).text == text)
        #expect(ArticleMarkdown.apply(.quote, to: "a\nb", selection: 0..<3).text == "> a\n> b")
        #expect(ArticleMarkdown.apply(.quote, to: "> a\n> b", selection: 0..<7).text == "a\nb")
    }

    @Test("a code block fences the selection on its own lines")
    func codeBlock() {
        let result = ArticleMarkdown.apply(.codeBlock, to: "run x", selection: 4..<5)
        #expect(result.text == "run \n```\nx\n```")
        #expect(ArticleMarkdown.apply(.codeBlock, to: "", selection: 0..<0).text == "```\n\n```")
    }

    @Test("out-of-range selections are clamped")
    func clamped() {
        #expect(ArticleMarkdown.apply(.bold, to: "ab", selection: 1..<99).text == "a**b**")
    }

    @Test("the preview splits headings, paragraphs, lists, quotes, code and rules")
    func blocks() {
        let markdown = """
        # Title
        First line
        second line

        - apple
        * pear
        1. one
        2) two
        > quoted
        > more
        ---
        ```
        let x = 1
          # not a heading
        ```
        #nospace
        """
        #expect(ArticleMarkdown.blocks(markdown) == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .bullet("apple"), .bullet("pear"),
            .numbered(1, "one"), .numbered(2, "two"),
            .quote("quoted\nmore"),
            .rule,
            .code("let x = 1\n  # not a heading"),
            .paragraph("#nospace"),
        ])
        #expect(ArticleMarkdown.blocks("```\nopen") == [.code("open")])
    }

    @Test("an article needs text and must fit")
    func canSend() {
        #expect(!ArticleMarkdown.canSend(" \n "))
        #expect(ArticleMarkdown.canSend("# Hi"))
        #expect(!ArticleMarkdown.canSend(String(repeating: "a", count: ArticleMarkdown.maximumLength + 1)))
    }
}
