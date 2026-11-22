import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("MentionFormatter")
struct MentionFormatterTests {
    private let alice = Mention(user: try! UserID("@alice:x.org"), name: "Alice")
    private let aliceB = Mention(user: try! UserID("@aliceb:x.org"), name: "Alice B")

    @Test("a mention becomes a matrix.to link and its user is listed once")
    func link() {
        let result = MentionFormatter.apply("hi @Alice and again @Alice!", mentions: [alice])
        #expect(result.markdown == "hi [@Alice](https://matrix.to/#/@alice:x.org) and again [@Alice](https://matrix.to/#/@alice:x.org)!")
        #expect(result.users == [alice.user])
    }

    @Test("the longest matching name wins, and a name followed by a letter is not a mention")
    func matching() {
        let result = MentionFormatter.apply("@Alice B, @Alicex", mentions: [alice, aliceB])
        #expect(result.users == [aliceB.user])
        #expect(result.markdown == "[@Alice B](https://matrix.to/#/@aliceb:x.org), @Alicex")
    }

    @Test("a mention whose text was deleted is dropped; text without mentions is untouched")
    func dropped() {
        #expect(MentionFormatter.apply("hello", mentions: [alice]) == .init(markdown: "hello", users: []))
        #expect(MentionFormatter.apply("a @ b @", mentions: []) == .init(markdown: "a @ b @", users: []))
    }

    @Test("brackets in a name are escaped so they can't break the link")
    func escaping() {
        let odd = Mention(user: try! UserID("@x:x.org"), name: "A]b")
        #expect(MentionFormatter.apply("@A]b", mentions: [odd]).markdown == "[@A\\]b](https://matrix.to/#/@x:x.org)")
    }

    @Test("a hostile display name can't inject HTML, emphasis or a link into the formatted body")
    func hostileNames() throws {
        let evil = Mention(user: try UserID("@e:x.org"), name: "x</a><a href=\"https://phish\">*hi*")
        let markdown = MentionFormatter.apply("@\(evil.name) ok", mentions: [evil]).markdown
        #expect(markdown == #"[@x\<\/a\>\<a href\=\"https\:\/\/phish\"\>\*hi\*](https://matrix.to/#/@e:x.org) ok"#)
        #expect(MentionFormatter.escape("Zoë_🙂 (B)") == #"Zoë\_🙂 \(B\)"#)
    }

    @Test("matrixToURL builds a valid permalink and percent-encodes unusual user IDs")
    func matrixToURL() throws {
        #expect(MentionFormatter.matrixToURL(for: alice.user)?.absoluteString == "https://matrix.to/#/@alice:x.org")
        let historical = try UserID("@a(b):x.org")
        #expect(MentionFormatter.matrixToURL(for: historical)?.absoluteString == "https://matrix.to/#/@a%28b%29:x.org")
    }
}
