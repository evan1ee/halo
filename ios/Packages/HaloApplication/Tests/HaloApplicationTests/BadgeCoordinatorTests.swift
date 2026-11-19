import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("BadgeCoordinator")
struct BadgeCoordinatorTests {
    private func summary(_ id: String, notify: Int = 0, mode: NotificationMode = .allMessages, membership: Membership = .joined) throws -> RoomSummary {
        RoomSummary(
            id: try RoomID(id), name: id, isDirect: false, isEncrypted: false, membership: membership,
            read: RoomReadCounts(mode: mode, server: ServerCounts(notification: notify, highlight: 0), sdk: .zero, isMarkedUnread: false))
    }

    private func record(_ room: String, _ event: String) throws -> NotificationRecord {
        NotificationRecord(roomID: try RoomID(room), eventID: try EventID(event), timestamp: Date(), isMention: false)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500_000 { if condition() { return true }; await Task.yield() }
        return false
    }

    private func make() async -> (FakeRoomListPort, RoomListCoordinator, FakeNotificationRecords, FakeBadgePort, BadgeCoordinator) {
        let rooms = FakeRoomListPort()
        let coordinator = RoomListCoordinator(port: rooms)
        let records = FakeNotificationRecords()
        let port = FakeBadgePort()
        let badge = BadgeCoordinator(rooms: coordinator, records: records, port: port)
        await badge.begin()
        await coordinator.start()
        return (rooms, coordinator, records, port, badge)
    }

    @Test("the badge follows the rooms that need attention and is recomputed, not counted up or down")
    func follows() async throws {
        let (rooms, _, _, port, badge) = await make()
        try rooms.emit(.reset([try summary("!a:x.org", notify: 2), try summary("!b:x.org"), try summary("!c:x.org", notify: 1, mode: .mute)]))
        #expect(await eventually { port.badge == 1 })
        try rooms.emit(.set(index: 1, try summary("!b:x.org", notify: 4)))
        #expect(await eventually { port.badge == 2 })
        try rooms.emit(.set(index: 0, try summary("!a:x.org")))
        #expect(await eventually { port.badge == 1 })
        #expect(port.history.last == [try RoomID("!b:x.org")])
        #expect(await badge.badge == 1)
    }

    @Test("a notification record makes a room count although the room list shows no unread, and opening it clears that")
    func recordsCount() async throws {
        let (rooms, _, records, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org"), try summary("!b:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        #expect(port.badge == 0)
        records.add(try record("!a:x.org", "$1"))  // written by the extension
        #expect(await eventually { port.badge == 1 })
        records.add(try record("!a:x.org", "$2"))  // a second event in the same room: still one room
        records.add(try record("!b:x.org", "$3"))
        #expect(await eventually { port.badge == 2 })
        records.clear(room: try RoomID("!a:x.org"))  // the user opened room a
        #expect(await eventually { port.badge == 1 })
    }

    @Test("a record for a room that isn't in the loaded list still counts")
    func unknownRoom() async throws {
        let (rooms, _, records, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        records.add(try record("!elsewhere:x.org", "$9"))
        #expect(await eventually { port.badge == 1 })
    }

    @Test("the first evaluation writes even an empty set, so a stale badge is cleared")
    func firstWriteClears() async throws {
        let (rooms, _, _, port, badge) = await make()
        defer { withExtendedLifetime(badge) {} }
        try rooms.emit(.reset([try summary("!a:x.org")]))
        #expect(await eventually { !port.history.isEmpty })
        #expect(port.history == [[]])
    }

    @Test("opening a timeline clears that room's records")
    func openClears() async throws {
        let records = FakeNotificationRecords()
        let timelines = FakeTimelinePort()
        let room = try RoomID("!a:x.org")
        timelines.addRoom(room)
        records.add(try record("!a:x.org", "$1"))
        records.add(try record("!b:x.org", "$2"))
        await TimelineCoordinator(port: timelines, room: room, records: records).open()
        #expect(records.all().map(\.eventID.rawValue) == ["$2"])
    }
}
