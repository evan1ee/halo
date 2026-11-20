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

    public static func apply(_ text: String, mentions: [Mention]) -> Result {
        // Longest names first, so "@Alice B" wins over "@Alice".
        let candidates = mentions.sorted { $0.name.count > $1.name.count }
        var output = ""
        var users: [UserID] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", let (mention, end) = match(candidates, in: text, at: index) {
                output += "[@\(escape(mention.name))](https://matrix.to/#/\(mention.user.rawValue))"
                if !users.contains(mention.user) { users.append(mention.user) }
                index = end
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return Result(markdown: output, users: users)
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

    private static func escape(_ name: String) -> String {
        var result = ""
        for character in name {
            if "\\[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
