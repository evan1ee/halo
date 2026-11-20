import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureRoomList

@MainActor
@Suite("NewChatViewModel")
struct NewChatViewModelTests {
    private func user(_ id: String, _ name: String?) throws -> UserSummary { UserSummary(id: try UserID(id), displayName: name) }

    @Test("a fully typed Matrix ID is offered even when the directory doesn't list it")
    func typedID() async throws {
        let model = NewChatViewModel(port: FakeChatCreationPort(), onCreated: { _ in })
        model.query = "@zed:x.org"
        #expect(model.candidates.map(\.id.rawValue) == ["@zed:x.org"])
        model.query = "zed"
        #expect(model.typedUser == nil)
    }

    @Test("directory matches are listed; the typed ID is not repeated")
    func search() async throws {
        let ann = try user("@ann:x.org", "Ann")
        let model = NewChatViewModel(port: FakeChatCreationPort(directory: [ann, try user("@bob:x.org", "Bob")]), onCreated: { _ in })
        model.query = "@ann:x.org"
        await model.search()
        #expect(model.candidates == [ann])
    }

    @Test("starting a chat opens the room; asking again for the same user gives the same room")
    func startChat() async throws {
        let ann = try user("@ann:x.org", "Ann")
        let port = FakeChatCreationPort()
        var opened: [RoomID] = []
        let model = NewChatViewModel(port: port, onCreated: { opened.append($0) })
        await model.startChat(with: ann)
        await model.startChat(with: ann)
        #expect(opened.count == 2 && opened[0] == opened[1])
    }

    @Test("a room needs a name; it invites the picked users; a failure is shown and nothing opens")
    func createRoom() async throws {
        let ann = try user("@ann:x.org", "Ann")
        let port = FakeChatCreationPort()
        var opened: [RoomID] = []
        let model = NewChatViewModel(port: port, onCreated: { opened.append($0) })
        #expect(!model.canCreateRoom)
        model.roomName = "  Book club "
        model.toggleInvite(ann)
        #expect(model.canCreateRoom)
        port.fail(with: .network(retryable: true))
        await model.createRoom()
        #expect(opened.isEmpty && model.errorText == "You appear to be offline. Try again.")
        port.fail(with: nil)
        await model.createRoom()
        #expect(opened.count == 1 && model.errorText == nil)
        #expect(port.createdRooms.first?.name == "Book club" && port.createdRooms.first?.invite == [ann.id])
        model.toggleInvite(ann)
        #expect(model.invited.isEmpty)
    }
}
