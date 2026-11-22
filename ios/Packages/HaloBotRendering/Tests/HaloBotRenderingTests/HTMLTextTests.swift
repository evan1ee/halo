import Foundation
import Testing
@testable import HaloBotRendering

@Suite("HTMLText")
struct HTMLTextTests {
    private func runs(_ html: String) -> [(String, InlinePresentationIntent?, URL?)] {
        HTMLText.attributed(html).runs.map { run in
            (String(HTMLText.attributed(html)[run.range].characters), run.inlinePresentationIntent, run.link)
        }
    }

    @Test("bold, italic, code and strikethrough become styles; the text has no tags")
    func styles() {
        #expect(String(HTMLText.attributed("a <b>b</b> <i>i</i> <code>c</code> <del>d</del>").characters) == "a b i c d")
        let bold = runs("<strong>x</strong>").first
        #expect(bold?.1 == .stronglyEmphasized)
        #expect(runs("<b><i>x</i></b>").first?.1 == [.stronglyEmphasized, .emphasized])
        #expect(runs("<code>x</code>").first?.1 == .code)
        #expect(HTMLText.attributed("<code>x</code>").runs.first?.font != nil)
        #expect(HTMLText.attributed("x").runs.first?.font == nil)
        #expect(runs("<s>x</s>").first?.1 == .strikethrough)
    }

    @Test("links keep only safe schemes")
    func links() {
        #expect(runs(#"<a href="https://example.org/a?b=1&amp;c=2">site</a>"#).first?.2 == URL(string: "https://example.org/a?b=1&c=2"))
        #expect(runs(#"<a href="matrix:r/room:x.org">room</a>"#).first?.2 != nil)
        #expect(runs(#"<a href="javascript:alert(1)">bad</a>"#).first?.2 == nil)
        #expect(String(HTMLText.attributed(#"<a href="javascript:alert(1)">bad</a>"#).characters) == "bad")
        #expect(runs(#"<a href="file:///etc/passwd">bad</a>"#).first?.2 == nil)
    }

    @Test("blocks, breaks and lists become line breaks and bullets; unknown tags keep their text; entities decode")
    func structure() {
        #expect(String(HTMLText.attributed("one<br>two<br/>three").characters) == "one\ntwo\nthree")
        #expect(String(HTMLText.attributed("<p>a</p><p>b</p>").characters) == "a\nb")
        #expect(String(HTMLText.attributed("<ul><li>x</li><li>y</li></ul>").characters) == "• x\n• y")
        #expect(String(HTMLText.attributed("<ol><li>x</li><li>y</li></ol>").characters) == "1. x\n2. y")
        #expect(String(HTMLText.attributed("<font color=\"#f00\">red</font> <script>alert(1)</script>").characters) == "red alert(1)")
        #expect(String(HTMLText.attributed("1 &lt; 2 &amp;&amp; 3 &gt; 2").characters) == "1 < 2 && 3 > 2")
        #expect(String(HTMLText.attributed("a < b").characters) == "a < b")
    }

    @Test("the quoted part of a reply (mx-reply) is dropped")
    func replyFallback() {
        #expect(String(HTMLText.attributed("<mx-reply><blockquote>old</blockquote></mx-reply>answer").characters) == "answer")
    }

    @Test("decimal and hex numeric entities decode in a single pass without double-unescaping or crashing on bad codes")
    func numericEntities() {
        #expect(String(HTMLText.attributed("don&#x27;t &amp;#x27; &#8217; &#x1F44D; &#128077;").characters) == "don't &#x27; \u{2019} 👍 👍")
        #expect(String(HTMLText.attributed("&amp;lt; &amp;amp; a & b &lt; c").characters) == "&lt; &amp; a & b < c")
        // Invalid, NUL, surrogate and out-of-range code points stay literal text.
        #expect(String(HTMLText.attributed("&#0; &#xD800; &#x9999999; &#xZZ; &#; &unknown;").characters) == "&#0; &#xD800; &#x9999999; &#xZZ; &#; &unknown;")
    }
}
