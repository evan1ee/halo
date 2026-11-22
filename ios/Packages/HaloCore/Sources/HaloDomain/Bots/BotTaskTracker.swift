import Foundation
import HaloFoundation

/// What a room's bot messages say about tasks (docs/features/BOT_MESSAGES.md §3, §6): where each task was created and which are
/// done. A pure function over the timeline, so it is recomputed on every change and never holds state that could go stale.
public struct BotTaskTracker: Sendable, Equatable {
    /// A task is identified by the bot that owns it and the bot's own number for it (the room is implied: one timeline).
    public struct Key: Hashable, Sendable {
        public let bot: String
        public let id: String
        public init(bot: String, id: String) { self.bot = bot; self.id = id }
    }

    public struct Source: Sendable, Equatable {
        /// The `Added Task #N` message: the only event the bot accepts a reaction on (D22/D23).
        public let eventID: EventID
        public let title: String
    }

    /// One bot message, oldest first.
    public struct Message: Sendable {
        public let bot: String
        public let eventID: EventID?
        public let card: BotCard
        public init(bot: String, eventID: EventID?, card: BotCard) { self.bot = bot; self.eventID = eventID; self.card = card }
    }

    /// Where each task was created, found only from `TaskAddedV1` messages. A task without an entry is read-only (AC-B3).
    public private(set) var sources: [Key: Source] = [:]
    /// Tasks the bot has confirmed as done: by a newer list showing the row finished, or by `Marked task as done` for its title.
    public private(set) var completed: Set<Key> = []

    public init(_ messages: [Message]) {
        for message in messages {
            switch message.card {
            case .taskAdded(let id, _, let title):
                guard let eventID = message.eventID else { continue }
                let key = Key(bot: message.bot, id: id)
                sources[key] = Source(eventID: eventID, title: title)
                completed.remove(key)  // an id reused for a new task starts open again
            case .todoList(_, let rows):
                // The newest list is the bot's current word on each task it mentions.
                for row in rows {
                    let key = Key(bot: message.bot, id: row.id)
                    if row.isDone { completed.insert(key) } else { completed.remove(key) }
                }
            case .taskDone(let title):
                // Only a task this bot created, found by its title; the newest creation with that title wins.
                let match = sources.filter { $0.key.bot == message.bot && $0.value.title == title }
                if match.count == 1, let key = match.keys.first { completed.insert(key) }
            case .reminderSet, .taskDeleted:
                continue
            }
        }
    }

    public func source(of key: Key) -> Source? { sources[key] }
    public func isCompleted(_ key: Key) -> Bool { completed.contains(key) }
}
