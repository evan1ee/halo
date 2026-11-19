import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloTestSupport

@Suite("FakeTimelinePort honours the contract")
struct FakeTimelineContractTests {
    static func text(_ id: String, _ body: String) -> TimelineItem {
        TimelineItem(
            id: TimelineItemID(id),
            content: .event(TimelineEvent(
                eventID: try? EventID("$\(id)"), sender: try? UserID("@a:x.org"), senderName: "A",
                timestamp: Date(timeIntervalSince1970: 0), isOwn: false, kind: .text(body, isEdited: false))))
    }

    @Test("a known room shows its events; an unknown room is not found")
    func contract() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [Self.text("1", "one"), Self.text("2", "two")])
        try await TimelinePortContract.verify(port, room: room, expectedBodies: ["one", "two"])
        try await TimelinePortContract.verifyUnknownRoom(port, room: try RoomID("!missing:x.org"))
        #expect(port.openSessions(in: room) == 0)
    }

    @Test("back pagination prepends older events as front inserts and reports when the start is reached")
    func pagination() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [Self.text("3", "three")], older: [[Self.text("1", "one"), Self.text("2", "two")]])
        let session = try await port.open(room: room)
        let reachedStart = try await session.paginateBackwards(count: 20)
        #expect(reachedStart)
        var items: [TimelineItem] = []
        var seen = 0
        for await diff in session.items() {
            try ListReducer.apply(diff, to: &items)
            seen += 1
            break  // the replayed state already includes the older events
        }
        #expect(TimelinePortContract.bodies(of: items) == ["one", "two", "three"])
        #expect(seen == 1)
    }

    @Test("sending shows a local echo that is confirmed; blank text is rejected")
    func sending() async throws {
        let port = FakeTimelinePort()
        let room = try RoomID("!r:x.org")
        port.addRoom(room, items: [Self.text("1", "one")])
        try await TimelinePortContract.verifySend(port, room: room, text: "hello there")
        #expect(port.sentTexts(in: room) == ["hello there"])
    }
}
