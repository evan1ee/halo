import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
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
}
