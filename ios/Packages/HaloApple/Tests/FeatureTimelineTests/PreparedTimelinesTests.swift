import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import FeatureTimeline

/// A timeline started before its screen (M19-9, D-MOT-2): the tapped room's rows are ready for the first frame, and nothing about
/// what was read leaves the device until the screen is shown (READ_RECEIPTS §1, UNREAD_STATE).
@MainActor
@Suite("Prepared timelines")
struct PreparedTimelinesTests {
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

    @Test("a room on screen isn't prepared again; a screen that closed without showing the waiting model lets it go; dropAll lets go", .timeLimit(.minutes(1)))
    func holderLifecycle() async throws {
        let open = try RoomID("!open:x.org"), next = try RoomID("!next:x.org")
        let port = FakeTimelinePort()
        port.addRoom(open, items: [try message(1)])
        port.addRoom(next, items: [try message(1)])
        let holder = PreparedTimelines(wait: { _ in }) { TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: $0), room: $0) }
        func settle(_ done: () -> Bool) async { for _ in 0..<200_000 where !done() { await Task.yield() } }

        holder.screensChanged([open])
        await holder.prepare(open)
        #expect(holder.waitingRoom == nil && port.totalOpens(in: open) == 0, "an open room isn't prepared again behind its screen")

        // Pushed, but the screen used a model of its own (opened at a message) and closed: the waiting model goes.
        await holder.prepare(next)
        await settle { port.openSessions(in: next) == 1 }
        holder.screensChanged([open, next])
        #expect(holder.take(next) != nil, "a screen built twice gets the same model")
        holder.screensChanged([open])
        #expect(holder.waitingRoom == nil)
        await settle { port.openSessions(in: next) == 0 }
        #expect(port.openSessions(in: next) == 0)

        // Sign-out and memory pressure let go of a waiting model.
        holder.screensChanged([])
        await holder.prepare(open)
        #expect(holder.waitingRoom == open)
        holder.dropAll()
        #expect(holder.waitingRoom == nil)
        await settle { port.openSessions(in: open) == 0 }
        #expect(port.openSessions(in: open) == 0)
    }

    @Test("a tapped room is prepared before its screen: prepare returns once it has landed, the screen takes that model, and nothing is reported until it is shown", .timeLimit(.minutes(1)))
    func preparedOnTap() async throws {
        let room = try RoomID("!r:x.org")
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try message(1), try message(2, own: true)])
        let markers = FakeReadMarkerPort()
        let receipts = ReadReceiptCoordinator(port: markers)
        // The time limit never runs out here: prepare must return because the rows are there.
        let (never, end) = AsyncStream.makeStream(of: Void.self)
        defer { end.finish() }
        let cache = PreparedTimelines(wait: { _ in for await _ in never { return } }) {
            TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: $0), receipts: receipts, room: $0, dwell: .zero, sleep: { _ in })
        }
        await cache.prepare(room)
        let model = try #require(cache.take(room))
        #expect(model.landed && model.canShow && model.lastRowID == "i2", "the screen pushed now has its rows on the first frame")
        #expect(!model.isPresented)
        for _ in 0..<5_000 { await Task.yield() }
        #expect(markers.receipts.isEmpty, "nothing is reported before the screen shows the room")
        cache.screensChanged([room])
        model.present()
        #expect(cache.take(room) == nil && cache.waitingRoom == nil, "shown, the model belongs to its screen")
        for _ in 0..<200_000 where markers.receipts.isEmpty { await Task.yield() }
        #expect(markers.receipts.map(\.event.rawValue) == ["$e2"])
        #expect(port.totalOpens(in: room) == 1, "opened once: the screen's start waits for the one under way")
        await model.stop()
    }

    @Test("prepare gives up after its time limit when the rows don't come; a newer choice lets go of the older one", .timeLimit(.minutes(1)))
    func prepareIsBoundedAndReplaced() async throws {
        let slow = try RoomID("!slow:x.org"), other = try RoomID("!other:x.org")
        let port = FakeTimelinePort()
        port.addRoom(slow)  // nothing to land on: its rows never come
        port.addRoom(other, items: [try message(1)])
        let (limits, release) = AsyncStream.makeStream(of: Void.self)
        let cache = PreparedTimelines(wait: { _ in for await _ in limits { return } }) {
            TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: $0), room: $0)
        }
        var returned = false
        let opening = Task { await cache.prepare(slow); returned = true }
        for _ in 0..<5_000 { await Task.yield() }
        #expect(!returned, "still waiting for rows")
        release.yield()
        await opening.value
        #expect(returned, "the time limit ends the wait")
        #expect(cache.take(slow)?.canShow == false, "pushed without rows, the screen shows them when they come")

        // Another room is chosen before the first was pushed: the first lets go of its timeline.
        await cache.prepare(other)
        cache.abandon(slow)  // the older tap's task ends cancelled: this does nothing to the newer one
        #expect(cache.waitingRoom == other)
        for _ in 0..<200_000 where port.openSessions(in: slow) > 0 { await Task.yield() }
        #expect(port.openSessions(in: slow) == 0)
        cache.abandon(other)
        #expect(cache.waitingRoom == nil)
        for _ in 0..<200_000 where port.openSessions(in: other) > 0 { await Task.yield() }
        #expect(port.openSessions(in: other) == 0, "an abandoned choice closes its timeline")
        release.finish()
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
