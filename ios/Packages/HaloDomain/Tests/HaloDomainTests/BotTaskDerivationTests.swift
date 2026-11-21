import Foundation
import HaloFoundation
import Testing

@testable import HaloDomain

@Suite("BotTaskDerivation")
struct BotTaskDerivationTests {
    let room = try! RoomID("!r:x.org")
    let bot = "@bot:x.org"

    func obs(_ t: TimeInterval, _ event: String?, _ card: BotCard) -> BotObservation {
        BotObservation(bot: bot, eventID: event.flatMap { try? EventID($0) }, timestamp: Date(timeIntervalSince1970: t), card: card)
    }

    func derive(_ items: [BotObservation]) -> [BotTaskEntry] { BotTaskDerivation.entries(room: room, observations: items) }

    @Test("added tasks and reminders are open with their source; lists update known tasks and add unknown ones without a source")
    func basics() {
        let entries = derive([
            obs(1, "$a", .taskAdded(id: "7", owner: "me", title: "Buy milk")),
            obs(2, "$r", .reminderSet(id: "3", when: "tomorrow 9am", title: "Call mum")),
            obs(3, "$l", .todoList(title: "Todo", rows: [.init(id: "7", text: "Buy milk", isDone: true), .init(id: "9", text: "Old one", isDone: false)])),
        ])
        #expect(entries.map(\.key.id) == ["3", "7", "9"])  // reminders sort before todos
        let milk = entries.first { $0.key.id == "7" }
        #expect(milk?.status == .completed && milk?.sourceEventID?.rawValue == "$a" && milk?.asOf == Date(timeIntervalSince1970: 3))
        let old = entries.first { $0.key.id == "9" }
        #expect(old?.status == .open && old?.sourceEventID == nil)
        let reminder = entries.first { $0.key.kind == .reminder }
        #expect(reminder?.detail == "tomorrow 9am" && reminder?.status == .open)
    }

    @Test("confirmations by title complete or delete the one matching task; an ambiguous title changes nothing")
    func confirmations() {
        let entries = derive([
            obs(1, "$a", .taskAdded(id: "1", owner: nil, title: "Pay rent")),
            obs(2, "$b", .taskAdded(id: "2", owner: nil, title: "Same")),
            obs(3, "$c", .taskAdded(id: "3", owner: nil, title: "Same")),
            obs(4, nil, .taskDone(title: "Pay rent")),
            obs(5, nil, .taskDone(title: "Same")),
            obs(6, nil, .taskDeleted(title: "Nothing like it")),
        ])
        #expect(entries.first { $0.key.id == "1" }?.status == .completed)
        #expect(entries.filter { $0.title == "Same" }.allSatisfy { $0.status == .open })
        let deleted = derive([obs(1, "$a", .taskAdded(id: "1", owner: nil, title: "Gone")), obs(2, nil, .taskDeleted(title: "Gone"))])
        #expect(deleted.first?.status == .deleted)
    }

    @Test("a confirmation by title prefers the one task created in the room over list-only tasks with the same title")
    func createdTaskWins() {
        let entries = derive([
            obs(1, "$l1", .todoList(title: "Tasks", rows: [.init(id: "3", text: "Pay rent", isDone: false)])),
            obs(2, "$a", .taskAdded(id: "7", owner: "Ann", title: "Pay rent")),
            obs(3, "$l2", .todoList(title: "Tasks", rows: [.init(id: "7", text: "Pay rent", isDone: false)])),
            obs(4, nil, .taskDone(title: "Pay rent")),
        ])
        #expect(entries.first { $0.key.id == "7" }?.status == .completed)
        #expect(entries.first { $0.key.id == "3" }?.status == .open)
    }

    @Test("a reused id starts a new open task; the same input always gives the same entries (determinism, AC-A3)")
    func reuseAndDeterminism() {
        let input = [
            obs(1, "$a", .taskAdded(id: "1", owner: nil, title: "First")),
            obs(2, nil, .taskDone(title: "First")),
            obs(3, "$b", .taskAdded(id: "1", owner: nil, title: "Second")),
        ]
        let entries = derive(input)
        #expect(entries.count == 1 && entries[0].status == .open && entries[0].title == "Second" && entries[0].sourceEventID?.rawValue == "$b")
        #expect(derive(input) == derive(input))
        #expect(derive(input + input).count == 1)  // a duplicated message list changes nothing but the order it is read in
    }

    @Test("entries are ordered by room, bot, kind and the number of the task, not as text")
    func ordering() {
        let ids = ["10", "9", "2"]
        let entries = derive(ids.map { obs(1, "$e\($0)", .taskAdded(id: $0, owner: nil, title: "t\($0)")) })
        #expect(entries.map(\.key.id) == ["2", "9", "10"])
    }
}
