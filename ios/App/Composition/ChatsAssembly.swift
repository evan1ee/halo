import FeatureMedia
import FeatureProfile
import FeatureRoomDetails
import FeatureRoomList
import FeatureSearch
import FeatureStickers
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPlatform

/// Feature view-model factories for chats, search, media gallery, profiles, timelines, and stickers (ADR-0022 step 2).
extension AppRoot {
    /// The "New chat" sheet (ROOM_MANAGEMENT FR-5); `onCreated` gets the room to open.
    func makeNewChat(onCreated: @escaping @MainActor (RoomID) -> Void) -> NewChatViewModel {
        NewChatViewModel(port: chatCreation, ownUserID: signedInUser, onCreated: onCreated)
    }

    /// Message search view model for the `.searchable` room list (D85, M8).
    func makeMessageSearch() -> MessageSearchViewModel {
        MessageSearchViewModel(coordinator: searchCoordinator) { [roomList] roomID in
            if case .loaded(_, let rows) = roomList.content, let row = rows.first(where: { $0.id == roomID }) {
                return row.name
            }
            return "Room"
        }
    }

    /// Global media gallery opened from the preset non-Matrix room entry in the room list (D34, D83).
    func makeGlobalMediaGallery() -> GlobalMediaGalleryViewModel {
        GlobalMediaGalleryViewModel(rooms: roomCoordinator, roomPort: roomPort, media: media)
    }

    /// Resolves a `matrix.to` or `matrix:` deep link into a joined room and optional target event (NAVIGATION §3).
    func resolveMatrixLink(_ url: URL) async -> (room: RoomID, event: EventID?)? {
        guard case .signedIn = auth.screen, let link = MatrixLink.parse(url) else { return nil }
        switch link {
        case .room(let id, let event):
            let alreadyJoined = await roomCoordinator.rooms.contains { $0.id == id && $0.membership == .joined }
            if alreadyJoined { return (id, event) }
            guard let joined = try? await chatCreation.joinRoom(id.rawValue) else { return nil }
            return (joined, event)
        case .roomAlias(let alias, let event):
            guard let joined = try? await chatCreation.joinRoom(alias) else { return nil }
            return (joined, event)
        case .user(let user):
            guard let dm = try? await chatCreation.startDirectChat(with: user) else { return nil }
            return (dm, nil)
        }
    }

    /// The profile sheet of a room member (USER_PROFILES); `nil` when the member's ID is not valid.
    func makeUserProfile(member: RoomMemberInfo, onOpenRoom: @escaping @MainActor (RoomID) -> Void) -> UserProfileViewModel? {
        guard let user = try? UserID(member.userID) else { return nil }
        return UserProfileViewModel(
            profiles: profilePort, chats: chatCreation, user: user, roomDisplayName: member.displayName,
            isMe: member.isMe, avatar: member.avatar, media: media,
            onIgnoreChanged: { [roomCoordinator] in await roomCoordinator.refreshIgnoredUsers() },
            onOpenRoom: onOpenRoom
        )
    }

    /// The room's display name for the timeline's title; `nil` while the list doesn't know it.
    func roomName(_ room: RoomID) async -> String? {
        await roomCoordinator.rooms.first { $0.id == room }?.name
    }

    /// The room info sheet for `room` (ROOM_MANAGEMENT).
    func makeRoomDetails(room: RoomID) -> RoomDetailsViewModel {
        RoomDetailsViewModel(
            port: roomPort, room: room, images: ImagePreparer(maximumDimension: 512),
            media: media, encryptor: CryptoKitRoomExportEncryptor()
        )
    }

    /// A view model for the timeline of `room`; each screen gets its own coordinator and session.
    func makeTimeline(room: RoomID, threadRoot: EventID? = nil) -> TimelineViewModel {
        let coordinator = TimelineCoordinator(port: timelinePort, room: room, threadRoot: threadRoot)
        let readThroughClosure: (@Sendable () async -> Date?)? = threadRoot == nil
            ? { @Sendable [roomCoordinator] in await roomCoordinator.rooms.first { $0.id == room }?.ownReadThrough }
            : nil
        let model = TimelineViewModel(
            coordinator: coordinator,
            media: media,
            previewsAllowed: { [previewPolicy] in await previewPolicy.previewsAllowed(in: room) },
            receipts: threadRoot == nil ? receipts : nil,
            room: room,
            drafts: threadRoot == nil ? drafts : nil,
            images: ImagePreparer(),
            readThrough: readThroughClosure
        )
        model.botSenders = Set(preferences.botSenders)
        model.unrecognisedBotMessages = unrecognisedBots
        model.botActivity = threadRoot == nil ? botActivity : nil
        model.sendsTypingNotices = { [preferences] in preferences.sendTypingNotices }
        model.klipy = klipy.isAvailable ? klipy : nil
        return model
    }

    /// A KLIPY grid (GIFs or stickers) for the timeline of `room`; `nil` without a KLIPY key (D98). Sending goes through that
    /// timeline's view model as a message holding the KLIPY URL.
    func makeKlipyPanel(_ kind: KlipyKind, timeline: TimelineViewModel) -> KlipyPanelModel? {
        guard klipy.isAvailable else { return nil }
        return KlipyPanelModel(kind: kind, catalog: klipy) { item throws(HaloError) in try await timeline.sendKlipy(item) }
    }

    /// The sticker panel for the timeline of `room`; sending goes through that timeline's view model.
    func makeStickerPanel(room: RoomID, timeline: TimelineViewModel) -> StickerPanelViewModel {
        let creator = StickerPackCreator(
            port: MatrixStickerPackCreationPort(session: matrixSession),
            preparer: ImagePreparer(maximumDimension: 512)
        )
        return StickerPanelViewModel(
            library: stickers, media: media, room: room,
            newPack: { done in NewPackViewModel(creator: creator, onCreated: done) },
            notice: StickerPanelViewModel.EncryptionNotice(
                roomIsEncrypted: { [roomCoordinator] in await roomCoordinator.rooms.first { $0.id == room }?.isEncrypted ?? false },
                isAcknowledged: { UserDefaults.standard.bool(forKey: "halo.stickers.encryptionNoticeSeen") },
                acknowledge: { UserDefaults.standard.set(true, forKey: "halo.stickers.encryptionNoticeSeen") }
            ),
            send: { sticker throws(HaloError) in try await timeline.sendSticker(sticker) }
        )
    }
}
