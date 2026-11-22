import Foundation

/// Pure Unicode emoji detection, extraction, and searchable native emoji catalog.
public enum NativeEmoji: Sendable {
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case smileys = "Smileys"
        case gestures = "Gestures"
        case symbols = "Hearts & Symbols"
        case celebration = "Food & Celebration"
        case nature = "Nature & Travel"

        public var id: String { rawValue }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let emoji: String
        public let shortcode: String
        public let keywords: [String]
        public let category: Category

        public var id: String { emoji }

        public init(emoji: String, shortcode: String, keywords: [String] = [], category: Category) {
            self.emoji = emoji
            self.shortcode = shortcode
            self.keywords = keywords
            self.category = category
        }
    }

    /// Returns `true` when `character` is a rendered Unicode emoji (including ZWJ sequences,
    /// skin-tone modifiers, flags, keycap sequences, and text-default emoji with `U+FE0F`),
    /// while rejecting plain ASCII digits and punctuation (`0-9`, `#`, `*`).
    public static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        // Keycap sequences: [0-9#*] + optional FE0F + U+20E3 (combining enclosing keycap).
        if scalars.contains(where: { $0.value == 0x20E3 }) {
            return first.properties.isEmoji
        }
        // Regional indicator pairs (flags): two scalars in 0x1F1E6...0x1F1FF.
        if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            return true
        }
        // Explicit emoji presentation selector (U+FE0F) promotes a text-default emoji scalar.
        if scalars.contains(where: { $0.value == 0xFE0F }) {
            return scalars.contains(where: { $0.properties.isEmoji })
        }
        // ZWJ sequence (e.g. family, professions).
        if scalars.contains(where: { $0.value == 0x200D }) {
            return scalars.contains(where: { $0.properties.isEmoji })
        }
        // Standard emoji with default emoji presentation (excludes plain digits, '#', '*', '©', '™').
        return first.properties.isEmojiPresentation
    }

    /// Returns `true` when `text` contains between 1 and `maxCount` emoji characters and no other
    /// non-whitespace characters (used for jumbo emoji-only message rendering).
    public static func isEmojiOnly(_ text: String, maxCount: Int = 3) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxCount > 0 else { return false }
        var count = 0
        for ch in trimmed {
            if ch.isWhitespace { continue }
            guard isEmoji(ch) else { return false }
            count += 1
            if count > maxCount { return false }
        }
        return count > 0
    }

    /// Extracts the first Unicode emoji grapheme cluster from `text`, or `nil` if none is present.
    public static func firstEmoji(in text: String) -> String? {
        for ch in text where isEmoji(ch) {
            return String(ch)
        }
        return nil
    }

    /// Searches the native emoji catalog by shortcode or keyword (empty query returns the full catalog).
    public static func search(_ query: String, limit: Int? = nil) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches: [Entry]
        if needle.isEmpty {
            matches = catalog
        } else {
            matches = catalog.filter { entry in
                entry.emoji == needle
                    || entry.shortcode.contains(needle)
                    || entry.keywords.contains { $0.contains(needle) }
            }
        }
        if let limit { return Array(matches.prefix(limit)) }
        return matches
    }

    /// Returns trailing `:shortcode` autocomplete suggestions for a composer draft (requires at least
    /// two query characters after `:`, preceded by start-of-string or whitespace).
    public static func shortcodeSuggestions(forDraft draft: String, limit: Int = 6) -> (range: Range<String.Index>, entries: [Entry])? {
        guard let colon = draft.lastIndex(of: ":") else { return nil }
        if colon != draft.startIndex {
            let before = draft[draft.index(before: colon)]
            guard before.isWhitespace else { return nil }
        }
        let queryStart = draft.index(after: colon)
        let query = String(draft[queryStart...])
        guard query.count >= 2, query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let hits = search(query, limit: limit)
        guard !hits.isEmpty else { return nil }
        return (colon..<draft.endIndex, hits)
    }

    public static let catalog: [Entry] = [
        // Smileys
        Entry(emoji: "😀", shortcode: "grinning", keywords: ["smile", "happy"], category: .smileys),
        Entry(emoji: "😃", shortcode: "smiley", keywords: ["smile", "happy"], category: .smileys),
        Entry(emoji: "😄", shortcode: "smile", keywords: ["happy", "joy"], category: .smileys),
        Entry(emoji: "😁", shortcode: "grin", keywords: ["happy", "teeth"], category: .smileys),
        Entry(emoji: "😅", shortcode: "sweat_smile", keywords: ["relief", "whew"], category: .smileys),
        Entry(emoji: "😂", shortcode: "joy", keywords: ["laugh", "lol", "haha", "tears"], category: .smileys),
        Entry(emoji: "🤣", shortcode: "rofl", keywords: ["laugh", "lol", "haha"], category: .smileys),
        Entry(emoji: "😊", shortcode: "blush", keywords: ["smile", "warm"], category: .smileys),
        Entry(emoji: "😇", shortcode: "innocent", keywords: ["angel", "halo"], category: .smileys),
        Entry(emoji: "😉", shortcode: "wink", keywords: ["flirt"], category: .smileys),
        Entry(emoji: "😍", shortcode: "heart_eyes", keywords: ["love", "crush"], category: .smileys),
        Entry(emoji: "🥰", shortcode: "smiling_face_with_hearts", keywords: ["love", "adore"], category: .smileys),
        Entry(emoji: "😘", shortcode: "kissing_heart", keywords: ["kiss", "love"], category: .smileys),
        Entry(emoji: "😎", shortcode: "sunglasses", keywords: ["cool"], category: .smileys),
        Entry(emoji: "🥳", shortcode: "partying_face", keywords: ["party", "celebrate"], category: .smileys),
        Entry(emoji: "🤔", shortcode: "thinking", keywords: ["hmm", "wonder"], category: .smileys),
        Entry(emoji: "🫡", shortcode: "saluting_face", keywords: ["salute", "yes", "sir"], category: .smileys),
        Entry(emoji: "😮", shortcode: "open_mouth", keywords: ["wow", "surprised"], category: .smileys),
        Entry(emoji: "🤯", shortcode: "exploding_head", keywords: ["mindblown", "wow"], category: .smileys),
        Entry(emoji: "😬", shortcode: "grimacing", keywords: ["awkward", "yikes"], category: .smileys),
        Entry(emoji: "🙄", shortcode: "rolling_eyes", keywords: ["eyeroll", "whatever"], category: .smileys),
        Entry(emoji: "😴", shortcode: "sleeping", keywords: ["sleep", "tired", "zzz"], category: .smileys),
        Entry(emoji: "🤗", shortcode: "hugging", keywords: ["hug"], category: .smileys),
        Entry(emoji: "😢", shortcode: "cry", keywords: ["sad", "tear"], category: .smileys),
        Entry(emoji: "😭", shortcode: "sob", keywords: ["cry", "sad"], category: .smileys),
        Entry(emoji: "😡", shortcode: "rage", keywords: ["angry", "mad"], category: .smileys),
        Entry(emoji: "🥹", shortcode: "holding_back_tears", keywords: ["touched", "aw"], category: .smileys),
        Entry(emoji: "🫠", shortcode: "melting_face", keywords: ["melt", "awkward"], category: .smileys),

        // Gestures
        Entry(emoji: "👍", shortcode: "thumbsup", keywords: ["+1", "ok", "yes", "like"], category: .gestures),
        Entry(emoji: "👎", shortcode: "thumbsdown", keywords: ["-1", "no", "dislike"], category: .gestures),
        Entry(emoji: "👏", shortcode: "clap", keywords: ["applause", "bravo"], category: .gestures),
        Entry(emoji: "🙌", shortcode: "raised_hands", keywords: ["hooray", "yay"], category: .gestures),
        Entry(emoji: "🙏", shortcode: "pray", keywords: ["thanks", "please", "thankyou"], category: .gestures),
        Entry(emoji: "🤝", shortcode: "handshake", keywords: ["deal", "agree"], category: .gestures),
        Entry(emoji: "💪", shortcode: "muscle", keywords: ["strong", "flex"], category: .gestures),
        Entry(emoji: "👋", shortcode: "wave", keywords: ["hello", "hi", "bye"], category: .gestures),
        Entry(emoji: "✌️", shortcode: "v", keywords: ["peace", "victory"], category: .gestures),
        Entry(emoji: "👌", shortcode: "ok_hand", keywords: ["ok", "perfect"], category: .gestures),
        Entry(emoji: "🤞", shortcode: "crossed_fingers", keywords: ["luck", "hope"], category: .gestures),
        Entry(emoji: "🫶", shortcode: "heart_hands", keywords: ["love", "thanks"], category: .gestures),
        Entry(emoji: "👀", shortcode: "eyes", keywords: ["look", "watching", "see"], category: .gestures),

        // Hearts & Symbols
        Entry(emoji: "❤️", shortcode: "heart", keywords: ["love", "red"], category: .symbols),
        Entry(emoji: "🧡", shortcode: "orange_heart", keywords: ["love"], category: .symbols),
        Entry(emoji: "💛", shortcode: "yellow_heart", keywords: ["love"], category: .symbols),
        Entry(emoji: "💚", shortcode: "green_heart", keywords: ["love"], category: .symbols),
        Entry(emoji: "💙", shortcode: "blue_heart", keywords: ["love"], category: .symbols),
        Entry(emoji: "💜", shortcode: "purple_heart", keywords: ["love"], category: .symbols),
        Entry(emoji: "💔", shortcode: "broken_heart", keywords: ["sad", "heartbreak"], category: .symbols),
        Entry(emoji: "🔥", shortcode: "fire", keywords: ["lit", "hot", "flame"], category: .symbols),
        Entry(emoji: "💯", shortcode: "100", keywords: ["perfect", "agree"], category: .symbols),
        Entry(emoji: "✅", shortcode: "white_check_mark", keywords: ["check", "done", "yes"], category: .symbols),
        Entry(emoji: "❌", shortcode: "x", keywords: ["no", "cancel", "cross"], category: .symbols),
        Entry(emoji: "⭐️", shortcode: "star", keywords: ["favourite", "favorite"], category: .symbols),
        Entry(emoji: "✨", shortcode: "sparkles", keywords: ["magic", "shine", "clean"], category: .symbols),
        Entry(emoji: "💡", shortcode: "bulb", keywords: ["idea", "light"], category: .symbols),
        Entry(emoji: "❓", shortcode: "question", keywords: ["what", "help"], category: .symbols),
        Entry(emoji: "❗️", shortcode: "exclamation", keywords: ["important", "alert"], category: .symbols),

        // Food & Celebration
        Entry(emoji: "🎉", shortcode: "tada", keywords: ["party", "congrats", "celebrate"], category: .celebration),
        Entry(emoji: "🎊", shortcode: "confetti_ball", keywords: ["party", "celebrate"], category: .celebration),
        Entry(emoji: "🎁", shortcode: "gift", keywords: ["present", "birthday"], category: .celebration),
        Entry(emoji: "🎂", shortcode: "birthday", keywords: ["cake", "party"], category: .celebration),
        Entry(emoji: "☕️", shortcode: "coffee", keywords: ["tea", "cafe", "morning"], category: .celebration),
        Entry(emoji: "🍕", shortcode: "pizza", keywords: ["food", "lunch", "dinner"], category: .celebration),
        Entry(emoji: "🍔", shortcode: "burger", keywords: ["food"], category: .celebration),
        Entry(emoji: "🍻", shortcode: "beers", keywords: ["cheers", "drinks"], category: .celebration),
        Entry(emoji: "🥂", shortcode: "champagne_glass", keywords: ["cheers", "toast"], category: .celebration),
        Entry(emoji: "🏆", shortcode: "trophy", keywords: ["win", "winner", "award"], category: .celebration),

        // Nature & Travel
        Entry(emoji: "🚀", shortcode: "rocket", keywords: ["launch", "ship", "fast"], category: .nature),
        Entry(emoji: "🌈", shortcode: "rainbow", keywords: ["pride", "colors"], category: .nature),
        Entry(emoji: "☀️", shortcode: "sunny", keywords: ["sun", "weather"], category: .nature),
        Entry(emoji: "🌙", shortcode: "moon", keywords: ["night", "sleep"], category: .nature),
        Entry(emoji: "🌸", shortcode: "cherry_blossom", keywords: ["flower", "spring"], category: .nature),
        Entry(emoji: "🐶", shortcode: "dog", keywords: ["puppy", "pet"], category: .nature),
        Entry(emoji: "🐱", shortcode: "cat", keywords: ["kitty", "pet"], category: .nature),
        Entry(emoji: "🌍", shortcode: "earth", keywords: ["world", "globe"], category: .nature),
    ]
}
