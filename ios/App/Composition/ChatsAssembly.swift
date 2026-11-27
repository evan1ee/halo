import FeatureMedia
import FeatureProfile
import FeatureRoomDetails
import FeatureRoomList
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

    /// Global media gallery opened from the preset non-Matrix room entry in the room list (D34, D83).
    func makeGlobalMediaGallery() -> GlobalMediaGalleryViewModel {
        GlobalMediaGalleryViewModel(rooms: roomCoordinator, roomPort: roomPort, media: media)
    }

    /// The profile sheet of a room member (USER_PROFILES); `nil` when the member's ID is not valid.
    func makeUserProfile(member: RoomMemberInfo, onOpenRoom: @escaping @MainActor (RoomID) -> Void) -> UserProfileViewModel? {
        guard let user = try? UserID(member.userID) else { return nil }
        return UserProfileViewModel(
            profiles: profilePort, chats: chatCreation, user: user, roomDisplayName: member.displayName,
            isMe: member.isMe, avatar: member.avatar, media: media,
            onIgnoreChanged: { [roomCoordinator, search] in
                await roomCoordinator.refreshIgnoredUsers()
                await search.refreshIgnoredUsers()
            },
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

    /// Preview sheet for joining, knocking on, or managing a room by ID or alias (ROOM_MANAGEMENT FR-11, M20-8).
    func makeRoomPreview(address: String, focusEvent: EventID? = nil) -> RoomPreviewViewModel {
        RoomPreviewViewModel(address: address, focusEvent: focusEvent, rooms: roomPort, chats: chatCreation)
    }

    /// List of `.knocked`, `.left`, and `.banned` rooms so no room can remain stuck (M20-8).
    func makeInactiveRooms() -> InactiveRoomsViewModel {
        InactiveRoomsViewModel(roomPort: roomPort, chats: chatCreation)
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
            videos: VideoPreparer(),
            readThrough: readThroughClosure,
            thumbnails: thumbnailMemory
        )
        model.unrecognisedBotMessages = unrecognisedBots
        model.botActivity = threadRoot == nil ? botActivity : nil
        model.sendsTypingNotices = { [preferences] in preferences.sendTypingNotices }
        model.forwarder = ForwardCoordinator(timeline: timelinePort, media: MatrixMediaPort(session: matrixSession))
        model.loadForwardTargets = { @Sendable [roomCoordinator] in
            let allRooms = await roomCoordinator.rooms
            let sourceIsEncrypted = allRooms.first { $0.id == room }?.isEncrypted ?? false
            let targets = allRooms
                .filter { $0.membership == .joined }
                .map { summary in
                    ForwardTarget(
                        id: summary.id,
                        name: summary.name ?? "Unnamed room",
                        isDirect: summary.isDirect,
                        isEncrypted: summary.isEncrypted,
                        avatar: summary.avatar
                    )
                }
            return (sourceIsEncrypted, targets)
        }
        model.loadRoomLifecycle = { @Sendable [roomPort] in
            guard let details = try? await roomPort.details(room) else { return nil }  // best-effort: unread lifecycle defaults to active room
            return RoomLifecyclePolicy.banner(membership: details.membership, successor: details.successor, roomID: room)
        }
        model.leaveAndForgetRoom = { @Sendable [roomPort] () async throws(HaloError) in
            try await roomPort.leave(room)
            try? await roomPort.forget(room)  // best-effort: some servers auto-forget on leave
        }
        model.forgetCurrentRoom = { @Sendable [roomPort] () async throws(HaloError) in
            try await roomPort.forget(room)
        }
        model.cancelCurrentKnock = { @Sendable [roomPort] () async throws(HaloError) in
            try await roomPort.leave(room)
            try? await roomPort.forget(room)  // best-effort: some servers auto-forget cancelled knocks
        }
        configure(model)
        return model
    }

    /// The settings a model reads when it is shown; set again on a model started ahead, as they may have changed meanwhile.
    private func configure(_ model: TimelineViewModel) {
        model.botSenders = Set(preferences.botSenders)
        model.klipy = klipy.isAvailable ? klipy : nil
    }

    /// The view model of a room screen: the one started when the room was chosen in the chat list (M19-9, D-MOT-2), so the first
    /// frame has rows; otherwise a new one. A room opened at a message always gets a new one.
    func makeRoomTimeline(room: RoomID, jumpTo: EventID?) -> TimelineViewModel {
        if jumpTo == nil, let started = preparedTimelines.take(room) {
            configure(started)
            return started
        }
        let model = makeTimeline(room: room)
        model.initialEvent = jumpTo
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
