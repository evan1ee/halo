import HaloDomain
import Testing

@Suite("NativeEmoji")
struct NativeEmojiTests {
    @Test("isEmojiOnly matches 1–3 Unicode emoji (incl. skin tones, ZWJ, flags, variation selectors) and rejects plain text/digits")
    func jumboDetection() {
        #expect(NativeEmoji.isEmojiOnly("👍"))
        #expect(NativeEmoji.isEmojiOnly("👍🏽"))
        #expect(NativeEmoji.isEmojiOnly("❤️"))
        #expect(NativeEmoji.isEmojiOnly("😂 🔥 🎉"))
        #expect(NativeEmoji.isEmojiOnly("🇺🇸"))
        #expect(NativeEmoji.isEmojiOnly("👨‍👩‍👧‍👦"))
        #expect(NativeEmoji.isEmojiOnly("1️⃣"))

        #expect(!NativeEmoji.isEmojiOnly(""))
        #expect(!NativeEmoji.isEmojiOnly("   "))
        #expect(!NativeEmoji.isEmojiOnly("123"))
        #expect(!NativeEmoji.isEmojiOnly("#"))
        #expect(!NativeEmoji.isEmojiOnly("*"))
        #expect(!NativeEmoji.isEmojiOnly("hello 👍"))
        #expect(!NativeEmoji.isEmojiOnly("👍 👍 👍 👍"))
    }

    @Test("firstEmoji extracts the first native emoji from mixed text")
    func extractFirst() {
        #expect(NativeEmoji.firstEmoji(in: "👍🏽") == "👍🏽")
        #expect(NativeEmoji.firstEmoji(in: "hi 🚀 world") == "🚀")
        #expect(NativeEmoji.firstEmoji(in: "plain text 123") == nil)
    }

    @Test("shortcodeSuggestions matches trailing :query and ignores mid-word colons")
    func shortcodeAutocomplete() {
        let hit = NativeEmoji.shortcodeSuggestions(forDraft: "ship it :rock")
        #expect(hit?.entries.first?.emoji == "🚀")
        #expect(NativeEmoji.shortcodeSuggestions(forDraft: "https://example.com") == nil)
        #expect(NativeEmoji.shortcodeSuggestions(forDraft: ":a") == nil)
    }
}
