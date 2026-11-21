import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@testable import HaloApplication

@Suite("BotActivityCoordinator")
struct BotActivityCoordinatorTests {
    let room = try! RoomID("!r:x.org")
    let bot = "@bot:x.org"

    func message(_ id: String, sender: String, html: String?, at: TimeInterval) throws -> TimelineItem {
        TimelineItem(id: TimelineItemID(id), content: .event(TimelineEvent(
            eventID: try EventID("$\(id)"), sender: try UserID(sender), senderName: nil, timestamp: Date(timeIntervalSince1970: at), isOwn: false,
            kind: .text("x", isEdited: false), formattedBody: html)))
    }

    let added = "Added Task <b>#7</b> for me: <i>\"Buy milk\"</i>"

    @Test("only allowlisted bots' recognised messages are indexed; nothing is read without an allowlist")
    func indexesKnownBots() async throws {
        let port = FakeBotTaskPort()
        let coordinator = BotActivityCoordinator(port: port)
        let items = [
            try message("a", sender: bot, html: added, at: 1),
            try message("b", sender: "@human:x.org", html: added, at: 2),
            try message("c", sender: bot, html: "hello <b>there</b>", at: 3),
        ]
        await coordinator.observe(room: room, items: items, botSenders: [])
        #expect(port.upsertCalls == 0)
        await coordinator.observe(room: room, items: items, botSenders: [bot])
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.entries.count == 1 && snapshot.entries[0].title == "Buy milk" && snapshot.entries[0].sourceEventID?.rawValue == "$a")
    }

    @Test("an unchanged timeline writes once; a change writes again; a failed write is retried by the next snapshot")
    func writesOnlyChanges() async throws {
        let port = FakeBotTaskPort()
        let coordinator = BotActivityCoordinator(port: port)
        let first = [try message("a", sender: bot, html: added, at: 1)]
        await coordinator.observe(room: room, items: first, botSenders: [bot])
        await coordinator.observe(room: room, items: first, botSenders: [bot])
        #expect(port.upsertCalls == 1)
        let more = first + [try message("d", sender: bot, html: "✅ Marked task as done: <i>\"Buy milk\"</i>", at: 5)]
        port.fail(with: .storage(.corrupted))
        await coordinator.observe(room: room, items: more, botSenders: [bot])
        port.fail(with: nil)
        await coordinator.observe(room: room, items: more, botSenders: [bot])
        #expect(await coordinator.snapshot().entries.first?.status == .completed)
    }

    @Test("rebuild empties the index and lets the same timeline fill it again; an unreadable index is reported")
    func rebuildAndFailure() async throws {
        let port = FakeBotTaskPort()
        let coordinator = BotActivityCoordinator(port: port)
        let items = [try message("a", sender: bot, html: added, at: 1)]
        await coordinator.observe(room: room, items: items, botSenders: [bot])
        await coordinator.rebuild()
        #expect(await coordinator.snapshot().entries.isEmpty)
        await coordinator.observe(room: room, items: items, botSenders: [bot])
        #expect(await coordinator.snapshot().entries.count == 1)
        port.fail(with: .storage(.corrupted))
        #expect(await coordinator.snapshot().failed)
    }
}
