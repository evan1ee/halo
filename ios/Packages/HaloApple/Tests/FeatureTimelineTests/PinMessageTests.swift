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
}
