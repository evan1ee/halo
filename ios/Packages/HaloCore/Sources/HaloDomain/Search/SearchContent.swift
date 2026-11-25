import Foundation
import HaloFoundation

/// Turns messages into what search finds them by (MESSAGE_SEARCH FR-4).
public enum SearchContent {
    /// Longer texts are indexed up to here.
    public static let maximumLength = 32_768

    /// A text, notice or emote. `nil` when there is nothing in it.
    public static func text(_ body: String, html: String? = nil, isReply: Bool = false) -> SearchableContent? {
        let shown = String((isReply ? withoutReplyFallback(body) : body).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
        guard !shown.isEmpty else { return nil }
        let addresses = html.map(linkAddresses(inHTML:)) ?? []
        let isLink = containsAddress(shown) || !addresses.isEmpty
        return SearchableContent(kind: isLink ? .link : .message, body: shown, extra: addresses.filter { !shown.contains($0) })
    }

    /// A picture, video, audio file or other file.
    public static func attachment(_ kind: MediaKind, filename: String, caption: String?) -> SearchableContent? {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !text.isEmpty else { return nil }
        let shown = text.isEmpty ? name : text
        return SearchableContent(kind: kind == .file ? .file : .media, body: String(shown.prefix(maximumLength)), extra: shown == name || name.isEmpty ? [] : [name])
    }

    public static func poll(question: String, options: [String]) -> SearchableContent? {
        let shown = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return nil }
        return SearchableContent(kind: .message, body: String(shown.prefix(maximumLength)), extra: options)
    }

    // MARK: Event content as JSON

    public struct Parsed: Sendable, Equatable {
        public let content: SearchableContent?
        public let threadRoot: EventID?
        /// The message this one replaces (an edit).
        public let replaces: EventID?
    }

    /// The content of an `m.room.message` event; `nil` when it isn't a JSON object.
    public static func parse(message json: String) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let relation = object["m.relates_to"] as? [String: Any]
        let type = relation?["rel_type"] as? String
        let related = (relation?["event_id"] as? String).flatMap { try? EventID($0) }
        let isReply = relation?["m.in_reply_to"] != nil
        if type == "m.replace", let related {
            let replacement = object["m.new_content"] as? [String: Any]
            return Parsed(content: replacement.flatMap { content(of: $0, isReply: false) }, threadRoot: nil, replaces: related)
        }
        return Parsed(content: content(of: object, isReply: isReply), threadRoot: type == "m.thread" ? related : nil, replaces: nil)
    }

    /// The content of a poll start event (stable or MSC3381).
    public static func parse(poll json: String) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let start = (object["m.poll"] ?? object["m.poll.start"] ?? object["org.matrix.msc3381.poll.start"]) as? [String: Any] else { return nil }
        let relation = object["m.relates_to"] as? [String: Any]
        let related = (relation?["event_id"] as? String).flatMap { try? EventID($0) }
        let type = relation?["rel_type"] as? String
        let answers = (start["answers"] as? [[String: Any]] ?? []).map(plainText)
        let poll = poll(question: plainText(start["question"] as? [String: Any] ?? [:]), options: answers.filter { !$0.isEmpty })
        return Parsed(content: poll, threadRoot: type == "m.thread" ? related : nil, replaces: type == "m.replace" ? related : nil)
    }

    private static func plainText(_ object: [String: Any]) -> String {
        if let text = object["body"] as? String { return text }
        for key in ["m.text", "org.matrix.msc1767.text"] {
            if let text = object[key] as? String { return text }
            if let list = object[key] as? [[String: Any]], let text = list.first(where: { $0["mimetype"] == nil || $0["mimetype"] as? String == "text/plain" })?["body"] as? String { return text }
        }
        return ""
    }

    private static func content(of object: [String: Any], isReply: Bool) -> SearchableContent? {
        let body = object["body"] as? String ?? ""
        switch object["msgtype"] as? String {
        case "m.text", "m.notice", "m.emote": return text(body, html: object["formatted_body"] as? String, isReply: isReply)
        case "m.image": return attachment(.image, object, body)
        case "m.video": return attachment(.video, object, body)
        case "m.audio": return attachment(.audio, object, body)
        case "m.file": return attachment(.file, object, body)
        default:
            // A gallery: one message with several files.
            guard let items = object["itemtypes"] as? [[String: Any]], !items.isEmpty else { return nil }
            let names = items.compactMap { ($0["filename"] ?? $0["body"]) as? String }
            return SearchableContent(kind: .media, body: body.isEmpty ? names.joined(separator: ", ") : body, extra: names)
        }
    }

    /// With a `filename` the body is the caption (Matrix 1.10); without one it is the file name.
    private static func attachment(_ kind: MediaKind, _ object: [String: Any], _ body: String) -> SearchableContent? {
        guard let name = object["filename"] as? String else { return attachment(kind, filename: body, caption: nil) }
        return attachment(kind, filename: name, caption: body == name ? nil : body)
    }

    // MARK: Text

    /// Without the quoted lines that old clients put before a reply.
    static func withoutReplyFallback(_ body: String) -> String {
        guard body.hasPrefix("> ") else { return body }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.hasPrefix("> ") || first == ">" { lines.removeFirst() }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    static func containsAddress(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("http://") || lowered.contains("https://") || lowered.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix("www.") && $0.count > 5 }
    }

    /// The web addresses of an HTML body's links. Mentions (`matrix.to` links to people) aren't links to search for.
    static func linkAddresses(inHTML html: String) -> [String] {
        var result: [String] = []
        var rest = html[...]
        while let start = rest.range(of: "href=", options: .caseInsensitive) {
            rest = rest[start.upperBound...]
            guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { break }
            let address = rest[..<end].replacingOccurrences(of: "&amp;", with: "&")
            rest = rest[end...]
            guard address.hasPrefix("http"), !address.contains("matrix.to/#/@"), !address.contains("matrix.to/#/%40"), !result.contains(address) else { continue }
            result.append(address)
        }
        return result
    }
}
