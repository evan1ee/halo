import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import HaloApplication

@Suite("ChatShortcutPublisher")
struct ChatShortcutPublisherTests {
    private func room(_ id: String, _ name: String?, _ membership: Membership = .joined, favourite: Bool = false) -> RoomSummary {
        RoomSummary(id: try! RoomID(id), name: name, isDirect: false, isEncrypted: false, membership: membership, isFavourite: favourite)
    }

    @Test("off stores nothing and removes what was there")
    func off() async {
        let port = FakeChatShortcutPort()
        let publisher = ChatShortcutPublisher(port: port)
        await publisher.update(rooms: [room("!a:x.org", "A")], enabled: true)
        #expect(port.load().count == 1)
        await publisher.update(rooms: [room("!a:x.org", "A")], enabled: false)
        #expect(port.load().isEmpty)
        await publisher.update(rooms: [room("!a:x.org", "A")], enabled: false)
        #expect(port.clearCalls == 1)
    }

    @Test("only joined, named, distinct chats go out, favourites first")
    func selection() async {
        let port = FakeChatShortcutPort()
        let publisher = ChatShortcutPublisher(port: port)
        await publisher.update(rooms: [
            room("!a:x.org", "Alpha"), room("!b:x.org", "  "), room("!c:x.org", nil),
            room("!d:x.org", "Invite", .invited), room("!e:x.org", "Fav", favourite: true), room("!a:x.org", "Alpha again"),
        ], enabled: true)
        #expect(port.load() == [ChatShortcut(id: "!e:x.org", name: "Fav"), ChatShortcut(id: "!a:x.org", name: "Alpha")])
    }

    @Test("the list is capped and an unchanged list is not stored again")
    func capAndDedupe() async {
        let port = FakeChatShortcutPort()
        let publisher = ChatShortcutPublisher(port: port)
        let rooms = (0..<(ChatShortcutPublisher.limit + 20)).map { room("!r\($0):x.org", "Room \($0)") }
        await publisher.update(rooms: rooms, enabled: true)
        await publisher.update(rooms: rooms, enabled: true)
        #expect(port.load().count == ChatShortcutPublisher.limit)
        #expect(port.replaceCalls == 1)
    }
}
