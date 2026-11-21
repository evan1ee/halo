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
}
