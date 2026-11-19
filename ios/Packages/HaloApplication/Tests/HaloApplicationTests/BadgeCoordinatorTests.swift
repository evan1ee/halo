import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("BadgeCoordinator")
struct BadgeCoordinatorTests {
    private func summary(_ id: String, unread: Int, mode: NotificationMode = .allMessages, membership: Membership = .joined) throws -> RoomSummary {
        RoomSummary(
            id: try RoomID(id), name: id, isDirect: false, isEncrypted: false, membership: membership,
            read: RoomReadCounts(mode: mode, server: ServerCounts(notification: unread, highlight: 0), sdk: .zero, isMarkedUnread: false))
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500_000 { if condition() { return true }; await Task.yield() }
        return false
    }

    @Test("the badge follows the rooms that need attention and is recomputed, not counted up or down")
    func follows() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, port: port)
        await badge.begin()
        await coordinator.start()

        let a = try summary("!a:x.org", unread: 2)
        let b = try summary("!b:x.org", unread: 0)
        let c = try summary("!c:x.org", unread: 1, mode: .mute)  // muted: no attention
        try rooms.emit(.reset([a, b, c]))
        #expect(await eventually { port.badge == 1 })

        try rooms.emit(.set(index: 1, try summary("!b:x.org", unread: 4)))
        #expect(await eventually { port.badge == 2 })
        // Reading elsewhere: the server count drops to zero and the badge falls again.
        try rooms.emit(.set(index: 0, try summary("!a:x.org", unread: 0)))
        #expect(await eventually { port.badge == 1 })
        #expect(port.history.last == [try RoomID("!b:x.org")])
        #expect(await badge.badge == 1)
    }

    @Test("the first evaluation writes even an empty set, so a badge the extension added is cleared")
    func firstWriteClears() async throws {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, port: port)
        await badge.begin()
        await coordinator.start()
        try rooms.emit(.reset([try summary("!a:x.org", unread: 0)]))
        #expect(await eventually { !port.history.isEmpty })
        #expect(port.history == [[]])
    }
}
