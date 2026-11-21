import Foundation
import HaloApplication
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
        #expect(model.memberCountText == "2 members")
        let (_, solo, _) = try fixture(members: [RoomMemberInfo(userID: "@a:x.org", displayName: "Ann", role: .administrator, isMe: true)], count: 1)
        await solo.load()
        #expect(solo.memberCountText == "1 member")
    }
}

extension RoomDetailsViewModelTests {
    @Test("saving a name and topic is stored and shown; an empty name is refused; a failure is shown")
    func editDetails() async throws {
        let (port, model, _) = try fixture()
        await model.load()
        #expect(await model.saveDetails(name: "  ", topic: "x") == false)
        #expect(port.detailEdits.isEmpty && model.actionError == "The room needs a name.")
        #expect(await model.saveDetails(name: " Renamed ", topic: "") == true)
        #expect(port.detailEdits.first?.name == "Renamed")
        guard case .loaded(let details, _) = model.content else { Issue.record("not loaded"); return }
        #expect(details.name == "Renamed" && details.topic == nil)
        port.fail(with: .forbidden)
        #expect(await model.saveDetails(name: "Again", topic: "t") == false)
        #expect(model.actionError == "You don't have permission to do that.")
    }

    @Test("inviting needs a complete Matrix ID")
    func inviting() async throws {
        let (port, model, _) = try fixture()
        await model.load()
        #expect(await model.invite("ann") == false)
        #expect(port.sentInvites.isEmpty && model.actionError != nil)
        #expect(await model.invite(" @ann:x.org ") == true)
        #expect(port.sentInvites.first?.map(\.rawValue) == ["@ann:x.org"])
        #expect(model.actionError == nil)
    }

    @Test("a room with more members than one page offers more, and a second page loads them all")
    func memberPaging() async throws {
        let many = (0..<450).map { RoomMemberInfo(userID: "@u\($0):x.org", displayName: "User \($0)", role: .user) }
        let (_, model, _) = try fixture(members: many, count: 450)
        await model.load()
        guard case .loaded(_, let first) = model.content else { Issue.record("not loaded"); return }
        #expect(first.count == 200)
        #expect(model.hasMoreMembers)
        await model.loadMoreMembers()
        await model.loadMoreMembers()
        guard case .loaded(_, let all) = model.content else { Issue.record("not loaded"); return }
        #expect(all.count == 450)
        #expect(!model.hasMoreMembers)
    }

    private struct PassThrough: ImagePreparing {
        func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
            guard !data.isEmpty else { throw .invalidInput("EMPTY_IMAGE") }
            return OutgoingImage(data: data, filename: filename, mimeType: "image/png", width: 1, height: 1)
        }
    }

    @Test("changing the room photo uploads the prepared image; removing calls the port; failures are explained")
    func roomPhoto() async throws {
        let (port, _, id) = try fixture()
        let model = RoomDetailsViewModel(port: port, room: id, images: PassThrough())
        await model.load()
        #expect(!model.hasAvatar && model.localAvatar == nil)
        #expect(await model.changePhoto(Data([1, 2])))
        #expect(port.avatarUploads == [Data([1, 2])])
        #expect(model.hasAvatar && model.localAvatar == Data([1, 2]))
        #expect(await model.changePhoto(Data()) == false)
        #expect(model.actionError?.contains("couldn't be used") == true)
        await model.removePhoto()
        #expect(port.avatarRemovals == 1 && model.actionError == nil && !model.hasAvatar && model.localAvatar == nil)
        port.fail(with: .forbidden)
        #expect(await model.changePhoto(Data([3])) == false)
        #expect(model.actionError?.contains("permission") == true)
    }

    @Test("avatar bytes come from the media loader; without one, or on failure, there are none")
    func avatarData() async throws {
        let (port, _, id) = try fixture()
        let ref = MediaRef(token: "a")
        let media = FakeMediaPort()
        media.add(ref, data: Data([7]))
        let withMedia = RoomDetailsViewModel(port: port, room: id, media: MediaLoader(port: media))
        #expect(await withMedia.avatarData(ref) == Data([7]))
        #expect(await withMedia.avatarData(MediaRef(token: "none")) == nil)
        #expect(await RoomDetailsViewModel(port: port, room: id).avatarData(ref) == nil)
    }

    @Test("load recovers after a failure and dismissActionError clears an action error")
    func retryAndDismiss() async throws {
        let (port, _, id) = try fixture()
        port.fail(with: .network(retryable: true))
        let model = RoomDetailsViewModel(port: port, room: id)
        await model.load()
        if case .failed = model.content {} else { Issue.record("expected failed") }
        port.fail(with: nil)
        await model.load()
        if case .loaded = model.content {} else { Issue.record("expected loaded on retry") }
        port.fail(with: .forbidden)
        await model.removePhoto()
        #expect(model.actionError != nil)
        model.dismissActionError()
        #expect(model.actionError == nil)
    }
}
