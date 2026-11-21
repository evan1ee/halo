import Foundation

/// A structured reading of a known bot's message (docs/features/BOT_MESSAGES.md §3, Layer 2).
public enum BotCard: Sendable, Equatable {
    case todoList(title: String, rows: [TodoRow])
    case taskAdded(id: String, owner: String?, title: String)
    case reminderSet(id: String, when: String?, title: String)
    case taskDone(title: String)
    case taskDeleted(title: String)

    public struct TodoRow: Sendable, Equatable {
        public let id: String
        public let text: String
        public let isDone: Bool
    }
}

/// Strict, versioned parsers over a bot's `formatted_body` (BOT_MESSAGES §3). Pure functions: every one fails closed with `nil`
/// on the slightest deviation, so the message then renders as ordinary formatted text (Layer 1).
public enum BotTemplates {
    /// The first parser that recognises `html` wins.
    public static func parse(_ html: String) -> BotCard? {
        // The SDK hands over HTML it has re-serialised (a `<br/>` comes back as `<br>`): accept all three spellings.
        let normalized = html.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "<br />", with: "<br/>")
            .replacingOccurrences(of: "<br>", with: "<br/>").trimmingCharacters(in: .whitespacesAndNewlines)
        return todoListV1(normalized) ?? taskAddedV1(normalized) ?? reminderSetV1(normalized) ?? taskDoneV1(normalized)
            ?? taskDeletedV1(normalized)
    }

    // MARK: Parsers

    /// `📋 <b>{title}:</b><br/>• [<b>#{id}</b>] {text}<br/>…`; a finished row is `<del>{text}</del> ✅`.
    static func todoListV1(_ html: String) -> BotCard? {
        let head = "📋 <b>", titleEnd = ":</b><br/>"
        guard html.hasPrefix(head), let end = html.range(of: titleEnd) else { return nil }
        guard let title = plain(String(html[html.index(html.startIndex, offsetBy: head.count)..<end.lowerBound])) else { return nil }
        var rows: [BotCard.TodoRow] = []
        for part in html[end.upperBound...].components(separatedBy: "<br/>") where !part.isEmpty {
            guard let row = todoRow(part) else { return nil }
            rows.append(row)
        }
        return rows.isEmpty ? nil : .todoList(title: title, rows: rows)
    }

    private static func todoRow(_ part: String) -> BotCard.TodoRow? {
        let open = "• [<b>#"
        guard part.hasPrefix(open), let close = part.range(of: "</b>] ") else { return nil }
        let id = String(part[part.index(part.startIndex, offsetBy: open.count)..<close.lowerBound])
        guard isID(id) else { return nil }
        let rest = String(part[close.upperBound...])
        if rest.hasPrefix("<del>") {
            guard let end = rest.range(of: "</del>"), rest[end.upperBound...].trimmingCharacters(in: .whitespaces) == "✅",
                let text = plain(String(rest[rest.index(rest.startIndex, offsetBy: 5)..<end.lowerBound]))
            else { return nil }
            return .init(id: id, text: text, isDone: true)
        }
        guard let text = plain(rest) else { return nil }
        return .init(id: id, text: text, isDone: false)
    }

    /// `Added Task <b>#{id}</b> for {owner}: <i>"{title}"</i>`
    static func taskAddedV1(_ html: String) -> BotCard? {
        let head = "Added Task <b>#"
        guard html.hasPrefix(head), let close = html.range(of: "</b>") else { return nil }
        let id = String(html[html.index(html.startIndex, offsetBy: head.count)..<close.lowerBound])
        guard isID(id) else { return nil }
        let rest = String(html[close.upperBound...])
        guard let title = quotedTail(rest, after: ": ") else { return nil }
        let before = String(rest[..<(rest.range(of: ": <i>\"", options: .backwards)?.lowerBound ?? rest.startIndex)])
        var owner: String?
        if before.hasPrefix(" for ") { owner = plain(String(before.dropFirst(5))) }
        else if !before.isEmpty { return nil }
        return .taskAdded(id: id, owner: owner, title: title.0)
    }

    /// `<b>Reminder #{id} set!</b> {when} for: <i>"{title}"</i>`
    static func reminderSetV1(_ html: String) -> BotCard? {
        guard let marker = html.range(of: "Reminder #"), html[..<marker.lowerBound].count <= 8,
            html[..<marker.lowerBound].hasSuffix("<b>") || html[..<marker.lowerBound].isEmpty,
            let setEnd = html.range(of: " set!</b>", range: marker.upperBound..<html.endIndex)
        else { return nil }
        let id = String(html[marker.upperBound..<setEnd.lowerBound])
        guard isID(id) else { return nil }
        let rest = String(html[setEnd.upperBound...])
        guard let tail = quotedTail(rest, after: "for: "), let forRange = rest.range(of: "for: <i>\"", options: .backwards) else { return nil }
        let when = plain(String(rest[..<forRange.lowerBound]).trimmingCharacters(in: .whitespaces))
        return .reminderSet(id: id, when: when?.isEmpty == true ? nil : when, title: tail.0)
    }

    /// `✅ Marked task as done: <i>"{title}"</i>`
    static func taskDoneV1(_ html: String) -> BotCard? { simple(html, head: "✅ Marked task as done: ").map(BotCard.taskDone) }

    /// `🗑 Deleted task: <i>"{title}"</i>`
    static func taskDeletedV1(_ html: String) -> BotCard? { simple(html, head: "🗑 Deleted task: ").map(BotCard.taskDeleted) }

    // MARK: Helpers

    private static func simple(_ html: String, head: String) -> String? {
        guard html.hasPrefix(head) else { return nil }
        let rest = String(html.dropFirst(head.count))
        guard rest.hasPrefix("<i>\""), rest.hasSuffix("\"</i>") else { return nil }
        return plain(String(rest.dropFirst(4).dropLast(5)))
    }

    /// The `<i>"title"</i>` that ends `text`, when it directly follows `lead` (the text before it is checked by the caller).
    private static func quotedTail(_ text: String, after lead: String) -> (String, Void)? {
        guard text.hasSuffix("\"</i>"), let open = text.range(of: lead + "<i>\"", options: .backwards),
            open.upperBound <= text.index(text.endIndex, offsetBy: -5)
        else { return nil }
        guard let title = plain(String(text[open.upperBound..<text.index(text.endIndex, offsetBy: -5)])) else { return nil }
        return (title, ())
    }

    private static func isID(_ text: String) -> Bool { !text.isEmpty && text.count <= 9 && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) }

    /// Text without markup: any tag or stray angle bracket fails the parse; named and numeric entities decode in one pass.
    static func plain(_ text: String) -> String? {
        guard !text.contains("<"), !text.contains(">") else { return nil }
        let trimmed = HTMLEntities.decode(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Bounded O(n) single-pass HTML entity decoder shared by bot template parsers and formatted-body rendering.
public enum HTMLEntities {
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semi = findEntityEnd(in: text, after: index) {
                let name = text[text.index(after: index)..<semi]
                if let decoded = decodeEntity(name) {
                    out.append(decoded)
                    index = text.index(after: semi)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// Scans at most 12 characters ahead for `;` so malformed input with many `&` stays O(n).
    private static func findEntityEnd(in text: String, after amp: String.Index) -> String.Index? {
        var cursor = text.index(after: amp)
        var steps = 0
        while cursor < text.endIndex, steps < 12 {
            let ch = text[cursor]
            if ch == ";" { return cursor }
            if ch == "&" || ch.isWhitespace { return nil }
            cursor = text.index(after: cursor)
            steps += 1
        }
        return nil
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        switch name {
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "amp": return "&"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let codePoint: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            let hex = digits.dropFirst()
            codePoint = !hex.isEmpty ? UInt32(hex, radix: 16) : nil
        } else {
            codePoint = !digits.isEmpty ? UInt32(digits, radix: 10) : nil
        }
        guard let codePoint, codePoint != 0, let scalar = Unicode.Scalar(codePoint) else { return nil }
        return String(scalar)
    }
}
