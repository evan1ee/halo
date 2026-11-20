import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("RoomListCoordinator", .timeLimit(.minutes(1)))
struct RoomListCoordinatorTests {
    @Test("with loadsAllPages, each page that adds rooms asks for the next, and an empty page ends the loop")
    func loadsAllPages() async throws {
        let port = FakeRoomListPort(rooms: [room(1), room(2)])
        let coordinator = RoomListCoordinator(port: port, loadsAllPages: true)
        let statuses = await coordinator.statuses()
        await coordinator.start()
        #expect(await first(statuses) { $0 == .loaded(roomCount: 2) } != nil)
        for _ in 0..<200_000 where port.loadMoreCalls < 1 { await Task.yield() }
        #expect(port.loadMoreCalls == 1)
        try port.emit(.append([room(3)]))
        #expect(await first(statuses) { $0 == .loaded(roomCount: 3) } != nil)
        for _ in 0..<200_000 where port.loadMoreCalls < 2 { await Task.yield() }
        #expect(port.loadMoreCalls == 2)  // no diff came back from page 2, so no page 3 is requested
        for _ in 0..<1000 { await Task.yield() }
        #expect(port.loadMoreCalls == 2)
    }

    @Test("a change that leaves the read inputs alone (a favourite, a rename) still reaches the summary stream")
    func summaryChanges() async throws {
        let port = FakeRoomListPort(rooms: [room(1)])
        let coordinator = RoomListCoordinator(port: port)
        let summaries = await coordinator.summaryChanges()
        await coordinator.start()
        #expect(await first(summaries) { $0.count == 1 && !$0[0].isFavourite } != nil)
        let original = room(1)
        let favourite = RoomSummary(
            id: original.id, name: original.name, isDirect: original.isDirect, isEncrypted: original.isEncrypted, membership: original.membership,
            read: original.read, latestEvent: original.latestEvent, ownReadThrough: original.ownReadThrough, isFavourite: true)
        try port.emit(.set(index: 0, favourite))
        #expect(await first(summaries) { $0.first?.isFavourite == true } != nil)
    }

    @Test("sticker pack rooms are left out of the list and the read inputs, also when they become known after the list")
    func hidesPackRooms() async throws {
        let port = FakeRoomListPort(rooms: [room(1), room(2), room(3)])
        let hidden = FakeHiddenRooms([room(2).id])
        let coordinator = RoomListCoordinator(port: port, hiddenRooms: hidden)
        let statuses = await coordinator.statuses()
        let inputs = await coordinator.readInputs()
        await coordinator.start()
        #expect(await first(statuses) { $0 == .loaded(roomCount: 2) } != nil)
        #expect(await coordinator.rooms.map(\.id) == [room(1).id, room(3).id])
        #expect(await first(inputs) { $0.map(\.roomID) == [room(1).id, room(3).id] } != nil)
        // A new pack room appears in the account data; the next change of the list picks it up.
        hidden.set([room(2).id, room(3).id])
        try port.emit(.pushBack(room(4)))
        #expect(await first(statuses) { $0 == .loaded(roomCount: 2) } != nil)  // rooms 1 and 4
        #expect(await coordinator.rooms.map(\.id) == [room(1).id, room(4).id])
        // A pack room that is un-hidden returns.
        hidden.set([])
        try port.emit(.pushBack(room(5)))
        #expect(await first(statuses) { $0 == .loaded(roomCount: 5) } != nil)
    }

    @Test("publishes the room count as diffs arrive (M0 exit signal)")
    func roomCount() async throws {
        let port = FakeRoomListPort(rooms: [room(1), room(2)])
        let coordinator = RoomListCoordinator(port: port)
        let statuses = await coordinator.statuses()
        await coordinator.start()
        #expect(await first(statuses) { $0 == .loaded(roomCount: 2) } != nil)
        try port.emit(.pushBack(room(3)))
        try port.emit(.append([room(4), room(5)]))
        #expect(await first(statuses) { $0 == .loaded(roomCount: 5) } != nil)
        try port.emit(.remove(index: 0))
        #expect(await first(statuses) { $0 == .loaded(roomCount: 4) } != nil)
        #expect(await coordinator.rooms.map(\.id) == [room(2), room(3), room(4), room(5)].map(\.id))
    }

    @Test("a diff that doesn't apply triggers a fresh subscription that repairs the list")
    func resubscribes() async throws {
        let port = FakeRoomListPort(rooms: [room(1)])
        let coordinator = RoomListCoordinator(port: port)
        let statuses = await coordinator.statuses()
        await coordinator.start()
        _ = await first(statuses) { $0 == .loaded(roomCount: 1) }
        try port.emit(.remove(index: 5), validate: false)
        // Status goes loading → loaded(1); with latest-wins delivery only the final value is certain.
        _ = await first(statuses) { $0 == .loaded(roomCount: 1) }
        #expect(port.subscriptionCount == 2)
        #expect(await coordinator.rooms.map(\.id) == [room(1).id])
    }

    @Test("gives up after repeated failures, even though every fresh start applies")
    func givesUp() async throws {
        let port = FakeRoomListPort(rooms: [])
        let coordinator = RoomListCoordinator(port: port)
        let statuses = await coordinator.statuses()
        await coordinator.start()
        for _ in 0...RoomListCoordinator.maximumResubscriptions {
            _ = await first(statuses) { $0 == .loaded(roomCount: 0) }
            try port.emit(.popFront, validate: false)
        }
        let status = await first(statuses) { if case .failed = $0 { true } else { false } }
        #expect(status == .failed(.internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE")))
        #expect(port.subscriptionCount == RoomListCoordinator.maximumResubscriptions + 1)
    }

    @Test("stop ends the subscription and later diffs are ignored")
    func stop() async throws {
        let port = FakeRoomListPort(rooms: [room(1)])
        let coordinator = RoomListCoordinator(port: port)
        let statuses = await coordinator.statuses()
        await coordinator.start()
        _ = await first(statuses) { $0 == .loaded(roomCount: 1) }
        await coordinator.stop()
        try port.emit(.pushBack(room(2)))
        #expect(await coordinator.status == .idle)
        #expect(await coordinator.rooms.count == 1)
    }
}
