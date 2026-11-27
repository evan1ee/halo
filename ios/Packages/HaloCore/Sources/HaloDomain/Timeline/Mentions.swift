import Foundation
import HaloFoundation

/// A member of a room, as the mention picker offers them.
public struct RoomMember: Sendable, Equatable, Identifiable {
    public var id: UserID { user }
    public let user: UserID
    public let displayName: String?

    public init(user: UserID, displayName: String?) {
        self.user = user
        self.displayName = displayName
    }

    /// What the composer inserts after `@`: the display name, else the user ID.
    public var mentionName: String { displayName ?? user.rawValue }
}

/// A user mentioned in a message being written. The composer text contains `@name`.
public struct Mention: Sendable, Equatable {
    public let user: UserID
    public let name: String

    public init(user: UserID, name: String) {
        self.user = user
        self.name = name
    }
}

/// Turns composer text with mentions into the Markdown that becomes the message's formatted body, and finds which
/// mentions the final text still contains (MESSAGING FR-1, AC-M2). A mention becomes a `matrix.to` link, which
/// other clients render as a pill; the users go into `m.mentions`. Pure.
public enum MentionFormatter {
    public struct Result: Equatable, Sendable {
        public let markdown: String
        /// The users actually present in the text, in order of first appearance, each once.
        public let users: [UserID]
    }

    public struct HTMLResult: Equatable, Sendable {
        public let html: String
        /// The users actually present in the text, in order of first appearance, each once.
        public let users: [UserID]
    }

    public static func apply(_ text: String, mentions: [Mention]) -> Result {
        // Longest names first, so "@Alice B" wins over "@Alice".
        let candidates = mentions.sorted { $0.name.count > $1.name.count }
        var output = ""
        var users: [UserID] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", let (mention, end) = match(candidates, in: text, at: index) {
                output += "[@\(escape(mention.name))](https://matrix.to/#/\(link(mention.user)))"
                if !users.contains(mention.user) { users.append(mention.user) }
                index = end
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return Result(markdown: output, users: users)
    }

    /// Builds Matrix HTML `formatted_body` with `matrix.to` mention pills while leaving the caller's plain-text `body`
    /// free of raw Markdown link syntax (`hello @Peer`, fixing GA-30 / M20-10).
    /// All literal text and display names are HTML-escaped first so hostile display names cannot inject markup.
    public static func html(_ text: String, mentions: [Mention]) -> HTMLResult {
        let candidates = mentions.sorted { $0.name.count > $1.name.count }
        var output = ""
        var users: [UserID] = []
        var plainBuffer = ""

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            output += renderSafeInlineHTML(plainBuffer)
            plainBuffer.removeAll(keepingCapacity: true)
        }

        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", let (mention, end) = match(candidates, in: text, at: index) {
                flushPlain()
                let escapedName = htmlEscape(mention.name)
                output += "<a href=\"https://matrix.to/#/\(link(mention.user))\">@\(escapedName)</a>"
                if !users.contains(mention.user) { users.append(mention.user) }
                index = end
            } else {
                plainBuffer.append(text[index])
                index = text.index(after: index)
            }
        }
        flushPlain()
        return HTMLResult(html: output, users: users)
    }

    /// Escapes raw HTML entities and converts lightweight inline formatting (`` `code` ``, `**bold**`, newlines)
    /// in non-mention text segments so messages mixing mentions and basic formatting render cleanly.
    private static func renderSafeInlineHTML(_ raw: String) -> String {
        let escaped = htmlEscape(raw)
        var out = ""
        var i = escaped.startIndex
        while i < escaped.endIndex {
            if escaped[i] == "\n" {
                out += "<br/>"
                i = escaped.index(after: i)
            } else if escaped[i] == "`",
                      let close = escaped[escaped.index(after: i)...].firstIndex(of: "`"),
                      close > escaped.index(after: i) {
                out += "<code>\(escaped[escaped.index(after: i)..<close])</code>"
                i = escaped.index(after: close)
            } else if escaped[i...].hasPrefix("**") {
                let start = escaped.index(i, offsetBy: 2)
                if let close = escaped[start...].range(of: "**"), close.lowerBound > start {
                    out += "<strong>\(escaped[start..<close.lowerBound])</strong>"
                    i = close.upperBound
                } else {
                    out.append(escaped[i])
                    i = escaped.index(after: i)
                }
            } else {
                out.append(escaped[i])
                i = escaped.index(after: i)
            }
        }
        return out
    }

    static func htmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The mention whose `@name` starts at `index` and isn't followed by a letter or digit.
    private static func match(_ candidates: [Mention], in text: String, at index: String.Index) -> (Mention, String.Index)? {
        let rest = text[text.index(after: index)...]
        for mention in candidates where rest.hasPrefix(mention.name) {
            let end = rest.index(rest.startIndex, offsetBy: mention.name.count)
            if end < rest.endIndex, rest[end].isLetter || rest[end].isNumber { continue }
            return (mention, end)
        }
        return nil
    }

    /// The user's `matrix.to` permalink (`https://matrix.to/#/@user:server`), percent-encoding any unusual characters.
    public static func matrixToURL(for user: UserID) -> URL? {
        URL(string: "https://matrix.to/#/\(link(user))")
    }

    /// The user ID as a URL fragment. Current user IDs only use these characters; anything else (historical IDs) is
    /// percent-encoded so it can't end the link.
    static func link(_ user: UserID) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@:._=-/+")
        return user.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? user.rawValue
    }

    /// The name as literal link text. Display names are chosen by other users, so every ASCII punctuation character is
    /// backslash-escaped (CommonMark): no emphasis, no nested link, and no raw HTML such as `<a href=…>` can reach the
    /// formatted body of the user's own message.
    static func escape(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.isASCII, scalar.properties.generalCategory.isPunctuationOrSymbol { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }
}
