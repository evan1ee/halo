import Foundation

/// The chats with unread messages for the medium widget (M16, D93). Counts are the app's last evaluated ones (the
/// `AttentionCache`, D82); names come from the opt-in chat list the app keeps for Siri and Spotlight (D88). With that
/// setting off there are no names, so the widget shows no chats and says how to turn them on (it never falls back to room
/// IDs or messages).
public struct UnreadChatsSnapshot: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let unread: Int
    }

    public let rows: [Row]
    /// Chats needing attention that don't fit, or whose names are unknown.
    public let moreCount: Int
    /// `false` when no chat names are available (the setting is off, or the app hasn't published them yet).
    public let namesAvailable: Bool
    public let updatedAt: Date?

    public init(counts: [String: Int], names: [String: String], updatedAt: Date?, limit: Int = 4) {
        namesAvailable = !names.isEmpty
        let named = counts.compactMap { id, unread -> Row? in
            guard unread > 0, let name = names[id], !name.isEmpty else { return nil }
            return Row(id: id, name: name, unread: unread)
        }.sorted { a, b in
            a.unread != b.unread ? a.unread > b.unread : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        rows = Array(named.prefix(limit))
        moreCount = counts.values.filter { $0 > 0 }.count - rows.count
        self.updatedAt = updatedAt
    }

    /// One sentence for the empty states and VoiceOver.
    public var summary: String {
        if updatedAt == nil { return "Open Halo to see your unread chats." }
        if !namesAvailable { return "Turn on \"Chats in Siri and Spotlight\" in Halo's settings to see chat names here." }
        if rows.isEmpty, moreCount <= 0 { return "No unread messages." }
        return rows.map { "\($0.name), \($0.unread)" }.joined(separator: "; ")
    }
}
