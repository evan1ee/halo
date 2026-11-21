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
            return .display(NotificationDisplay(
                title: item.roomInfo.displayName,
                body: "\(item.senderInfo.displayName ?? inviter) invited you",
                timestamp: rawEventTimestamp(item.rawEvent)))
        case .timeline(let event):
            guard let content = try? event.content() else { return .suppressed }
            guard case .messageLike(let like) = content else { return .suppressed }
            switch like {
            case .roomEncrypted:
                return .encrypted(roomName: item.roomInfo.displayName, timestamp: eventTimestamp(event, rawEvent: item.rawEvent))
            case .roomMessage(let type, _):
                return .display(stamped(shape(sender: sender, room: item.roomInfo.displayName, isDirect: item.roomInfo.isDirect, text: text(of: type)), event: event, item: item))
            case .sticker:
                return .display(stamped(shape(sender: sender, room: item.roomInfo.displayName, isDirect: item.roomInfo.isDirect, text: "Sticker"), event: event, item: item))
            default:
                return .suppressed
            }
        }
    }

    private static func stamped(_ display: NotificationDisplay, event: MatrixRustSDK.TimelineEvent, item: NotificationItem) -> NotificationDisplay {
        NotificationDisplay(
            title: display.title, body: display.body, timestamp: eventTimestamp(event, rawEvent: item.rawEvent),
            isMention: item.hasMention ?? false)
    }

    /// The event's `origin_server_ts`, from the SDK event or (as a fallback) from `rawEvent` JSON (R-02).
    static func eventTimestamp(_ event: MatrixRustSDK.TimelineEvent, rawEvent: String) -> Date? {
        let ms = event.timestamp()
        if ms > 0 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return rawEventTimestamp(rawEvent)
    }

    /// Parses `origin_server_ts` (milliseconds since epoch) from a raw Matrix event JSON string (R-02).
    static func rawEventTimestamp(_ rawEvent: String) -> Date? {
        guard let data = rawEvent.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = (object["origin_server_ts"] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
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
