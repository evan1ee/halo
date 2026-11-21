import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@testable import HaloApplication

@Suite("BotActionCoordinator")
struct BotActionCoordinatorTests {
    let room = try! RoomID("!r:x.org")
    let bot = try! UserID("@bot:x.org")
    let added = "Added Task <b>#7</b> for me: <i>\"Buy milk\"</i>"

    func message(_ id: String, html: String, at: TimeInterval) throws -> TimelineItem {
        TimelineItem(id: TimelineItemID(id), content: .event(TimelineEvent(
            eventID: try EventID("$\(id)"), sender: bot, senderName: nil, timestamp: Date(timeIntervalSince1970: at), isOwn: false,
            kind: .text("x", isEdited: false), formattedBody: html)))
    }

    /// A timeline holding the bot's "Added Task #7", its index already filled by an earlier visit.
    func setUp(timeout: Duration = .seconds(3600), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws
        -> (BotActionCoordinator, FakeTimelinePort, BotActivityCoordinator, BotTaskEntry)
    {
        let port = FakeTimelinePort()
        let item = try message("a", html: added, at: 10)
        port.addRoom(room, items: [item])
        let activity = BotActivityCoordinator(port: FakeBotTaskPort())
        await activity.observe(room: room, items: [item], botSenders: [bot.rawValue])
        let entry = try #require(await activity.snapshot().entries.first)
        let coordinator = BotActionCoordinator(port: port, activity: activity, botSenders: { [bot.rawValue] }, timeout: timeout, sleep: sleep)
        return (coordinator, port, activity, entry)
    }

    @Test("a tick sends one 👍 on the creating message, waits, and completes when the bot confirms in the room")
    func confirmed() async throws {
        let (coordinator, port, activity, entry) = try await setUp()
        let states = await coordinator.stateChanges()
        let ticking = Task { await coordinator.tick(entry) }
        var sawPending = false
        for await state in states where state[entry.key] == .pending { sawPending = true; break }
        #expect(sawPending)
        // The bot answers in the room: the open timeline sees it and the index completes the task.
        try port.emit(.append([try message("d", html: "✅ Marked task as done: <i>\"Buy milk\"</i>", at: 20)]), in: room)
        await ticking.value
        #expect(await activity.snapshot().entries.first?.status == .completed)
        for await state in states { #expect(state[entry.key] == nil); break }
    }

    @Test("without an answer the tick ends as noResponse; a second tap retries without a second 👍")
    func noResponseAndRetry() async throws {
        let (coordinator, _, _, entry) = try await setUp(timeout: .zero, sleep: { _ in })
        await coordinator.tick(entry)
        var last: [BotTaskEntry.Key: BotActionCoordinator.State] = [:]
        for await state in await coordinator.stateChanges() { last = state; break }
        #expect(last[entry.key] == .noResponse)
        await coordinator.tick(entry)  // allowed again, and idempotent on the server side
        for await state in await coordinator.stateChanges() { last = state; break }
        #expect(last[entry.key] == .noResponse)
    }

    @Test("reminders, completed tasks and tasks without a source message are never ticked")
    func notTickable() async throws {
        let (coordinator, _, _, entry) = try await setUp(timeout: .zero, sleep: { _ in })
        var reminder = entry
        reminder = BotTaskEntry(key: .init(room: room, bot: entry.key.bot, kind: .reminder, id: "9"), title: "r", status: .open, sourceEventID: entry.sourceEventID, asOf: entry.asOf)
        var done = entry; done.status = .completed
        var noSource = entry; noSource.sourceEventID = nil
        for candidate in [reminder, done, noSource] { await coordinator.tick(candidate) }
        for await state in await coordinator.stateChanges() { #expect(state.isEmpty); break }
    }
}
