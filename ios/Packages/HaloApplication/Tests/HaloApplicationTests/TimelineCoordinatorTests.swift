import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("TimelineCoordinator")
struct TimelineCoordinatorTests {
    private func item(_ id: String, _ body: String) -> TimelineItem {
        TimelineItem(
            id: TimelineItemID(id),
            content: .event(TimelineEvent(
                eventID: nil, sender: nil, senderName: nil, timestamp: Date(timeIntervalSince1970: 0),
                isOwn: false, kind: .text(body, isEdited: false))))
    }

    /// Waits for the first status that satisfies `predicate`, without sleeping.
    private func wait(_ coordinator: TimelineCoordinator, until predicate: @Sendable (TimelineCoordinator.Status) -> Bool) async -> TimelineCoordinator.Status? {
        for await status in await coordinator.statuses() where predicate(status) { return status }
        return nil
    }

    private func items(_ status: TimelineCoordinator.Status?) -> [String] {
        guard case .live(let snapshot) = status else { return [] }
        return TimelinePortContract.bodies(of: snapshot.items)
    }

    @Test("opening shows the room's items and live diffs")
    func opensAndFollows() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [item("1", "one")])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        #expect(items(await wait(coordinator) { if case .live(let s) = $0 { s.items.count == 1 } else { false } }) == ["one"])
        try port.emit(.pushBack(item("2", "two")), in: room)
        #expect(items(await wait(coordinator) { if case .live(let s) = $0 { s.items.count == 2 } else { false } }) == ["one", "two"])
    }

    @Test("an unknown room fails to open with notFound")
    func unknownRoom() async throws {
        let coordinator = TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!nope:x.org"))
        await coordinator.open()
        #expect(await coordinator.status == .failed(.notFound))
    }

    @Test("back pagination loads older events once and then reports the start")
    func pagination() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [item("3", "three")], older: [[item("1", "one"), item("2", "two")]])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        await coordinator.paginateBackwards()
        let done = await wait(coordinator) { if case .live(let s) = $0 { s.reachedStart && s.items.count == 3 } else { false } }
        #expect(items(done) == ["one", "two", "three"])
        await coordinator.paginateBackwards()  // at the start: does nothing
        #expect(port.paginateCalls(in: room) == 1)
    }

    @Test("a diff that doesn't apply triggers a fresh subscription that repairs the list")
    func repairs() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [item("1", "one")])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        _ = await wait(coordinator) { if case .live(let s) = $0 { s.items.count == 1 } else { false } }
        try port.emit(.remove(index: 9), in: room, validate: false)
        try port.emit(.pushBack(item("2", "two")), in: room)
        #expect(items(await wait(coordinator) { if case .live(let s) = $0 { s.items.count == 2 } else { false } }) == ["one", "two"])
    }

    @Test("closing returns to idle and closes the session")
    func closes() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [item("1", "one")])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        await coordinator.close()
        #expect(await coordinator.status == .idle)
        #expect(port.openSessions(in: room) == 0)
    }

    @Test("the timeline-start marker means the start is reached, even if pagination never said so")
    func startMarker() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        let start = TimelineItem(id: TimelineItemID("start"), content: .virtual(.timelineStart))
        port.addRoom(room, items: [start, item("1", "one")])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await coordinator.open()
        let status = await wait(coordinator) { if case .live(let s) = $0 { s.reachedStart } else { false } }
        #expect(status != nil)
        await coordinator.paginateBackwards()
        #expect(port.paginateCalls(in: room) == 0)
    }

    @Test("sending adds a local echo that is confirmed in place; sending into a closed timeline is cancelled")
    func sends() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [item("1", "one")])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await #expect(throws: HaloError.cancelled) { try await coordinator.send("too early") }
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        try await coordinator.send("hello")
        let done = await wait(coordinator) { status in
            guard case .live(let s) = status, s.items.count == 2, case .event(let e) = s.items[1].content else { return false }
            return e.sendState == .sent
        }
        #expect(items(done) == ["one", "hello"])
        await #expect(throws: HaloError.invalidInput("EMPTY_MESSAGE")) { try await coordinator.send("  ") }
    }

    @Test("typing: others' typing shows in the snapshot; our notices are throttled and stopped on false and close")
    func typing() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let clock = Mutex(ContinuousClock.now)
        let coordinator = TimelineCoordinator(port: port, room: room, now: { clock.withLock { $0 } })
        await coordinator.setTyping(true)  // not open yet
        #expect(port.typingCalls(in: room).isEmpty)
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }

        let bob = try UserID("@bob:x.org")
        port.setTypingUsers([bob], in: room)
        let shown = await wait(coordinator) { if case .live(let s) = $0 { s.typing == [bob] } else { false } }
        #expect(shown != nil)

        await coordinator.setTyping(true)
        await coordinator.setTyping(true)  // within 4 s: dropped
        clock.withLock { $0 += .seconds(5) }
        await coordinator.setTyping(true)
        await coordinator.setTyping(false)
        await coordinator.setTyping(false)  // already stopped: dropped
        #expect(port.typingCalls(in: room) == [true, true, false])

        await coordinator.setTyping(true)
        await coordinator.close()
        #expect(port.typingCalls(in: room) == [true, true, false, true, false])
    }

    @Test("reaction, edit and delete go through the open timeline and refuse when it is closed")
    func interactions() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let coordinator = TimelineCoordinator(port: port, room: room)
        let someEvent = try EventID("$e")
        await #expect(throws: HaloError.cancelled) { try await coordinator.toggleReaction(on: someEvent, key: "👍") }
        await #expect(throws: HaloError.cancelled) { try await coordinator.edit(event: someEvent, newText: "x") }
        await #expect(throws: HaloError.cancelled) { try await coordinator.delete(event: someEvent) }
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        await #expect(throws: HaloError.notFound) { try await coordinator.delete(event: someEvent) }  // unknown event
    }

    @Test("a failed echo can be retried or deleted; both refuse when closed or when the echo is gone")
    func failedEchoes() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        func failed(_ n: Int) -> TimelineItem {
            TimelineItem(id: TimelineItemID("l\(n)"), content: .event(TimelineEvent(
                eventID: nil, sender: nil, senderName: nil, timestamp: Date(timeIntervalSince1970: Double(n)), isOwn: true,
                kind: .text("m\(n)", isEdited: false), sendState: .failed(recoverable: false), localID: "txn\(n)")))
        }
        port.addRoom(room, items: [failed(1), failed(2)])
        let coordinator = TimelineCoordinator(port: port, room: room)
        await #expect(throws: HaloError.cancelled) { try await coordinator.retrySend(localID: "txn1") }
        await #expect(throws: HaloError.cancelled) { try await coordinator.abortSend(localID: "txn1") }
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        try await coordinator.retrySend(localID: "txn1")
        #expect(port.retried(in: room) == ["txn1"])
        try await coordinator.abortSend(localID: "txn2")
        await #expect(throws: HaloError.notFound) { try await coordinator.abortSend(localID: "txn2") }
        await #expect(throws: HaloError.notFound) { try await coordinator.retrySend(localID: "txn1") }  // sent meanwhile
    }

    @Test("a sticker goes through the open timeline; it refuses when closed and passes errors on")
    func stickers() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room)
        let coordinator = TimelineCoordinator(port: port, room: room)
        let sticker = Sticker(pack: PackRef(room: room, stateKey: "p"), shortcode: "wave", body: nil, url: "mxc://x.org/w", info: nil)
        await #expect(throws: HaloError.cancelled) { try await coordinator.sendSticker(sticker) }
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        try await coordinator.sendSticker(sticker)
        #expect(port.sentStickers(in: room) == [sticker])
        port.failNextSticker(with: .network(retryable: true), in: room)
        await #expect(throws: HaloError.network(retryable: true)) { try await coordinator.sendSticker(sticker) }
    }

    @Test("opening with threadRoot calls openThread with the root event ID (M10 Threads)")
    func opensThread() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        let root = try EventID("$root1")
        port.addRoom(room)
        let coordinator = TimelineCoordinator(port: port, room: room, threadRoot: root)
        await coordinator.open()
        _ = await wait(coordinator) { if case .live = $0 { true } else { false } }
        #expect(port.openedThreads(in: room) == [root])
    }
}
