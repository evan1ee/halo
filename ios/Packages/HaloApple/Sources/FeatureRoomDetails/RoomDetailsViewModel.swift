import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The room info sheet (ROOM_MANAGEMENT FR-1…FR-4): details, the first page of members, the notification mode and leaving.
@MainActor @Observable
public final class RoomDetailsViewModel: Identifiable {
    public enum Content: Equatable {
        case loading
        case loaded(RoomDetails, members: [RoomMemberInfo])
        case failed(String)
    }

    /// How many members one page adds (FR-2); "Show more" raises the limit by this much.
    public static let memberPage = 200
    /// The number of members requested now.
    public private(set) var requestedMembers = RoomDetailsViewModel.memberPage

    public private(set) var content: Content = .loading
    /// Set when changing the mode or leaving fails; cleared by the next successful action or when dismissed.
    public private(set) var actionError: String?

    public func dismissActionError() { actionError = nil }
    /// `true` once the user has left; the screen closes.
    public private(set) var hasLeft = false
    /// `true` while the leave confirmation is shown.
    public var confirmsLeave = false
    /// Bytes of a photo just uploaded during this sheet visit, shown immediately before the next sync delivers a new `MediaRef`.
    public private(set) var localAvatar: Data?
    /// Recent media items loaded for the room's Media & Files gallery (M9 Gallery + Export).
    public private(set) var galleryItems: [RoomMediaItem] = []
    public private(set) var isLoadingGallery = false
    public private(set) var galleryError: String?

    /// Loads recent photos, videos, audio and files for this room (M9).
    public func loadGallery(limit: Int = 50) async {
        guard !isLoadingGallery else { return }
        isLoadingGallery = true
        galleryError = nil
        defer { isLoadingGallery = false }
        do throws(HaloError) {
            galleryItems = try await port.mediaGallery(in: room, limit: limit)
        } catch {
            galleryError = Self.text(error)
        }
    }

