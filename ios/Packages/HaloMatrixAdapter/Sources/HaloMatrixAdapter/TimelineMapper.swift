import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// Maps upstream timeline items to Halo's. Names that exist on both sides are written module-qualified.
enum TimelineMapper {
    static func map(_ update: MatrixRustSDK.TimelineDiff) -> HaloDomain.TimelineDiff {
        switch update {
        case .append(let values): .append(values.map(map))
        case .clear: .clear
        case .pushFront(let value): .pushFront(map(value))
        case .pushBack(let value): .pushBack(map(value))
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(index: Int(index), map(value))
        case .set(let index, let value): .set(index: Int(index), map(value))
        case .remove(let index): .remove(index: Int(index))
        case .truncate(let length): .truncate(length: Int(length))
        case .reset(let values): .reset(values.map(map))
        }
    }

    static func map(_ item: MatrixRustSDK.TimelineItem) -> HaloDomain.TimelineItem {
        let id = TimelineItemID(item.uniqueId().id)
        if let event = item.asEvent() { return HaloDomain.TimelineItem(id: id, content: .event(map(event))) }
        if let virtual = item.asVirtual() { return HaloDomain.TimelineItem(id: id, content: .virtual(map(virtual))) }
        return HaloDomain.TimelineItem(id: id, content: .event(
            HaloDomain.TimelineEvent(eventID: nil, sender: nil, senderName: nil, timestamp: Date(timeIntervalSince1970: 0), isOwn: false, kind: .unsupported)))
    }

    static func map(_ virtual: VirtualTimelineItem) -> VirtualItem {
        switch virtual {
        case .dateDivider(let ts): .dateDivider(date(ts))
        case .readMarker: .readMarker
        case .timelineStart: .timelineStart
        }
    }

    static func map(_ event: EventTimelineItem) -> HaloDomain.TimelineEvent {
        var eventID: EventID?
        if case .eventId(let raw) = event.eventOrTransactionId { eventID = try? EventID(raw) }
        var senderName: String?
        if case .ready(let displayName, _, _, _, _) = event.senderProfile { senderName = displayName }
        return HaloDomain.TimelineEvent(
            eventID: eventID, sender: try? UserID(event.sender), senderName: senderName,
            timestamp: date(event.timestamp), isOwn: event.isOwn, kind: kind(of: event.content))
    }

    static func kind(of content: TimelineItemContent) -> TimelineEventKind {
        switch content {
        case .msgLike(let content): kind(of: content.kind)
        case .roomMembership(let userID, let displayName, let change, _):
            .membership(user: try? UserID(userID), displayName: displayName, change: map(change))
        case .profileChange, .state: .otherState
        default: .unsupported
        }
    }

    static func kind(of kind: MsgLikeKind) -> TimelineEventKind {
        switch kind {
        case .message(let message):
            switch message.msgType {
            case .text: .text(message.body, isEdited: message.isEdited)
            case .notice: .notice(message.body, isEdited: message.isEdited)
            case .emote: .emote(message.body, isEdited: message.isEdited)
            case .image: .media(.image, body: message.body)
            case .video: .media(.video, body: message.body)
            case .audio: .media(.audio, body: message.body)
            case .file: .media(.file, body: message.body)
            default: .unsupported
            }
        case .sticker(let body, _, _): .sticker(body: body)
        case .redacted: .redacted
        case .unableToDecrypt: .undecryptable
        case .poll, .other, .liveLocation: .unsupported
        }
    }

    static func map(_ change: MatrixRustSDK.MembershipChange?) -> HaloDomain.MembershipChange {
        switch change {
        case .joined, .invitationAccepted, .knockAccepted: .joined
        case .left: .left
        case .invited: .invited
        case .kicked: .kicked
        case .banned, .kickedAndBanned: .banned
        case .unbanned: .unbanned
        case .invitationRejected: .invitationRejected
        case .invitationRevoked: .invitationRevoked
        case .knocked: .knocked
        default: .other
        }
    }

    static func date(_ timestamp: UInt64) -> Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}
