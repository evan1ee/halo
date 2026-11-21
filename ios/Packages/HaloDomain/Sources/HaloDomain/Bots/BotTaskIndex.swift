import Foundation
import HaloFoundation

/// One task or reminder a known bot has told the user about (docs/features/BOT_ACTIVITY.md §3, `bot_task`). The truth lives in
/// the bot's backend; this is what Halo has seen in message timelines, so it carries the time it was last said (`asOf`).
public struct BotTaskEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case todo, reminder }
    public enum Status: String, Sendable, Equatable { case open, completed, deleted }

    public struct Key: Sendable, Hashable, Comparable {
        public let room: RoomID
        public let bot: String
        public let kind: Kind
        /// The bot's own number for the task (a string, as parsed).
        public let id: String

        public init(room: RoomID, bot: String, kind: Kind, id: String) {
            self.room = room
            self.bot = bot
            self.kind = kind
            self.id = id
        }

        public static func < (a: Key, b: Key) -> Bool {
            (a.room.rawValue, a.bot, a.kind.rawValue, a.id.count, a.id) < (b.room.rawValue, b.bot, b.kind.rawValue, b.id.count, b.id)
        }
    }

    public var id: Key { key }
    public let key: Key
    public var title: String?
    public var status: Status
    /// The message that created it (`Added Task #N` / `Reminder #N set!`); `nil` for a task only seen in a list, which is then
    /// read-only (D23).
    public var sourceEventID: EventID?
    /// When the newest bot message about it was sent.
    public var asOf: Date
    /// A reminder's time text as the bot wrote it, or a task's owner.
    public var detail: String?

    public init(key: Key, title: String?, status: Status, sourceEventID: EventID?, asOf: Date, detail: String? = nil) {
        self.key = key
        self.title = title
        self.status = status
        self.sourceEventID = sourceEventID
        self.asOf = asOf
        self.detail = detail
    }
}

/// A bot message read as a card, with where and when it was sent.
public struct BotObservation: Sendable, Equatable {
    public let bot: String
    public let eventID: EventID?
    public let timestamp: Date
    public let card: BotCard

    public init(bot: String, eventID: EventID?, timestamp: Date, card: BotCard) {
        self.bot = bot
        self.eventID = eventID
        self.timestamp = timestamp
        self.card = card
    }
}

/// `BotTaskIndexer`'s pure core (BOT_ACTIVITY FR-1): the entries one room's bot messages describe. It reads the whole list in
/// order every time, so the result depends only on the messages (the same timeline always gives the same entries, AC-A3).
public enum BotTaskDerivation {
    /// - Parameter observations: the room's bot messages, oldest first.
    public static func entries(room: RoomID, observations: [BotObservation]) -> [BotTaskEntry] {
        var map: [BotTaskEntry.Key: BotTaskEntry] = [:]

        /// The task a confirmation by title means: the one task `bot` created in this room (it has a source message) with that title,
        /// as the timeline's `BotTaskTracker` reads it; else the one task of `bot` with that title. `nil` when there are none or
        /// several (a guess would be wrong). Deleted tasks never match.
        func uniqueTodo(bot: String, title: String) -> BotTaskEntry.Key? {
            let matches = map.filter { $0.key.bot == bot && $0.key.kind == .todo && $0.value.title == title && $0.value.status != .deleted }
            let created = matches.filter { $0.value.sourceEventID != nil }
            if created.count == 1 { return created.keys.first }
            return matches.count == 1 ? matches.keys.first : nil
        }

        for item in observations {
            switch item.card {
            case .taskAdded(let id, let owner, let title):
                let key = BotTaskEntry.Key(room: room, bot: item.bot, kind: .todo, id: id)
                // An id the bot reuses is a new task: it starts open again.
                map[key] = BotTaskEntry(key: key, title: title, status: .open, sourceEventID: item.eventID, asOf: item.timestamp, detail: owner)
            case .todoList(_, let rows):
                for row in rows {
                    let key = BotTaskEntry.Key(room: room, bot: item.bot, kind: .todo, id: row.id)
                    var entry = map[key] ?? BotTaskEntry(key: key, title: nil, status: .open, sourceEventID: nil, asOf: item.timestamp)
                    entry.title = row.text
                    entry.status = row.isDone ? .completed : .open
                    entry.asOf = item.timestamp
                    map[key] = entry
                }
            case .reminderSet(let id, let when, let title):
                let key = BotTaskEntry.Key(room: room, bot: item.bot, kind: .reminder, id: id)
                map[key] = BotTaskEntry(key: key, title: title, status: .open, sourceEventID: item.eventID, asOf: item.timestamp, detail: when)
            case .taskDone(let title):
                if let key = uniqueTodo(bot: item.bot, title: title) { map[key]?.status = .completed; map[key]?.asOf = item.timestamp }
            case .taskDeleted(let title):
                if let key = uniqueTodo(bot: item.bot, title: title) { map[key]?.status = .deleted; map[key]?.asOf = item.timestamp }
            }
        }
        return map.values.sorted { $0.key < $1.key }
    }
}
