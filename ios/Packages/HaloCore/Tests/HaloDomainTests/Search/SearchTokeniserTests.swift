import HaloDomain
import HaloFoundation
import Testing

@Suite("SearchTokeniser")
struct SearchTokeniserTests {
    /// What FTS5 does with the expression, over the words of `text`.
    private func matches(_ text: String, _ query: String) -> Bool {
        let words = SearchTokeniser.tokens(text).map(\.text)
        let terms = SearchTokeniser.terms(query)
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { term in
            switch term {
            case .prefix(let prefix): words.contains { $0.hasPrefix(prefix) }
            case .phrase(let phrase): words.indices.contains { words[$0...].starts(with: phrase) }
            }
        }
    }

    @Test("CJK by any part in order, mixed with Latin; accents and case don't matter (AC-SRCH-5)")
    func finds() {
        for query in ["今天", "天去", "apple", "AppleStore", "今天去", "去apple", "ＡＰＰＬＥ"] { #expect(matches("今天去AppleStore", query), "\(query)") }
        #expect(!matches("今天去AppleStore", "天今"))
        #expect(!matches("今天去AppleStore", "store"))
        #expect(matches("Café", "cafe") && matches("cafe", "CAFÉ") && matches("İstanbul", "istanbul"))
        #expect(matches("カタカナ", "ｶﾀｶﾅ") && matches("ガギグ", "ｶﾞｷﾞ"))
        #expect(!matches("がっこう", "かっこう"), "voicing marks make other letters")
        #expect(matches("안녕하세요 세계", "녕하") && matches("今、天", "今 天"))
        #expect(matches("release-notes_v2.pdf", "notes") && matches("https://example.org/Path", "example.org"))
        #expect(matches("สวัสดีครับ", "สวัสดี"))
        #expect(matches("Straße 12", "straße") && matches("naïve e\u{301}te\u{301}", "été"))
    }

    @Test("a space between CJK characters of a query separates two terms")
    func separateTerms() {
        #expect(SearchTokeniser.terms("今天 去") == [.phrase(["今", "天"]), .phrase(["去"])])
        #expect(SearchTokeniser.terms("去Apple") == [.phrase(["去"]), .prefix("apple")])
    }

    @Test("nothing typed is ever FTS5 syntax; nothing to search for gives no expression (AC-SRCH-7)")
    func safety() {
        for query in ["", "   ", "\"", "***", "()", "-", "😀", "…", "AND OR NOT()".filter { "()".contains($0) }] {
            #expect(SearchTokeniser.matchExpression(query) == nil, "\(query)")
        }
        #expect(SearchTokeniser.matchExpression("a OR b") == "\"a\"* \"or\"* \"b\"*")
        #expect(SearchTokeniser.matchExpression("NEAR(x, 2)") == "\"near\"* \"x\"* \"2\"*")
        #expect(SearchTokeniser.matchExpression("col:x*") == "\"col\"* \"x\"*")
        #expect(SearchTokeniser.matchExpression("今天") == "\"今 天\"")
        let long = SearchTokeniser.matchExpression(String(repeating: "word ", count: 2_000)) ?? ""
        #expect(long.split(separator: " ").count == SearchTokeniser.maximumTerms)
        #expect(SearchTokeniser.matchExpression(String(repeating: "x", count: 10_000))?.count == SearchTokeniser.maximumQueryCharacters + 3)
    }

    @Test("highlights mark what matched, in the original text")
    func highlights() {
        func marked(_ text: String, _ query: String) -> [String] { SearchTokeniser.highlights(in: text, query: query).map { String(text[$0]) } }
        #expect(marked("Das Café am Café-Platz", "cafe") == ["Café", "Café"])
        #expect(marked("今天去AppleStore，今天", "今天 apple") == ["今天", "Apple", "今天"])
        #expect(marked("ＡＢＣ def", "abc") == ["ＡＢＣ"])
        #expect(marked("hello", "world").isEmpty && marked("hello", "").isEmpty)
        #expect(marked("foobar", "foo foobar") == ["foobar"])
        #expect(marked("a 👨‍👩‍👧 family", "family") == ["family"])
    }

    @Test("a snippet shows the part around the match")
    func snippet() {
        let long = String(repeating: "lorem ipsum ", count: 40) + "needle" + String(repeating: " dolor sit", count: 40)
        let snippet = SearchTokeniser.snippet(of: long, query: "needle")
        #expect(snippet.contains("needle") && snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.count <= 162)
        #expect(SearchTokeniser.snippet(of: "short\ntext", query: "text") == "short text")
    }

    @Test("the words of the index and of the highlighting agree")
    func consistent() {
        for text in ["Ünïcödé ﬁne", "㍿会社", "ﾊﾟﾋﾟ", "x²", "Ⅷ chapters", "한국어 테스트", "e\u{301}a\u{308}", "a1b2", "Ångström"] {
            for token in SearchTokeniser.tokens(text) {
                #expect(!SearchTokeniser.highlights(in: text, query: token.text).isEmpty, "\(text): \(token.text)")
            }
        }
    }

    @Test("preview computes single-pass snippet and character offsets identically, including on 20,000-character messages")
    func previewPerformanceAndAccuracy() {
        for (body, query) in [
            ("Das Café am Café-Platz", "cafe"),
            ("今天去AppleStore，今天", "今天 apple"),
            ("a 👨‍👩‍👧 family\nwith newline", "family"),
            (String(repeating: "lorem ipsum ", count: 40) + "needle" + String(repeating: " dolor sit", count: 40), "needle"),
        ] {
            let expectedSnippet = SearchTokeniser.snippet(of: body, query: query)
            let expectedOffsets = SearchTokeniser.highlights(in: expectedSnippet, query: query).map { range in
                expectedSnippet.distance(from: expectedSnippet.startIndex, to: range.lowerBound)
                    ..< expectedSnippet.distance(from: expectedSnippet.startIndex, to: range.upperBound)
            }
            let preview = SearchTokeniser.preview(of: body, query: query)
            #expect(preview.text == expectedSnippet)
            #expect(preview.highlights == expectedOffsets)
        }

        // A 20,000-character Markdown article with an early match stops near the match instead of scanning the entire body twice.
        let huge = "Intro: deploy checklist ready. " + String(repeating: "background notes and prose ", count: 800)
        let started = ContinuousClock.now
        let preview = SearchTokeniser.preview(of: huge, query: "deploy")
        let elapsed = ContinuousClock.now - started
        #expect(preview.text.hasPrefix("Intro: deploy checklist ready."))
        #expect(preview.highlights == [7..<13])
        #expect(elapsed < .milliseconds(50))
    }
}

@Suite("SearchContent")
struct SearchContentTests {
    @Test("messages, replies, links, attachments, polls")
    func parse() throws {
        func content(_ json: String) -> SearchableContent? { SearchContent.parse(message: json)?.content }
        #expect(content(#"{"msgtype":"m.text","body":"hello **world**"}"#) == SearchableContent(kind: .message, body: "hello **world**"))
        #expect(content(#"{"msgtype":"m.text","body":"> <@a:x> old\n> line\n\nnew","m.relates_to":{"m.in_reply_to":{"event_id":"$1"}}}"#)?.body == "new")
        #expect(content(#"{"msgtype":"m.text","body":"> quoted on purpose"}"#)?.body == "> quoted on purpose")
        #expect(content(#"{"msgtype":"m.notice","body":"see https://example.org/a"}"#)?.kind == .link)
        let html = content(#"{"msgtype":"m.text","body":"docs","formatted_body":"<a href=\"https://example.org/?a=1&amp;b=2\">docs</a> <a href=\"https://matrix.to/#/@bob:x\">Bob</a>"}"#)
        #expect(html == SearchableContent(kind: .link, body: "docs", extra: ["https://example.org/?a=1&b=2"]))
        #expect(content(#"{"msgtype":"m.file","body":"report.pdf"}"#) == SearchableContent(
            kind: .file, body: "report.pdf",
            attachment: SearchAttachment(mediaKind: .file, filename: "report.pdf")))
        #expect(content(#"{"msgtype":"m.image","body":"our trip","filename":"IMG_1.jpg","info":{"mimetype":"image/png","size":1400000}}"#) == SearchableContent(
            kind: .media, body: "our trip", extra: ["IMG_1.jpg"],
            attachment: SearchAttachment(mediaKind: .image, filename: "IMG_1.jpg", mimeType: "image/png", sizeBytes: 1_400_000)))
        #expect(SearchAttachment(mediaKind: .image, filename: "IMG_1.png", mimeType: "image/png", sizeBytes: 1_400_000).subtitle == "PNG (1.4 MB)")
        #expect(SearchAttachment(mediaKind: .file, filename: "notes.pdf", sizeBytes: 240_000).subtitle == "PDF (240 KB)")
        #expect(content(#"{"msgtype":"dm.filament.gallery","body":"","itemtypes":[{"filename":"a.png"},{"body":"b.png"}]}"#)?.extra == ["a.png", "b.png"])
        #expect(content(#"{"msgtype":"m.location","body":"here","geo_uri":"geo:1,2"}"#) == nil)
        #expect(content(#"{"msgtype":"m.text","body":"   "}"#) == nil)
        #expect(content("{}") == nil && SearchContent.parse(message: "nonsense") == nil)
        let poll = SearchContent.parse(poll: #"{"org.matrix.msc3381.poll.start":{"question":{"org.matrix.msc1767.text":"Lunch?"},"answers":[{"id":"1","org.matrix.msc1767.text":"Pizza"},{"id":"2","m.text":[{"body":"Soup"}]}]}}"#)
        #expect(poll?.content == SearchableContent(kind: .message, body: "Lunch?", extra: ["Pizza", "Soup"]))
    }

    @Test("edits name what they replace; threads their root")
    func relations() throws {
        let edit = SearchContent.parse(message: ##"{"msgtype":"m.text","body":"* new","m.new_content":{"msgtype":"m.text","body":"new"},"m.relates_to":{"rel_type":"m.replace","event_id":"$old"}}"##)
        #expect(edit?.content?.body == "new" && edit?.replaces?.rawValue == "$old" && edit?.threadRoot == nil)
        let threaded = SearchContent.parse(message: ##"{"msgtype":"m.text","body":"t","m.relates_to":{"rel_type":"m.thread","event_id":"$root","is_falling_back":true,"m.in_reply_to":{"event_id":"$x"}}}"##)
        #expect(threaded?.threadRoot?.rawValue == "$root" && threaded?.replaces == nil)
    }
}
