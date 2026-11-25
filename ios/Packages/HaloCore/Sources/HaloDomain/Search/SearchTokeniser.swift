import Foundation

/// Splits text into the words message search works with (MESSAGE_SEARCH FR-5, FR-6). The index, the query and the highlighting all use
/// this one tokeniser: text is NFKC-normalised, lowercased and stripped of Latin diacritics; every CJK character is a word of its own,
/// so a query of several becomes a phrase; any other run of letters, digits and marks is a word matched by its beginning.
public enum SearchTokeniser {
    public struct Token: Sendable, Equatable {
        public let text: String
        public let isCJK: Bool
        /// Something other than a letter, digit or mark stood between this word and the one before.
        public let followsGap: Bool
    }

    /// What one part of a query asks for.
    public enum Term: Sendable, Equatable {
        /// A word that begins with this.
        case prefix(String)
        /// These CJK characters, next to each other and in this order.
        case phrase([String])
    }

    /// Longer queries are cut: nobody types them, and each term costs an index lookup.
    public static let maximumQueryCharacters = 256
    public static let maximumTerms = 16

    // MARK: Index and query

    /// The words of `text`, as the index stores them.
    public static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var word = ""
        var gap = false
        func flush() {
            guard !word.isEmpty else { return }
            result.append(Token(text: word, isCJK: false, followsGap: gap))
            word = ""
            gap = false
        }
        for scalar in fold(text).unicodeScalars {
            switch kind(scalar) {
            case .word: word.unicodeScalars.append(scalar)
            case .cjk:
                flush()
                result.append(Token(text: String(scalar), isCJK: true, followsGap: gap))
                gap = false
            case .separator:
                flush()
                gap = true
            }
        }
        flush()
        return result
    }

    /// What goes into the full-text column: the words of every part, separated by spaces.
    public static func indexText(_ parts: [String]) -> String {
        parts.flatMap { tokens($0) }.map(\.text).joined(separator: " ")
    }

    /// The parts of a query; empty when it holds nothing to search for (blank, punctuation only).
    public static func terms(_ query: String) -> [Term] {
        var result: [Term] = []
        var phrase: [String] = []
        func flush() {
            if !phrase.isEmpty { result.append(.phrase(phrase)) }
            phrase = []
        }
        for token in tokens(String(query.prefix(maximumQueryCharacters))) {
            if token.isCJK {
                if token.followsGap { flush() }
                phrase.append(token.text)
            } else {
                flush()
                result.append(.prefix(token.text))
            }
        }
        flush()
        return Array(result.prefix(maximumTerms))
    }

    /// The FTS5 expression for a query, or `nil` when there is nothing to search for. Every word is quoted, so nothing the person
    /// types is ever read as FTS5 syntax.
    public static func matchExpression(_ query: String) -> String? {
        let terms = terms(query)
        guard !terms.isEmpty else { return nil }
        return terms.map { term in
            switch term {
            case .prefix(let word): quoted(word) + "*"
            case .phrase(let words): quoted(words.joined(separator: " "))
            }
        }.joined(separator: " ")
    }

    private static func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    // MARK: Showing a hit

    /// The parts of `text` that `query` matches, in order and without overlaps.
    public static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        let terms = terms(query)
        guard !terms.isEmpty else { return [] }
        let words = positioned(text)
        var ranges: [Range<String.Index>] = []
        for term in terms {
            switch term {
            case .prefix(let prefix):
                let wanted = Array(prefix.unicodeScalars)
                for word in words where !word.isCJK && word.scalars.count >= wanted.count && Array(word.scalars.prefix(wanted.count)) == wanted {
                    ranges.append(word.ranges[0].lowerBound..<word.ranges[wanted.count - 1].upperBound)
                }
            case .phrase(let phrase):
                guard words.count >= phrase.count else { continue }
                for start in 0...(words.count - phrase.count) {
                    let slice = words[start..<(start + phrase.count)]
                    guard zip(slice, phrase).allSatisfy({ String(String.UnicodeScalarView($0.scalars)) == $1 }), let first = slice.first, let last = slice.last else { continue }
                    ranges.append(first.ranges[0].lowerBound..<last.ranges[last.ranges.count - 1].upperBound)
                }
            }
        }
        return merged(ranges)
    }

    /// The part of a long text around its first match, on one line; the whole text when it is short or nothing in it matches.
    public static func snippet(of text: String, query: String, length: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > length, let first = highlights(in: flat, query: query).first else { return String(flat.prefix(length)) + (flat.count > length ? "…" : "") }
        let lead = length / 4
        let distance = flat.distance(from: flat.startIndex, to: first.lowerBound)
        guard distance > lead else { return String(flat.prefix(length)) + "…" }
        let start = flat.index(first.lowerBound, offsetBy: -lead)
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return "…" + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    private struct Positioned {
        var scalars: [Unicode.Scalar]
        var ranges: [Range<String.Index>]
        let isCJK: Bool
    }

    private static func positioned(_ text: String) -> [Positioned] {
        var words: [Positioned] = []
        var open = false
        for index in text.indices {
            let range = index..<text.index(after: index)
            for scalar in fold(String(text[index])).unicodeScalars {
                switch kind(scalar) {
                case .word:
                    if open {
                        words[words.count - 1].scalars.append(scalar)
                        words[words.count - 1].ranges.append(range)
                    } else {
                        words.append(Positioned(scalars: [scalar], ranges: [range], isCJK: false))
                        open = true
                    }
                case .cjk:
                    words.append(Positioned(scalars: [scalar], ranges: [range], isCJK: true))
                    open = false
                case .separator: open = false
                }
            }
        }
        return words
    }

    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Characters

    /// Compatibility forms unified (full-width Latin, half-width kana), lowercased, Latin diacritics removed. Japanese voicing marks and
    /// Thai or Indic vowel signs stay: they make different letters.
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        let unified = text.precomposedStringWithCompatibilityMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in unified.decomposedStringWithCanonicalMapping.unicodeScalars where !(0x300...0x36F).contains(scalar.value) { scalars.append(scalar) }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    private enum Kind { case word, cjk, separator }

    private static func kind(_ scalar: Unicode.Scalar) -> Kind {
        switch scalar.value {
        case 0x30...0x39, 0x61...0x7A: return .word
        case 0..<0x80: return .separator
        case 0x3005...0x3007, 0x3041...0x3096, 0x3099...0x309A, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0x20000...0x3FFFD: return .cjk
        default: break
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark: return .word
        default: return .separator
        }
    }
}
