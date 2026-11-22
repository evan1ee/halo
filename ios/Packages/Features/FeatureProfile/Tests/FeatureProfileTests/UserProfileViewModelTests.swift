import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureProfile

@MainActor
@Suite("UserProfileViewModel")
struct UserProfileViewModelTests {
    private func make(profiles: FakeProfilePort, chats: FakeChatCreationPort = FakeChatCreationPort(), isMe: Bool = false, onOpen: @escaping @MainActor (RoomID) -> Void = { _ in }) throws -> UserProfileViewModel {
        UserProfileViewModel(profiles: profiles, chats: chats, user: try UserID("@ann:x.org"), roomDisplayName: "Ann (room)", isMe: isMe, onOpenRoom: onOpen)
    }

    @Test("loads the profile and the ignored state; ignoring and unignoring are stored")
    func ignore() async throws {
        let ann = try UserID("@ann:x.org")
        let profiles = FakeProfilePort(profiles: [UserProfile(userID: ann, displayName: "Ann")])
        let model = try make(profiles: profiles)
        await model.load()
        #expect(model.content == .loaded(UserProfile(userID: ann, displayName: "Ann"), isIgnored: false))
        await model.toggleIgnore()
        #expect(profiles.ignored == [ann])
        #expect(model.content == .loaded(UserProfile(userID: ann, displayName: "Ann"), isIgnored: true))
        await model.toggleIgnore()
        #expect(profiles.ignored.isEmpty)
    }

    @Test("a profile that can't be fetched falls back to the name from the room; a failed ignore is shown")
    func fallback() async throws {
        let ann = try UserID("@ann:x.org")
        let profiles = FakeProfilePort()
        let model = try make(profiles: profiles)
        await model.load()
        #expect(model.content == .loaded(UserProfile(userID: ann, displayName: "Ann (room)"), isIgnored: false))
        profiles.fail(with: .network(retryable: true))
        await model.toggleIgnore()
        #expect(model.actionError == "You appear to be offline. Try again.")
    }

    @Test("messaging opens the direct chat; your own profile has no actions")
    func message() async throws {
        var opened: [RoomID] = []
        let model = try make(profiles: FakeProfilePort(), onOpen: { opened.append($0) })
        await model.message()
        #expect(opened.count == 1)
        let me = try make(profiles: FakeProfilePort(), isMe: true, onOpen: { opened.append($0) })
        await me.message()
        await me.load()
        await me.toggleIgnore()
        #expect(opened.count == 1)
    }

    @Test("profile avatar loads from MediaLoader when available")
    func avatarLoading() async throws {
        let ann = try UserID("@ann:x.org")
        let ref = MediaRef(token: "u1")
        let mediaPort = FakeMediaPort()
        mediaPort.add(ref, data: Data([9, 8]))
        let withAvatar = UserProfileViewModel(
            profiles: FakeProfilePort(), chats: FakeChatCreationPort(), user: ann, roomDisplayName: "Ann",
            isMe: false, avatar: ref, media: MediaLoader(port: mediaPort), onOpenRoom: { _ in })
        #expect(await withAvatar.avatarData() == Data([9, 8]))
        let withoutAvatar = try make(profiles: FakeProfilePort())
        #expect(await withoutAvatar.avatarData() == nil)
    }

    @Test("shareURL returns the person's matrix.to permalink (USER_PROFILES FR-3)")
    func shareLink() throws {
        let model = try make(profiles: FakeProfilePort())
        #expect(model.shareURL?.absoluteString == "https://matrix.to/#/@ann:x.org")
    }
}
