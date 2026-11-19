import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `NotificationFetchPort` over the SDK's `NotificationClient` in `MultipleProcesses` mode, for the notification
/// extension (docs/matrix/PUSH_NOTIFICATIONS.md §3). It fetches the event the push points at, decrypts it through the
/// shared crypto store, and maps it to text. It never starts a sync loop.
public final class MatrixNotificationPort: NotificationFetchPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func fetch(room: RoomID, event: EventID) async throws(HaloError) -> NotificationFetchResult {
        let client = try await session.signedInClient()
        do {
            let notifications = try await client.notificationClient(processSetup: .multipleProcesses)
            let status = try await notifications.getNotification(roomId: room.rawValue, eventId: event.rawValue)
            return try NotificationMapper.result(status)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }
}

enum NotificationMapper {
    static func result(_ status: NotificationStatus) throws(HaloError) -> NotificationFetchResult {
        switch status {
        case .event(let item): return result(item)
        case .eventNotFound: throw .notFound
        case .eventFilteredOut, .eventRedacted: return .suppressed
        }
    }

    static func result(_ item: NotificationItem) -> NotificationFetchResult {
        let sender = item.senderInfo.displayName ?? "Someone"
        switch item.event {
        case .invite(let inviter):
            return .display(NotificationDisplay(title: item.roomInfo.displayName, body: "\(item.senderInfo.displayName ?? inviter) invited you"))
        case .timeline(let event):
            guard let content = try? event.content() else { return .suppressed }
            guard case .messageLike(let like) = content else { return .suppressed }
            switch like {
            case .roomEncrypted:
                return .encrypted(roomName: item.roomInfo.displayName)
            case .roomMessage(let type, _):
                return .display(shape(sender: sender, room: item.roomInfo.displayName, isDirect: item.roomInfo.isDirect, text: text(of: type)))
            case .sticker:
                return .display(shape(sender: sender, room: item.roomInfo.displayName, isDirect: item.roomInfo.isDirect, text: "Sticker"))
            default:
                return .suppressed
            }
        }
    }

    /// A direct chat shows the sender as the title; a group shows the room as the title and "Sender: text" as the body.
    static func shape(sender: String, room: String, isDirect: Bool, text: String) -> NotificationDisplay {
        isDirect ? NotificationDisplay(title: sender, body: text) : NotificationDisplay(title: room, body: "\(sender): \(text)")
    }

    static func text(of type: MessageType) -> String {
        switch type {
        case .text(let content): content.body
        case .notice(let content): content.body
        case .emote(let content): "* \(content.body)"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .file: "File"
        case .gallery: "Gallery"
        case .location: "Location"
        case .other(_, let body): body
        }
    }
}