    /// Downloads full bytes of a gallery item to a temporary file so the user can share/export it (M9).
    public func exportMediaFile(_ item: RoomMediaItem) async -> URL? {
        guard let media, let ref = item.attachment.source else { return nil }
        do {
            let data = try await media.content(ref)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-gallery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rawName = URL(fileURLWithPath: item.attachment.body).lastPathComponent
            let name = rawName.isEmpty || rawName == "." || rawName == ".." ? "attachment" : rawName
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Output of an on-demand encrypted room export (D32, R-P2-EXPORT).
    public struct EncryptedRoomExportResult: Sendable, Equatable {
        public let url: URL
        public let messageCount: Int
    }

    public private(set) var isExportingRoom = false
    public private(set) var roomExportError: String?
    public var canExportEncryptedRoom: Bool { encryptor != nil }

    /// Exports recent room messages into a passphrase-encrypted `.halo-export.json` archive (D32, R-P2-EXPORT).
    public func exportEncryptedRoom(passphrase: String, limit: Int = 500) async -> EncryptedRoomExportResult? {
        guard let encryptor else {
            roomExportError = "Encrypted export is not available."
            return nil
        }
        guard !isExportingRoom else { return nil }
        let minLen = type(of: encryptor).minimumPassphraseLength
        guard passphrase.count >= minLen else {
            roomExportError = "Passphrase must be at least \(minLen) characters."
            return nil
        }
        isExportingRoom = true
        roomExportError = nil
        defer { isExportingRoom = false }

        do {
            let details: RoomDetails
            if case .loaded(let loaded, _) = content {
                details = loaded
            } else {
                details = try await port.details(room)
            }
            let messages = try await port.exportMessages(in: room, limit: limit)
            let doc = RoomExportDocument(
                exportedAt: Date(),
                roomID: room.rawValue,
                roomName: details.name ?? room.rawValue,
                roomTopic: details.topic,
                messages: messages
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let plaintext = try encoder.encode(doc)
            let encrypted = try encryptor.encrypt(plaintext, passphrase: passphrase)

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("halo-room-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = (details.name ?? "room")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let filename = "\(base.isEmpty ? "room" : base).halo-export.json"
            let url = dir.appendingPathComponent(filename)
            try encrypted.write(to: url, options: .atomic)
            return EncryptedRoomExportResult(url: url, messageCount: messages.count)
        } catch let error as HaloError {
            roomExportError = Self.text(error)
            return nil
        } catch {
            roomExportError = "Couldn't create encrypted export."
            return nil
        }
    }

    /// `true` when the room currently has an avatar (either from the server or just uploaded).
    public var hasAvatar: Bool {
        if localAvatar != nil { return true }
        if case .loaded(let details, _) = content { return details.avatar != nil }
        return false
    }

    private let port: any RoomPort
    private let room: RoomID

    private let images: (any ImagePreparing)?
    private let media: MediaLoader?
    private let encryptor: (any RoomExportEncryptor)?

    /// An avatar's image bytes (a small thumbnail); `nil` without a loader or when the download failed, so the initial stays.
    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 96, height: 96)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    public init(
        port: any RoomPort, room: RoomID, images: (any ImagePreparing)? = nil, media: MediaLoader? = nil,
        encryptor: (any RoomExportEncryptor)? = nil
    ) {
        self.images = images
        self.media = media
        self.encryptor = encryptor
        self.port = port
        self.room = room
    }

    /// The members shown under a heading; administrators carry a badge.
    public func load() async {
        content = .loading
        do throws(HaloError) {
            let details = try await port.details(room)
            let members = try await port.members(room, limit: requestedMembers)
            content = .loaded(details, members: members)
        } catch { content = .failed(Self.text(error)) }
    }

    /// Reads the details and members again without the loading screen (pull to refresh), so permissions that reached the SDK
    /// after the sheet opened show up (a just-created room). A failure keeps what is shown and reports it.
    public func refresh() async {
        guard case .loaded = content else { return await load() }
        do throws(HaloError) {
            let details = try await port.details(room)
            let members = try await port.members(room, limit: requestedMembers)
            content = .loaded(details, members: members)
            actionError = nil
        } catch { actionError = Self.text(error) }
    }

    /// `true` when the last load returned as many members as asked for, so there may be more.
    public var hasMoreMembers: Bool {
        guard case .loaded(_, let members) = content else { return false }
        return members.count >= requestedMembers
    }

    /// Sets a picked photo as the room's avatar: shrunk and stripped of metadata first. Returns `true` on success.
    @discardableResult
    public func changePhoto(_ data: Data) async -> Bool {
        guard let images else { return false }
        do throws(HaloError) {
            let image = try images.prepare(data: data, filename: "avatar")
            try await port.setAvatar(mimeType: image.mimeType, data: image.data, in: room)
            localAvatar = image.data
            actionError = nil
            return true
        } catch {
            actionError = Self.photoText(error)
            return false
        }
    }

    public func removePhoto() async {
        do throws(HaloError) {
            try await port.removeAvatar(in: room)
            localAvatar = nil
            if case .loaded(let details, let members) = content {
                content = .loaded(details.with(avatar: nil), members: members)
            }
            actionError = nil
        } catch { actionError = Self.photoText(error) }
    }

    private static func photoText(_ error: HaloError) -> String {
        switch error {
        case .forbidden: "You don't have permission to change this room's photo."
        case .invalidInput: "That photo couldn't be used. Try another one."
        default: text(error)
        }
    }

    /// Asks for one more page of members (administrators and moderators stay first).
    public func loadMoreMembers() async {
        guard hasMoreMembers, case .loaded(let details, _) = content else { return }
        do throws(HaloError) {
            let more = try await port.members(room, limit: requestedMembers + Self.memberPage)
            requestedMembers += Self.memberPage
            content = .loaded(details, members: more)
            actionError = nil
        } catch { actionError = Self.text(error) }
    }

    public func setNotificationMode(_ mode: RoomNotificationChoice) async {
        guard case .loaded(let details, let members) = content, details.notificationMode != mode else { return }
        do throws(HaloError) {
            try await port.setNotificationMode(mode, in: room)
            content = .loaded(details.with(notificationMode: mode), members: members)
            actionError = nil
        } catch { actionError = Self.text(error) }
    }

    /// The number of joined members: the SDK's count, or the members actually loaded when the SDK's summary count is missing
    /// (found against infra/dev: it stays 0 under classic sync).
    public var joinedMemberCount: Int {
        guard case .loaded(let details, let members) = content else { return 0 }
        return max(details.joinedMemberCount, members.filter { !$0.isInvited }.count)
    }

    /// Grammatically pluralised member count ("1 member" / "3 members").
    public var memberCountText: String {
        joinedMemberCount == 1 ? "1 member" : "\(joinedMemberCount) members"
    }

    /// Whether leaving needs a warning: the user is the only administrator of a room with other people (FR-4).
    public var leavingStrandsRoom: Bool {
        guard case .loaded(_, let members) = content, joinedMemberCount > 1 else { return false }
        return members.filter { $0.role == .administrator && !$0.isInvited }.count == 1 && ownRole == .administrator
    }

    /// The signed-in user's role in the room, once the members are loaded.
    public var ownRole: RoomMemberRole? {
        guard case .loaded(_, let members) = content else { return nil }
        return members.first { $0.isMe }?.role
    }

    /// Saves a new name and topic (FR-7). An empty name is refused.
    public func saveDetails(name: String, topic: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { actionError = "The room needs a name."; return false }
        guard case .loaded(let details, let members) = content else { return false }
        do throws(HaloError) {
            try await port.setDetails(name: name, topic: topic, in: room)
            content = .loaded(details.with(name: name, topic: topic.isEmpty ? nil : topic), members: members)
            actionError = nil
            return true
        } catch { actionError = Self.text(error); return false }
    }

    /// Invites one person by Matrix ID (FR-5); the text must be a complete ID.
    public func invite(_ text: String) async -> Bool {
        guard let user = try? UserID(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            actionError = "Enter a full Matrix ID, like @name:server."
            return false
        }
        do throws(HaloError) {
            try await port.invite([user], to: room)
            actionError = nil
            return true
        } catch { actionError = Self.text(error); return false }
    }

    public func leave() async {
        do throws(HaloError) {
            try await port.leave(room)
            hasLeft = true
            actionError = nil
        } catch { actionError = Self.text(error) }
    }

    private static func text(_ error: HaloError) -> String {
        switch error {
        case .network: "You appear to be offline. Try again."
        case .forbidden: "You don't have permission to do that."
        default: "That didn't work. Try again."
        }
    }
}
