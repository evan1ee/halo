import Foundation

/// Turns the HTML subset Matrix clients send in `formatted_body` into styled text (docs/features/MESSAGING.md FR-1,
/// TIMELINE FR-2). Only a fixed set of tags is honoured; every other tag is dropped but its text stays, and nothing is
/// ever executed or fetched. Links are kept only for web, mail and Matrix schemes.
enum HTMLText {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "matrix"]

    static func attributed(_ html: String) -> AttributedString {
        var result = AttributedString()
        var bold = 0, italic = 0, strike = 0, code = 0
        var links: [URL?] = []
        var listStack: [(ordered: Bool, count: Int)] = []
        var skipDepth = 0  // inside <mx-reply>, whose quoted text is shown separately as a reply preview

        func append(_ text: String) {
            guard !text.isEmpty, skipDepth == 0 else { return }
            var piece = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if strike > 0 { intent.insert(.strikethrough) }
            if code > 0 { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = links.last, let url = link { piece.link = url }
            result += piece
        }
        func newline() {
            guard skipDepth == 0, !result.characters.isEmpty, result.characters.last != "\n" else { return }
            result += AttributedString("\n")
        }

        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                let tag = parse(String(html[html.index(after: index)..<close]))
                index = html.index(after: close)
                switch (tag.name, tag.isClosing) {
                case ("b", false), ("strong", false): bold += 1
                case ("b", true), ("strong", true): bold = max(0, bold - 1)
                case ("i", false), ("em", false): italic += 1
                case ("i", true), ("em", true): italic = max(0, italic - 1)
                case ("s", false), ("del", false), ("strike", false): strike += 1
                case ("s", true), ("del", true), ("strike", true): strike = max(0, strike - 1)
                case ("code", false): code += 1
                case ("code", true): code = max(0, code - 1)
                case ("a", false): links.append(tag.href.flatMap(safeURL))
                case ("a", true): if !links.isEmpty { links.removeLast() }
                case ("br", _): newline()
                case ("p", _), ("div", _), ("pre", _), ("blockquote", _), ("h1", _), ("h2", _), ("h3", _), ("h4", _), ("h5", _), ("h6", _): newline()
                case ("ul", false): listStack.append((false, 0))
                case ("ol", false): listStack.append((true, 0))
                case ("ul", true), ("ol", true): if !listStack.isEmpty { listStack.removeLast() }; newline()
                case ("li", false):
                    newline()
                    if var top = listStack.popLast() {
                        top.count += 1
                        listStack.append(top)
                        append(top.ordered ? "\(top.count). " : "• ")
                    }
                case ("li", true): newline()
                case ("mx-reply", false): skipDepth += 1
                case ("mx-reply", true): skipDepth = max(0, skipDepth - 1)
                default: break
                }
            } else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                // A lone "<" that isn't a tag is plain text.
                let end = next == index ? html.index(after: index) : next
                append(decode(String(html[index..<end])))
                index = end
            }
        }
        // Trim trailing newlines left by block tags.
        while result.characters.last == "\n" { result.characters.removeLast() }
        return result
    }

    private struct Tag { var name: String; var isClosing: Bool; var href: String? }

    private static func parse(_ raw: String) -> Tag {
        var body = Substring(raw)
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        var href: String?
        if let range = body.range(of: #"href\s*=\s*("([^"]*)"|'([^']*)')"#, options: [.regularExpression, .caseInsensitive]) {
            let attribute = body[range]
            if let quote = attribute.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                href = decode(String(attribute[attribute.index(after: quote)...].dropLast()))
            }
        }
        return Tag(name: name, isClosing: closing, href: href)
    }

    private static func safeURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    private static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }
}
