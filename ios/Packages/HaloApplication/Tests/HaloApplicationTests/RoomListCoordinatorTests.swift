import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("RoomListCoordinator", .timeLimit(.minutes(1)))
struct RoomListCoordinatorTests {
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
