import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import FeatureTimeline

/// A timeline started before its screen (M19-9, D-MOT-2): rows are ready for the first frame, and nothing about what was read
/// leaves the device until the screen is shown (READ_RECEIPTS §1, UNREAD_STATE).
@MainActor
@Suite("Warm timelines")
struct WarmTimelinesTests {
    private func message(_ n: Int, own: Bool = false) throws -> TimelineItem {
        TimelineItem(id: TimelineItemID("i\(n)"), content: .event(TimelineEvent(
            eventID: try EventID("$e\(n)"), sender: own ? nil : try UserID("@bob:x.org"), senderName: "Bob",
            timestamp: Date(timeIntervalSince1970: Double(n)), isOwn: own, kind: .text("m\(n)", isEdited: false))))
    }

    private func rows(_ model: TimelineViewModel) -> [TimelineRow] {
        if case .live(let rows, _, _, _) = model.content { rows } else { [] }
    }

    @Test("started ahead, a model has its rows but sends no receipt, no own read, no marked-unread clearing, no draft or typing; shown, it does", .timeLimit(.minutes(1)))
    func reportsNothingUntilShown() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try message(1), try message(2), try message(3, own: true)])
        let markers = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: markers)
        try await receipts.markRoomUnread(room)
        let store = FakeDrafts([room: "half written"])
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), receipts: receipts, room: room,
            drafts: DraftCoordinator(store: store), dwell: .zero, sleep: { _ in })

        await model.startAhead()
        while rows(model).count < 3 { await Task.yield() }
        #expect(!model.isPresented && model.landed)
        #expect(model.draft == "half written")
        // Even rows reported as on screen (they can't be, but nothing may slip through) and an active app report nothing.
        model.setActive(true)
        for row in rows(model) { model.rowVisibility(row, isVisible: true) }
        for _ in 0..<5_000 { await Task.yield() }
        #expect(markers.receipts.isEmpty, "no read receipt and no own message as read while not shown")
        #expect(markers.unreadFlags[room] == true, "m.marked_unread stays until the room is shown")
        #expect(port.typingCalls(in: room).isEmpty)
        #expect(store.stored[room] == "half written")

        var presented = 0
        model.onPresented = { presented += 1 }
        model.present()
        model.present()  // a second appearance changes nothing
        #expect(presented == 1 && model.isPresented)
        #expect(model.landingRow == model.lastRowID, "lands at the newest row now (D95)")
        for _ in 0..<200_000 where markers.receipts.isEmpty || markers.unreadFlags[room] == true { await Task.yield() }
        #expect(markers.unreadFlags[room] == false)
        #expect(markers.receipts.map(\.event.rawValue).last == "$e3")
        #expect(port.typingCalls(in: room).isEmpty, "restoring the draft is no typing")
        await model.stop()
    }

    @Test("shown later, a model started ahead lands at the newest row and marks what is unread by the read position of that moment", .timeLimit(.minutes(1)))
    func landsAtNewestWhenShown() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try message(1), try message(2)])
        let position = Mutex<Date?>(Date(timeIntervalSince1970: 2))
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), room: room,
            readThrough: { position.withLock { $0 } }, dwell: .zero, sleep: { _ in })
        await model.startAhead()
        while rows(model).count < 2 { await Task.yield() }
        #expect(model.unreadMarkerID == nil, "everything was read when it started")
        // Meanwhile a message arrives and the read position moves back (read on another device up to message 1 only).
        try port.emit(.append([try message(4)]), in: room)
        while model.lastRowID != "i4" { await Task.yield() }
        position.withLock { $0 = Date(timeIntervalSince1970: 1) }

        model.present()
        #expect(model.landingRow == "i4" && model.isAtBottom)
        for _ in 0..<200_000 where model.unreadMarkerID == nil { await Task.yield() }
        #expect(model.unreadMarkerID == "i2")
        await model.stop()
    }

    @Test("a model started the usual way is shown from the start: present() changes nothing")
    func usualStartIsPresented() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try message(1)])
        let model = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), room: room)
        var presented = false
        model.onPresented = { presented = true }
        await model.start()
        model.present()
        #expect(model.isPresented && !presented)
        await model.stop()
    }

    @Test("the cache keeps at most its limit for the top rooms, hands the same model until it is shown, and never prepares a room on screen again", .timeLimit(.minutes(1)))
    func cacheFollowsTheTop() async throws {
        let ids = try (1...5).map { try RoomID("!r\($0):x.org") }
        let port = FakeTimelinePort()
        for id in ids { port.addRoom(id, items: [try message(1)]) }
        let cache = WarmTimelines(limit: 3, refillDelay: .zero) { TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: $0), room: $0) }
        func settle(_ done: () -> Bool) async { for _ in 0..<200_000 where !done() { await Task.yield() } }
        func opened() -> Set<RoomID> { Set(ids.filter { port.openSessions(in: $0) > 0 }) }

        cache.setTop(ids)
        await settle { opened() == Set(ids.prefix(3)) }
        #expect(cache.waitingRooms == Set(ids.prefix(3)))
        #expect(opened() == Set(ids.prefix(3)), "three timelines, not five")

        // A screen built twice gets the same model; it leaves the cache once shown.
        let first = try #require(cache.take(ids[0]))
        #expect(cache.take(ids[0]) === first)
        cache.screensChanged([ids[0]])
        first.present()
        #expect(cache.take(ids[0]) == nil)
        await settle { cache.waitingRooms == Set([ids[1], ids[2], ids[3]]) }
        #expect(cache.waitingRooms == Set([ids[1], ids[2], ids[3]]), "the next room takes the free place")
        #expect(port.openSessions(in: ids[0]) == 1, "the room on screen isn't prepared again behind it")

        // Closed, it is prepared again; the room that falls out of the top lets go of its timeline.
        await first.stop()
        cache.screensChanged([])
        await settle { cache.waitingRooms == Set(ids.prefix(3)) && port.openSessions(in: ids[3]) == 0 }
        #expect(cache.waitingRooms == Set(ids.prefix(3)))
        #expect(port.openSessions(in: ids[3]) == 0)

        // A room opened at a message uses a model of its own; the waiting one is replaced when that screen closes.
        let stale = try #require(cache.take(ids[1]))
        cache.screensChanged([ids[1]])
        cache.screensChanged([])
        await settle { cache.take(ids[1]).map { $0 !== stale } ?? false }
        #expect(cache.take(ids[1]) !== stale)
        await settle { port.openSessions(in: ids[1]) == 1 }
        #expect(port.openSessions(in: ids[1]) == 1, "the replaced model closed its timeline")

        // Sign-out and memory pressure let go of everything.
        cache.dropAll()
        #expect(cache.waitingRooms.isEmpty)
        await settle { opened().isEmpty }
        #expect(opened().isEmpty)
    }

    @Test("a screen appearing before or while its model starts ahead: the start is awaited, the timeline opens once, and the shown model reports", .timeLimit(.minutes(1)))
    func screenDuringTheStartAhead() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try message(1), try message(2, own: true)])
        let markers = FakeReadMarkerPort()
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room), receipts: ReadReceiptCoordinator(port: markers), room: room, dwell: .zero, sleep: { _ in })
        // The screen appears, then its start and the cache's start ahead run at the same time.
        model.present()
        async let screenStart: Void = model.start()
        async let aheadStart: Void = model.startAhead()
        _ = await (screenStart, aheadStart)
        #expect(model.isPresented, "a start ahead after the screen appeared doesn't hide it")
        for _ in 0..<200_000 where markers.receipts.isEmpty { await Task.yield() }
        #expect(markers.receipts.map(\.event.rawValue) == ["$e2"], "the shown model reports the own message")
        for _ in 0..<2_000 { await Task.yield() }
        #expect(port.totalOpens(in: room) == 1, "opened once")
        await model.stop()
    }
}
