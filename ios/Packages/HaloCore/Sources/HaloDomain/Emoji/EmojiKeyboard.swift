import Foundation

/// The full emoji set shown by the composer's emoji panel (docs/features/COMPOSER_PANELS.md §4, D97).
///
/// Derived from Unicode properties instead of a hand-kept list, so the panel offers every emoji the runtime knows:
/// each section is a list of code-point ranges, and only scalars with default emoji presentation are kept (unassigned
/// and text-default code points drop out). An emoji belongs to the first section that lists it. Flags are built from
/// ISO 3166 region codes. Search matches the curated `NativeEmoji` shortcodes first, then the Unicode scalar names.
public enum EmojiKeyboard: Sendable {
    public enum Section: String, CaseIterable, Sendable, Identifiable {
        case smileys = "Smileys & People"
        case nature = "Animals & Nature"
        case food = "Food & Drink"
        case activity = "Activity"
        case travel = "Travel & Places"
        case objects = "Objects"
        case symbols = "Symbols"
        case flags = "Flags"

        public var id: String { rawValue }
    }

    /// The emoji of `section`, in code-point order (flags in region-code order).
    public static func emoji(in section: Section) -> [String] { table[section] ?? [] }

    /// Every emoji of every section, in section order.
    public static var all: [String] { Section.allCases.flatMap { emoji(in: $0) } }

    /// The section `emoji` is listed in, or `nil` when it isn't part of the set (for example a skin-tone variant).
    public static func section(of emoji: String) -> Section? { sectionByEmoji[emoji] }

    /// Emoji matching `query`: curated shortcodes and keywords first, then Unicode names (each word of the query must
    /// start a word of the name). Blank queries match nothing.
    public static func search(_ query: String, limit: Int = 120) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var hits: [String] = []
        func add(_ emoji: String) {
            guard hits.count < limit, seen.insert(emoji).inserted else { return }
            hits.append(emoji)
        }
        if let direct = NativeEmoji.firstEmoji(in: needle) { add(direct) }
        for entry in NativeEmoji.search(needle) { add(entry.emoji) }
        let words = needle.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).map(String.init)
        for (emoji, name) in names where hits.count < limit {
            let nameWords = name.split(separator: " ")
            if words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { add(emoji) }
        }
        return hits
    }

    /// A readable name for VoiceOver and search, from the curated shortcode or the Unicode name ("grinning face").
    public static func name(of emoji: String) -> String? {
        if let entry = NativeEmoji.catalog.first(where: { $0.emoji == emoji }) { return entry.shortcode.replacingOccurrences(of: "_", with: " ") }
        return names.first { $0.emoji == emoji }?.name
    }

    // MARK: - Tables

    private static let ranges: [(Section, [ClosedRange<UInt32>])] = [
        (.smileys, [
            0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9DF, 0x1FAE0...0x1FAEF,
            0x1F466...0x1F487, 0x1F44A...0x1F450, 0x1F440...0x1F445, 0x1F48B...0x1F48F, 0x1F930...0x1F93E,
            0x1F918...0x1F91F, 0x1F9B0...0x1F9B9, 0x1F9CD...0x1F9CF, 0x1FAF0...0x1FAF8, 0x1F6B4...0x1F6B6,
            0x1F574...0x1F57A, 0x1F590...0x1F596, 0x270A...0x270B, 0x1F9E0...0x1F9E0, 0x1FAC0...0x1FAC5,
        ]),
        (.nature, [
            0x1F400...0x1F43F, 0x1F980...0x1F9AF, 0x1F330...0x1F344, 0x1F490...0x1F490, 0x1F4AE...0x1F4AE,
            0x1F331...0x1F33F, 0x1F98A...0x1F9AE, 0x1FAB0...0x1FABF, 0x1F30D...0x1F32F,
            0x2600...0x2604, 0x2614...0x2615, 0x26A1...0x26A1, 0x26C4...0x26C8,
        ]),
        (.food, [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF]),
        (.activity, [
            0x1F380...0x1F393, 0x1F3A0...0x1F3CF, 0x1F93A...0x1F94F, 0x1F3F8...0x1F3FA, 0x1F6F7...0x1F6F9,
            0x1FA80...0x1FA8F, 0x1F9E9...0x1F9F8, 0x1FA70...0x1FA7C, 0x26BD...0x26BE, 0x26F3...0x26F3, 0x26F8...0x26F9,
        ]),
        (.travel, [0x1F680...0x1F6FF, 0x1F3D4...0x1F3F7, 0x1F5FA...0x1F5FF, 0x1F3E0...0x1F3F0, 0x1F6E0...0x1F6FC, 0x26EA...0x26FD]),
        (.objects, [
            0x1F4A0...0x1F4FF, 0x1F500...0x1F53D, 0x1F54A...0x1F573, 0x1F57B...0x1F5F9, 0x1F97B...0x1F97F,
            0x1F9E0...0x1F9FF, 0x1FA90...0x1FAAF, 0x231A...0x23FF, 0x2700...0x27BF,
        ]),
        (.symbols, [
            0x1F300...0x1F32F, 0x1F7E0...0x1F7F0, 0x1F170...0x1F251, 0x2190...0x21FF, 0x2B00...0x2BFF,
            0x3030...0x303D, 0x1F004...0x1F0CF, 0x2600...0x26FF,
        ]),
    ]

    /// ISO 3166-1 alpha-2 codes of the region flags.
    private static let regionCodes = """
        AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF \
        CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET EU FI FJ FK FM FO FR GA GB GD GE GF GG GH \
        GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW \
        KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG \
        NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN \
        SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM UN US UY UZ VA VC VE VG VI VN VU WF WS XK \
        YE YT ZA ZM ZW
        """

    static func flag(_ code: Substring) -> String? {
        var scalars = String.UnicodeScalarView()
        for letter in code.unicodeScalars {
            guard ("A"..."Z").contains(letter), let indicator = Unicode.Scalar(0x1F1E6 + letter.value - 65) else { return nil }
            scalars.append(indicator)
        }
        return scalars.count == 2 ? String(scalars) : nil
    }

    private static let table: [Section: [String]] = {
        var seen = Set<UInt32>()
        var result: [Section: [String]] = [:]
        for (section, list) in ranges {
            var items: [String] = []
            for range in list {
                for value in range where !seen.contains(value) {
                    guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { continue }
                    seen.insert(value)
                    items.append(String(scalar))
                }
            }
            result[section, default: []].append(contentsOf: items)
        }
        result[.flags] = regionCodes.split(whereSeparator: \.isWhitespace).compactMap(flag)
        return result
    }()

    private static let sectionByEmoji: [String: Section] = {
        var map: [String: Section] = [:]
        for section in Section.allCases { for emoji in table[section] ?? [] where map[emoji] == nil { map[emoji] = section } }
        return map
    }()

    /// Lower-cased Unicode names, in panel order; flags are named after their region code.
    private static let names: [(emoji: String, name: String)] = Section.allCases.flatMap { section in
        (table[section] ?? []).compactMap { emoji -> (emoji: String, name: String)? in
            if section == .flags {
                let code = String(String.UnicodeScalarView(emoji.unicodeScalars.compactMap { Unicode.Scalar($0.value - 0x1F1E6 + 65) }))
                return (emoji, "flag \(code.lowercased())")
            }
            guard let name = emoji.unicodeScalars.first?.properties.name else { return nil }
            return (emoji, name.lowercased())
        }
    }
}
