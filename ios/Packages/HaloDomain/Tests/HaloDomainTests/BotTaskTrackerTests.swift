import Testing
import HaloFoundation

@testable import HaloDomain

@Suite("BotTaskTracker")
struct BotTaskTrackerTests {
    private func event(_ raw: String) throws -> EventID { try EventID(raw) }
    private func list(_ rows: [(String, Bool)]) -> BotCard {
        .todoList(title: "T", rows: rows.map { .init(id: $0.0, text: "t\($0.0)", isDone: $0.1) })
    }
    private let bot = "@bot:x.org"

    @Test("a created task is the source of its id; a list row without a creation message has none")
    func sources() throws {
        let tracker = BotTaskTracker([
            .init(bot: bot, eventID: try event("$a"), card: .taskAdded(id: "1", owner: nil, title: "Milk")),
            .init(bot: bot, eventID: try event("$l"), card: list([("1", false), ("2", false)])),
        ])
        #expect(tracker.source(of: .init(bot: bot, id: "1")) == .init(eventID: try event("$a"), title: "Milk"))
        #expect(tracker.source(of: .init(bot: bot, id: "2")) == nil)
        #expect(tracker.sources.count == 1)
    }

    @Test("a newer list decides: finished marks done, a later unfinished list reopens")
    func lists() throws {
        let key = BotTaskTracker.Key(bot: bot, id: "1")
        func tracker(_ lists: [[(String, Bool)]]) throws -> BotTaskTracker {
            BotTaskTracker(try lists.enumerated().map { .init(bot: bot, eventID: try event("$\($0.offset)"), card: list($0.element)) })
        }
        #expect(try tracker([[("1", false)], [("1", true)]]).isCompleted(key))
        #expect(try !tracker([[("1", true)], [("1", false)]]).isCompleted(key))
    }

    @Test("`Marked task as done` completes the one task of that bot with that title, and nothing when ambiguous or unknown")
    func doneMessage() throws {
        let key = BotTaskTracker.Key(bot: bot, id: "1")
        let added = BotTaskTracker.Message(bot: bot, eventID: try event("$a"), card: .taskAdded(id: "1", owner: nil, title: "Milk"))
        let done = BotTaskTracker.Message(bot: bot, eventID: try event("$d"), card: .taskDone(title: "Milk"))
        #expect(BotTaskTracker([added, done]).isCompleted(key))
        #expect(!BotTaskTracker([done, added]).isCompleted(key))  // out of order: the confirmation predates the task
        let twin = BotTaskTracker.Message(bot: bot, eventID: try event("$b"), card: .taskAdded(id: "2", owner: nil, title: "Milk"))
        #expect(BotTaskTracker([added, twin, done]).completed.isEmpty)  // two tasks with one title: don't guess
        let other = BotTaskTracker.Message(bot: "@other:x.org", eventID: try event("$o"), card: .taskDone(title: "Milk"))
        #expect(!BotTaskTracker([added, other]).isCompleted(key))
    }

    @Test("the same id from two bots stays apart, and a reused id starts open again")
    func identity() throws {
        let a = BotTaskTracker.Key(bot: bot, id: "1"), b = BotTaskTracker.Key(bot: "@o:x.org", id: "1")
        let tracker = BotTaskTracker([
            .init(bot: bot, eventID: try event("$a"), card: .taskAdded(id: "1", owner: nil, title: "A")),
            .init(bot: "@o:x.org", eventID: try event("$b"), card: .taskAdded(id: "1", owner: nil, title: "B")),
            .init(bot: bot, eventID: try event("$l"), card: list([("1", true)])),
        ])
        #expect(tracker.isCompleted(a) && !tracker.isCompleted(b))
        let reused = BotTaskTracker(tracker.sources.isEmpty ? [] : [
            .init(bot: bot, eventID: try event("$l"), card: list([("1", true)])),
            .init(bot: bot, eventID: try event("$n"), card: .taskAdded(id: "1", owner: nil, title: "New")),
        ])
        #expect(!reused.isCompleted(a))
    }

    @Test("an own-event with no server id yet can't be a source")
    func localEcho() {
        let tracker = BotTaskTracker([.init(bot: bot, eventID: nil, card: .taskAdded(id: "1", owner: nil, title: "x"))])
        #expect(tracker.sources.isEmpty)
    }
}
