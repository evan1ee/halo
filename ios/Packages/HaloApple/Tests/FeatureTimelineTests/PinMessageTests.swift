import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("Pin messages")
@MainActor
struct PinMessageTests {
    @Test("togglePin pins and unpins a confirmed message and keeps pinnedEventIDs in sync")
    func pinAndUnpin() async throws {
        let room = try RoomID("!pin:x.org")
        let eventID = try EventID("$msg1")
        let event = TimelineEvent(
            eventID: eventID,
            sender: try UserID("@alice:x.org"),
            senderName: "Alice",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isOwn: false,
            kind: .text("Important notice", isEdited: false)
        )
        let port = FakeTimelinePort()
        port.addRoom(room, items: [TimelineItem(id: TimelineItemID("row-1"), content: .event(event))])
        let coordinator = TimelineCoordinator(port: port, room: room)
        let vm = TimelineViewModel(coordinator: coordinator, room: room)

        await vm.start()
        for _ in 0..<5 {
            if case .live(let rows, _, _, _) = vm.content, !rows.isEmpty { break }
            await Task.yield()
        }

        guard case .live(let rows, _, _, _) = vm.content, let row = rows.first(where: { $0.eventID == eventID }) else {
            await vm.stop()
            Issue.record("Expected seeded message row")
            return
        }

        #expect(!vm.isPinned(row))
        #expect(vm.pinnedMessages.isEmpty)
        await vm.togglePin(row)
        #expect(vm.isPinned(row))
        #expect(port.pinnedEvents(in: room) == [eventID])
        #expect(vm.pinnedMessages.count == 1)
        #expect(vm.pinnedMessages.first?.preview == "Important notice")
        #expect(vm.pinnedMessages.first?.sender == "Alice")

        await vm.unpin(eventID: eventID)
        #expect(!vm.isPinned(row))
        #expect(vm.pinnedMessages.isEmpty)
        #expect(port.pinnedEvents(in: room).isEmpty)
        await vm.stop()
    }

    @Test("re-entering a room reloads existing pinned messages immediately after open")
    func reenteringRoomKeepsPins() async throws {
        let room = try RoomID("!pin-reenter:x.org")
        let eventID = try EventID("$pinned1")
        let event = TimelineEvent(
            eventID: eventID,
            sender: try UserID("@alice:x.org"),
            senderName: "Alice",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isOwn: false,
            kind: .text("Pinned before leaving", isEdited: false)
        )
        let port = FakeTimelinePort()
        port.addRoom(room, items: [TimelineItem(id: TimelineItemID("row-1"), content: .event(event))])

        // First visit: pin the message and leave the room.
        let vm1 = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), room: room)
        await vm1.start()
        for _ in 0..<5 {
            if case .live(let rows, _, _, _) = vm1.content, !rows.isEmpty { break }
            await Task.yield()
        }
        await vm1.pin(eventID: eventID)
        #expect(vm1.pinnedEventIDs == [eventID])
        await vm1.stop()

        // Second visit: brand-new coordinator & view model re-entering the room.
        let vm2 = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room), room: room)
        await vm2.start()
        for _ in 0..<5 {
            if case .live(let rows, _, _, _) = vm2.content, !rows.isEmpty { break }
            await Task.yield()
        }
        #expect(vm2.pinnedEventIDs == [eventID])
        #expect(vm2.pinnedMessages.count == 1)
        #expect(vm2.pinnedMessages.first?.preview == "Pinned before leaving")
        await vm2.stop()
    }
}
