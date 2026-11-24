import Testing
@testable import HaloDomain

@Suite("EmojiKeyboard")
struct EmojiKeyboardTests {
    @Test("every section has emoji, and a full keyboard's worth in total")
    func sections() {
        for section in EmojiKeyboard.Section.allCases { #expect(!EmojiKeyboard.emoji(in: section).isEmpty, "\(section)") }
        #expect(EmojiKeyboard.all.count > 900)
    }

    @Test("well-known emoji land in the expected section")
    func placement() {
        #expect(EmojiKeyboard.section(of: "😀") == .smileys)
        #expect(EmojiKeyboard.section(of: "👍") == .smileys)
        #expect(EmojiKeyboard.section(of: "🐶") == .nature)
        #expect(EmojiKeyboard.section(of: "🍕") == .food)
        #expect(EmojiKeyboard.section(of: "⚽") == .activity)
        #expect(EmojiKeyboard.section(of: "🚀") == .travel)
        #expect(EmojiKeyboard.section(of: "💡") == .objects)
        #expect(EmojiKeyboard.section(of: "🇩🇪") == .flags)
    }

    @Test("no emoji is listed twice, and digits or text-default symbols are not emoji keys")
    func uniqueAndPresentational() {
        let all = EmojiKeyboard.all
        #expect(Set(all).count == all.count)
        #expect(!all.contains("1") && !all.contains("©"))
        #expect(all.allSatisfy { $0.count == 1 })
    }

    @Test("flags are built from region codes; invalid codes give nothing")
    func flags() {
        #expect(EmojiKeyboard.flag("JP") == "🇯🇵")
        #expect(EmojiKeyboard.flag("j1") == nil)
    }

    @Test("search matches curated shortcodes first, then word prefixes of Unicode names")
    func search() {
        let hearts = EmojiKeyboard.search("heart")
        #expect(hearts.prefix(5).contains("❤️"))
        #expect(EmojiKeyboard.search("pizza") == ["🍕"])
        #expect(EmojiKeyboard.search("grin fa").contains("😀"))
        #expect(EmojiKeyboard.search("flag jp").contains("🇯🇵"))
        #expect(EmojiKeyboard.search("   ").isEmpty)
        #expect(EmojiKeyboard.search("face", limit: 5).count == 5)
    }

    @Test("names come from the curated shortcode or Unicode")
    func names() {
        #expect(EmojiKeyboard.name(of: "🚀") == "rocket")
        #expect(EmojiKeyboard.name(of: "x") == nil)
    }
}
