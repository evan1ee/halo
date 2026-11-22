import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@testable import FeatureBotActivity

@MainActor
@Suite("BotActivityViewModel")
struct BotActivityViewModelTests {
    let r1 = try! RoomID("!one:x.org"), r2 = try! RoomID("!two:x.org")
    let now = Date(timeIntervalSince1970: 1_000_000)

    func entry(_ room: RoomID, bot: String = "@todo:x.org", kind: BotTaskEntry.Kind = .todo, id: String, title: String?, status: BotTaskEntry.Status = .open, age: TimeInterval = 60) -> BotTaskEntry {
        BotTaskEntry(key: .init(room: room, bot: bot, kind: kind, id: id), title: title, status: status, sourceEventID: try? EventID("$\(id)"), asOf: now.addingTimeInterval(-age))
    }

    func model(_ entries: [BotTaskEntry]) async throws -> (BotActivityViewModel, FakeBotTaskPort) {
        let port = FakeBotTaskPort()
        try await port.upsert(entries)
        let vm = BotActivityViewModel(
            coordinator: BotActivityCoordinator(port: port), roomName: { $0 == self.r1 ? "Home" : nil }, now: { self.now })
        await vm.load()
        return (vm, port)
    }

    @Test("sections: open tasks, reminders, completed within a week; deleted and old completions are hidden")
    func sections() async throws {
        let (vm, _) = try await model([
            entry(r1, id: "1", title: "Buy milk"),
            entry(r1, kind: .reminder, id: "2", title: "Call mum"),
            entry(r1, id: "3", title: "Done recently", status: .completed, age: 3600),
            entry(r1, id: "4", title: "Done long ago", status: .completed, age: 8 * 24 * 3600),
            entry(r1, id: "5", title: "Gone", status: .deleted),
        ])
        let s = vm.sections
        #expect(s.open.map(\.title) == ["Buy milk"] && s.reminders.map(\.title) == ["Call mum"] && s.completed.map(\.title) == ["Done recently"])
        #expect(s.open[0].roomName == "Home" && s.open[0].botName == "todo" && s.open[0].sourceEventID?.rawValue == "$1")
    }

    @Test("filters narrow by room and by bot; a task seen only in a list has a placeholder title and an unknown room is named so")
    func filters() async throws {
        let (vm, _) = try await model([
            entry(r1, id: "1", title: "A"), entry(r2, id: "2", title: nil), entry(r2, bot: "@other:x.org", id: "3", title: "C"),
        ])
        #expect(vm.sections.open.count == 3 && vm.roomChoices.map(\.name) == ["Home", "Unknown room"] && vm.botChoices == ["@other:x.org", "@todo:x.org"])
        vm.roomFilter = r2
        #expect(vm.sections.open.map(\.title).sorted() == ["C", "Task #2"] && vm.sections.open[0].roomName == "Unknown room")
        vm.botFilter = "@other:x.org"
        #expect(vm.sections.open.map(\.title) == ["C"])
    }

    @Test("rebuild empties the index and the filters; an unreadable index shows as failed")
    func rebuildAndFailure() async throws {
        let (vm, port) = try await model([entry(r1, id: "1", title: "A")])
        vm.roomFilter = r1
        await vm.rebuild()
        #expect(vm.sections.isEmpty && vm.roomFilter == nil && vm.phase == .loaded)
        port.fail(with: .storage(.corrupted))
        await vm.load()
        #expect(vm.phase == .failed)
    }

    @Test("only open tasks with a source message are tickable, and only when ticking is available")
    func tickable() async throws {
        let withoutSource = BotTaskEntry(key: .init(room: r1, bot: "@todo:x.org", kind: .todo, id: "9"), title: "x", status: .open, sourceEventID: nil, asOf: now)
        let (plain, _) = try await model([entry(r1, id: "1", title: "A")])
        #expect(plain.sections.open.allSatisfy { !$0.canTick })  // no actions coordinator
        let port = FakeBotTaskPort()
        try await port.upsert([entry(r1, id: "1", title: "A"), entry(r1, kind: .reminder, id: "2", title: "R"), withoutSource])
        let activity = BotActivityCoordinator(port: port)
        let vm = BotActivityViewModel(
            coordinator: activity,
            actions: BotActionCoordinator(port: FakeTimelinePort(), activity: activity, botSenders: { [] }), roomName: { _ in "Home" }, now: { self.now })
        await vm.load()
        #expect(vm.sections.open.first { $0.key.id == "1" }?.canTick == true)
        #expect(vm.sections.open.first { $0.key.id == "9" }?.canTick == false)
        #expect(vm.sections.reminders.allSatisfy { !$0.canTick })
        var deleted = entry(r1, id: "5", title: "Deleted source")
        deleted.sourceRedacted = true
        try await port.upsert([deleted])
        await vm.load()
        let item = try #require(vm.sections.open.first { $0.key.id == "5" })
        #expect(!item.canTick && item.sourceDeleted && item.sourceEventID == nil)
    }

    @Test("ticking sends the reaction, shows pending, and the list reloads as completed once the bot confirms in the room")
    func ticking() async throws {
        let bot = try UserID("@bot:x.org")
        func message(_ id: String, _ html: String, _ ts: TimeInterval) throws -> TimelineItem {
            TimelineItem(id: TimelineItemID(id), content: .event(TimelineEvent(
                eventID: try EventID("$\(id)"), sender: bot, senderName: nil, timestamp: Date(timeIntervalSince1970: ts), isOwn: false,
                kind: .text("x", isEdited: false), formattedBody: html)))
        }
        let timeline = FakeTimelinePort()
        let added = try message("a", "Added Task <b>#7</b> for me: <i>\"Buy milk\"</i>", 10)
        timeline.addRoom(r1, items: [added])
        let activity = BotActivityCoordinator(port: FakeBotTaskPort(), now: { Date(timeIntervalSince1970: 11) })
        await activity.observe(room: r1, items: [added], botSenders: [bot.rawValue])
        let vm = BotActivityViewModel(
            coordinator: activity,
            actions: BotActionCoordinator(port: timeline, activity: activity, botSenders: { [bot.rawValue] }), roomName: { _ in "Home" },
            now: { Date(timeIntervalSince1970: 100) })
        await vm.load()
        let observing = Task { await vm.observeActions() }
        let item = try #require(vm.sections.open.first)
        #expect(item.canTick && item.tickState == nil)
        let ticking = Task { await vm.tick(item) }
        for _ in 0..<500_000 where vm.actionStates.isEmpty { await Task.yield() }
        #expect(vm.actionStates.values.first == .pending && vm.sections.open.first?.tickState == .pending)
        try timeline.emit(.append([try message("d", "✅ Marked task as done: <i>\"Buy milk\"</i>", 20)]), in: r1)
        await ticking.value
        observing.cancel()
        #expect(vm.sections.open.isEmpty && vm.sections.completed.map(\.title) == ["Buy milk"])
    }
}
