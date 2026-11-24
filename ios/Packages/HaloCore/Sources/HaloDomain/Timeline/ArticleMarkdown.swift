import Foundation

/// The attachment panel's Article editor (docs/features/COMPOSER_PANELS.md §7a, D101): a long message written in Markdown,
/// sent through the ordinary text path, where the SDK turns the Markdown into the formatted body. These helpers are the
/// editor's formatting bar and its preview's block structure; they never touch the network.
public enum ArticleMarkdown {
    /// Longest article, in characters (a Matrix event is capped at 64 KiB, and the formatted body doubles the text).
    public static let maximumLength = 20_000

    /// A formatting-bar action.
    public enum Format: String, CaseIterable, Sendable {
        case bold, italic, strikethrough, code, link, heading, bulletList, numberedList, quote, codeBlock
    }

    /// One block of the preview.
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case quote(String)
        case code(String)
        case rule
    }

    // MARK: Formatting

    /// Applies `format` to `selection` (character offsets into `text`), returning the new text and selection.
    ///
    /// Inline formats wrap the selection (or insert empty markers with the cursor between them); line formats prefix
    /// every line the selection touches and are removed again when all those lines already have the prefix.
    public static func apply(_ format: Format, to text: String, selection: Range<Int>) -> (text: String, selection: Range<Int>) {
        let chars = Array(text)
        let lower = min(max(0, selection.lowerBound), chars.count)
        let upper = min(max(lower, selection.upperBound), chars.count)
        switch format {
        case .bold: return wrap(chars, lower, upper, "**")
        case .italic: return wrap(chars, lower, upper, "_")
        case .strikethrough: return wrap(chars, lower, upper, "~~")
        case .code: return wrap(chars, lower, upper, "`")
        case .link:
            let label = lower == upper ? "link" : String(chars[lower..<upper])
            let placeholder = "https://"
            let inserted = "[\(label)](\(placeholder))"
            let result = String(chars[..<lower]) + inserted + String(chars[upper...])
            let start = lower + label.count + 3
            return (result, start..<(start + placeholder.count))
        case .heading: return prefixLines(chars, lower, upper) { _ in "## " }
        case .bulletList: return prefixLines(chars, lower, upper) { _ in "- " }
        case .numberedList: return prefixLines(chars, lower, upper) { "\($0 + 1). " }
        case .quote: return prefixLines(chars, lower, upper) { _ in "> " }
        case .codeBlock:
            let body = String(chars[lower..<upper])
            let before = lower > 0 && chars[lower - 1] != "\n" ? "\n" : ""
            let opening = before + "```\n"
            let result = String(chars[..<lower]) + opening + body + "\n```" + String(chars[upper...])
            let start = lower + opening.count
            return (result, start..<(start + body.count))
        }
    }

    private static func wrap(_ chars: [Character], _ lower: Int, _ upper: Int, _ marker: String) -> (text: String, selection: Range<Int>) {
        let m = marker.count
        // Already wrapped: unwrap.
        if lower >= m, upper + m <= chars.count, String(chars[(lower - m)..<lower]) == marker, String(chars[upper..<(upper + m)]) == marker {
            let result = String(chars[..<(lower - m)]) + String(chars[lower..<upper]) + String(chars[(upper + m)...])
            return (result, (lower - m)..<(upper - m))
        }
        let result = String(chars[..<lower]) + marker + String(chars[lower..<upper]) + marker + String(chars[upper...])
        return (result, (lower + m)..<(upper + m))
    }

    private static func prefixLines(_ chars: [Character], _ lower: Int, _ upper: Int, prefix: (Int) -> String) -> (text: String, selection: Range<Int>) {
        var start = lower
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = upper
        while end < chars.count, chars[end] != "\n" { end += 1 }
        let lines = String(chars[start..<end]).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let prefixes = lines.indices.map(prefix)
        let removing = lines.indices.allSatisfy { lines[$0].hasPrefix(prefixes[$0]) }
        let changed = lines.indices.map { removing ? String(lines[$0].dropFirst(prefixes[$0].count)) : prefixes[$0] + lines[$0] }
        let block = changed.joined(separator: "\n")
        let result = String(chars[..<start]) + block + String(chars[end...])
        if lines.count == 1 {
            let shift = (removing ? -1 : 1) * prefixes[0].count
            let newLower = max(start, lower + shift), newUpper = max(newLower, upper + shift)
            return (result, newLower..<newUpper)
        }
        return (result, start..<(start + block.count))
    }

    // MARK: Preview

    /// The blocks the preview draws: headings, paragraphs (consecutive lines joined), list items, quotes, fenced code
    /// and rules. Inline formatting stays in the text for the view to style.
    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let heading = heading(line) { flush(); blocks.append(heading); continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); blocks.append(.bullet(String(line.dropFirst(2)))); continue
            }
            if let numbered = numbered(line) { flush(); blocks.append(numbered); continue }
            if line.hasPrefix(">") {
                flush()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
                continue
            }
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func numbered(_ line: String) -> Block? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .numbered(number, String(rest.dropFirst(2)))
    }

    /// `true` when `text` has something to send and fits.
    public static func canSend(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximumLength
    }
}
