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

    /// A single-line excerpt around the first match and the character-offset ranges to highlight within it.
    public struct Snippet: Sendable, Equatable {
        public let text: String
        public let highlights: [Range<Int>]

        public init(text: String, highlights: [Range<Int>]) {
            self.text = text
            self.highlights = highlights
        }
    }

    private enum CompiledTerm {
        case prefix([Unicode.Scalar])
        case phrase([Unicode.Scalar])
    }

    private static func compile(_ terms: [Term]) -> [CompiledTerm] {
        terms.compactMap { term in
            switch term {
            case .prefix(let word):
                let scalars = Array(word.unicodeScalars)
                return scalars.isEmpty ? nil : .prefix(scalars)
            case .phrase(let words):
                let scalars = words.compactMap { $0.unicodeScalars.first }
                return scalars.count == words.count && !scalars.isEmpty ? .phrase(scalars) : nil
            }
        }
    }

    /// Computes both the single-line snippet and its highlight character offsets without redundant tokenisation passes.
    public static func preview(of text: String, query: String, length: Int = 160) -> Snippet {
        preview(of: text, terms: terms(query), length: length)
    }

    /// Computes both the single-line snippet and its highlight character offsets for pre-parsed `terms`.
    public static func preview(of text: String, terms: [Term], length: Int = 160) -> Snippet {
        let flat = flattenNewlines(text)
        let compiled = compile(terms)
        guard !compiled.isEmpty else {
            let clipped = flat.count > length ? String(flat.prefix(length)) + "…" : flat
            return Snippet(text: clipped, highlights: [])
        }
        if flat.count <= length {
            let words = positioned(flat)
            return Snippet(text: flat, highlights: highlightOffsets(in: words, compiled: compiled))
        }
        let lead = length / 4
        guard let first = firstMatch(in: flat, compiled: compiled) else {
            return Snippet(text: String(flat.prefix(length)) + "…", highlights: [])
        }
        guard first.charOffset > lead else {
            let clipped = String(flat.prefix(length)) + "…"
            return Snippet(text: clipped, highlights: highlightOffsets(in: positioned(clipped), compiled: compiled))
        }
        let start = flat.index(first.index, offsetBy: -lead)
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        let window = "…" + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        return Snippet(text: window, highlights: highlightOffsets(in: positioned(window), compiled: compiled))
    }

    /// The parts of `text` that `query` matches, in order and without overlaps.
    public static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        let compiled = compile(terms(query))
        guard !compiled.isEmpty else { return [] }
        let words = positioned(text)
        var ranges: [Range<String.Index>] = []
        for term in compiled {
            switch term {
            case .prefix(let wanted):
                for word in words where !word.isCJK && word.scalars.count >= wanted.count && word.scalars.starts(with: wanted) {
                    ranges.append(word.ranges[0].lowerBound..<word.ranges[wanted.count - 1].upperBound)
                }
            case .phrase(let wanted):
                guard words.count >= wanted.count else { continue }
                for start in 0...(words.count - wanted.count) {
                    guard matchesPhrase(words, start: start, wanted: wanted) else { continue }
                    let first = words[start], last = words[start + wanted.count - 1]
                    ranges.append(first.ranges[0].lowerBound..<last.ranges[last.ranges.count - 1].upperBound)
                }
            }
        }
        return merged(ranges)
    }

    /// The part of a long text around its first match, on one line; the whole text when it is short or nothing in it matches.
    public static func snippet(of text: String, query: String, length: Int = 160) -> String {
        let flat = flattenNewlines(text)
        guard flat.count > length else { return flat }
        let compiled = compile(terms(query))
        guard !compiled.isEmpty, let first = firstMatch(in: flat, compiled: compiled) else {
            return String(flat.prefix(length)) + "…"
        }
        let lead = length / 4
        guard first.charOffset > lead else { return String(flat.prefix(length)) + "…" }
        let start = flat.index(first.index, offsetBy: -lead)
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        return "…" + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    private static func flattenNewlines(_ text: String) -> String {
        text.contains(where: \.isNewline) ? text.split(whereSeparator: \.isNewline).joined(separator: " ") : text
    }

    private struct Positioned {
        var scalars: [Unicode.Scalar]
        var ranges: [Range<String.Index>]
        var charOffsets: [Int]
        let isCJK: Bool
    }

    private static func matchesPhrase(_ words: [Positioned], start: Int, wanted: [Unicode.Scalar]) -> Bool {
        for offset in 0..<wanted.count {
            let word = words[start + offset]
            guard word.scalars.count == 1, word.scalars[0] == wanted[offset] else { return false }
        }
        return true
    }

    private static func firstMatch(in text: String, compiled: [CompiledTerm]) -> (index: String.Index, charOffset: Int)? {
        let maxWindow = compiled.reduce(1) { current, term in
            if case .phrase(let wanted) = term { return max(current, wanted.count) }
            return current
        }
        let words = positioned(text, stopAfterMatchWindow: maxWindow, compiled: compiled)
        for index in words.indices {
            for term in compiled {
                switch term {
                case .prefix(let wanted):
                    let word = words[index]
                    if !word.isCJK, word.scalars.count >= wanted.count, word.scalars.starts(with: wanted) {
                        return (word.ranges[0].lowerBound, word.charOffsets[0])
                    }
                case .phrase(let wanted):
                    if index + wanted.count <= words.count, matchesPhrase(words, start: index, wanted: wanted) {
                        return (words[index].ranges[0].lowerBound, words[index].charOffsets[0])
                    }
                }
            }
        }
        return nil
    }

    private static func highlightOffsets(in words: [Positioned], compiled: [CompiledTerm]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for term in compiled {
            switch term {
            case .prefix(let wanted):
                for word in words where !word.isCJK && word.scalars.count >= wanted.count && word.scalars.starts(with: wanted) {
                    ranges.append(word.charOffsets[0]..<(word.charOffsets[wanted.count - 1] + 1))
                }
            case .phrase(let wanted):
                guard words.count >= wanted.count else { continue }
                for start in 0...(words.count - wanted.count) {
                    guard matchesPhrase(words, start: start, wanted: wanted) else { continue }
                    let first = words[start], last = words[start + wanted.count - 1]
                    ranges.append(first.charOffsets[0]..<(last.charOffsets[last.charOffsets.count - 1] + 1))
                }
            }
        }
        return mergedOffsets(ranges)
    }

    private static func positioned(
        _ text: String,
        stopAfterMatchWindow window: Int = 0,
        compiled: [CompiledTerm] = []
    ) -> [Positioned] {
        var words: [Positioned] = []
        var open = false
        var charOffset = 0
        var matchedAtWord: Int?

        func canStopNow() -> Bool {
            guard window > 0, !open else { return false }
            if let matchedAtWord { return words.count >= matchedAtWord + window }
            // Check newly completed tail words for an early match so 20k-char bodies stop near the first hit.
            let checkFrom = max(0, words.count - window)
            for start in checkFrom..<words.count {
                for term in compiled {
                    switch term {
                    case .prefix(let wanted):
                        let word = words[start]
                        if !word.isCJK, word.scalars.count >= wanted.count, word.scalars.starts(with: wanted) {
                            matchedAtWord = start
                            return words.count >= start + window
                        }
                    case .phrase(let wanted):
                        if start + wanted.count <= words.count, matchesPhrase(words, start: start, wanted: wanted) {
                            matchedAtWord = start
                            return words.count >= start + window
                        }
                    }
                }
            }
            return false
        }

        for index in text.indices {
            let char = text[index]
            let range = index..<text.index(after: index)
            defer { charOffset += 1 }
            if let ascii = char.asciiValue {
                switch ascii {
                case 0x30...0x39, 0x61...0x7A:
                    let scalar = Unicode.Scalar(ascii)
                    if open {
                        words[words.count - 1].scalars.append(scalar)
                        words[words.count - 1].ranges.append(range)
                        words[words.count - 1].charOffsets.append(charOffset)
                    } else {
                        words.append(Positioned(scalars: [scalar], ranges: [range], charOffsets: [charOffset], isCJK: false))
                        open = true
                    }
                case 0x41...0x5A:
                    let scalar = Unicode.Scalar(ascii + 32)
                    if open {
                        words[words.count - 1].scalars.append(scalar)
                        words[words.count - 1].ranges.append(range)
                        words[words.count - 1].charOffsets.append(charOffset)
                    } else {
                        words.append(Positioned(scalars: [scalar], ranges: [range], charOffsets: [charOffset], isCJK: false))
                        open = true
                    }
                default:
                    open = false
                    if canStopNow() { return words }
                }
                continue
            }
            for scalar in fold(String(char)).unicodeScalars {
                switch kind(scalar) {
                case .word:
                    if open {
                        words[words.count - 1].scalars.append(scalar)
                        words[words.count - 1].ranges.append(range)
                        words[words.count - 1].charOffsets.append(charOffset)
                    } else {
                        words.append(Positioned(scalars: [scalar], ranges: [range], charOffsets: [charOffset], isCJK: false))
                        open = true
                    }
                case .cjk:
                    open = false
                    words.append(Positioned(scalars: [scalar], ranges: [range], charOffsets: [charOffset], isCJK: true))
                    if canStopNow() { return words }
                case .separator:
                    open = false
                    if canStopNow() { return words }
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

    private static func mergedOffsets(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
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
