import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureRoomDetails

@MainActor
@Suite("RoomDetailsViewModel")
struct RoomDetailsViewModelTests {
    private func fixture(members: [RoomMemberInfo]? = nil, count: Int = 3) throws -> (FakeRoomPort, RoomDetailsViewModel, RoomID) {
        let id = try RoomID("!r:x.org")
        let details = RoomDetails(id: id, name: "General", topic: "Chat", isDirect: false, isEncrypted: true, joinedMemberCount: count, notificationMode: .allMessages)
        let list = members ?? [
            RoomMemberInfo(userID: "@a:x.org", displayName: "Ann", role: .administrator, isMe: true),
            RoomMemberInfo(userID: "@b:x.org", displayName: nil, role: .user),
        ]
        let port = FakeRoomPort(details: details, members: list)
        return (port, RoomDetailsViewModel(port: port, room: id), id)
    }

    @Test("loads the details and members")
    func loads() async throws {
        let (_, model, id) = try fixture()
        await model.load()
        guard case .loaded(let details, let members) = model.content else { Issue.record("not loaded"); return }
        #expect(details.id == id)
        #expect(members.count == 2)
        #expect(members[1].title == "@b:x.org")
    }

    @Test("a failing load shows a message")
    func failedLoad() async throws {
        let (port, model, _) = try fixture()
        port.fail(with: .network(retryable: true))
        await model.load()
        #expect(model.content == .failed("You appear to be offline. Try again."))
    }

    @Test("changing the mode is stored and shown; a failure keeps the old mode")
    func mode() async throws {
        let (port, model, _) = try fixture()
        await model.load()
        await model.setNotificationMode(.mute)
        #expect(port.modeChanges == [.mute])
        guard case .loaded(let details, _) = model.content else { Issue.record("not loaded"); return }
        #expect(details.notificationMode == .mute)
        port.fail(with: .forbidden)
        await model.setNotificationMode(.allMessages)
        guard case .loaded(let after, _) = model.content else { Issue.record("not loaded"); return }
        #expect(after.notificationMode == .mute)
        #expect(model.actionError == "You don't have permission to do that.")
    }

    @Test("leaving reports success; a failure is shown and the room stays")
    func leaving() async throws {
        let (port, model, id) = try fixture()
        await model.load()
        port.fail(with: .network(retryable: true))
        await model.leave()
        #expect(!model.hasLeft)
        #expect(model.actionError != nil)
        port.fail(with: nil)
        await model.leave()
        #expect(model.hasLeft)
        #expect(port.leftRooms == [id])
    }

    @Test("leaving warns when the user is the only administrator of a room with others")
    func lastAdmin() async throws {
        let (_, model, _) = try fixture()
        await model.load()
        #expect(model.leavingStrandsRoom)
        let (_, other, _) = try fixture(members: [RoomMemberInfo(userID: "@a:x.org", displayName: "Ann", role: .administrator, isMe: true)], count: 0)
        await other.load()
        #expect(!other.leavingStrandsRoom)
    }
}

extension RoomDetailsViewModelTests {
    @Test("the member count falls back to the loaded members when the SDK count is 0")
    func countFallback() async throws {
        let (_, model, _) = try fixture(count: 0)
        await model.load()
        #expect(model.joinedMemberCount == 2)
    }
}
