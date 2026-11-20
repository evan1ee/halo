import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// Maps upstream timeline items to Halo's. Names that exist on both sides are written module-qualified.
enum TimelineMapper {
    static func map(_ update: MatrixRustSDK.TimelineDiff, ownUserID: String) -> HaloDomain.TimelineDiff {
        func convert(_ item: MatrixRustSDK.TimelineItem) -> HaloDomain.TimelineItem { map(item, ownUserID: ownUserID) }
        switch update {
        case .append(let values): return .append(values.map(convert))
        case .clear: return .clear
        case .pushFront(let value): return .pushFront(convert(value))
        case .pushBack(let value): return .pushBack(convert(value))
        case .popFront: return .popFront
        case .popBack: return .popBack
        case .insert(let index, let value): return .insert(index: Int(index), convert(value))
        case .set(let index, let value): return .set(index: Int(index), convert(value))
        case .remove(let index): return .remove(index: Int(index))
        case .truncate(let length): return .truncate(length: Int(length))
        case .reset(let values): return .reset(values.map(convert))
        }
    }

    static func map(_ item: MatrixRustSDK.TimelineItem, ownUserID: String) -> HaloDomain.TimelineItem {
        let id = TimelineItemID(item.uniqueId().id)
        if let event = item.asEvent() { return HaloDomain.TimelineItem(id: id, content: .event(map(event, ownUserID: ownUserID))) }
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

    static func map(_ event: EventTimelineItem, ownUserID: String) -> HaloDomain.TimelineEvent {
        var eventID: EventID?
        var localID: String?
        switch event.eventOrTransactionId {
        case .eventId(let raw): eventID = try? EventID(raw)
        case .transactionId(let raw): localID = raw
        }
        var senderName: String?
        var senderAvatar: MediaRef?
        if case .ready(let displayName, _, let avatarUrl, _, _) = event.senderProfile {
            senderName = displayName
            senderAvatar = MatrixRoomListPort.avatar(avatarUrl)
        }
        return HaloDomain.TimelineEvent(
            eventID: eventID, sender: try? UserID(event.sender), senderName: senderName,
            timestamp: date(event.timestamp), isOwn: event.isOwn, kind: kind(of: event.content),
            sendState: sendState(of: event.localSendState),
            reactions: event.reactions.map { reaction in
                ReactionSummary(key: reaction.key, count: reaction.senders.count, reactedByMe: reaction.senders.contains { $0.senderId == ownUserID })
            },
            replyTo: replyPreview(of: event.content), formattedBody: formattedHTML(of: event.content),
            localID: localID, senderAvatar: senderAvatar)
    }

    /// The HTML body of a text message, if the sender gave one in the standard format.
    static func formattedHTML(of content: TimelineItemContent) -> String? {
        guard case .msgLike(let msgLike) = content, case .message(let message) = msgLike.kind, case .text(let text) = message.msgType,
              let formatted = text.formatted, case .html = formatted.format else { return nil }
        return formatted.body
    }

    /// The quoted message of a reply. Text-like originals give a snippet; anything else (not loaded, encrypted, media)
    /// leaves it `nil` rather than guessing.
    static func replyPreview(of content: TimelineItemContent) -> ReplyPreview? {
        guard case .msgLike(let msgLike) = content, let details = msgLike.inReplyTo, let id = try? EventID(details.eventId()) else { return nil }
        guard case .ready(let original, _, let profile, _, _) = details.event() else { return ReplyPreview(eventID: id, senderName: nil, snippet: nil) }
        var name: String?
        if case .ready(let displayName, _, _, _, _) = profile { name = displayName }
        var snippet: String?
        switch kind(of: original) {
        case .text(let body, _), .notice(let body, _), .emote(let body, _): snippet = body
        case .media(let attachment): snippet = attachment.body
        default: break
        }
        return ReplyPreview(eventID: id, senderName: name, snippet: snippet)
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
            case .image(let content):
                .media(MediaAttachment(
                    kind: .image, body: message.body, source: ref(content.source),
                    width: content.info?.width.map(Int.init), height: content.info?.height.map(Int.init)))
            case .video(let content):
                .media(MediaAttachment(
                    kind: .video, body: message.body, source: ref(content.source),
                    width: content.info?.width.map(Int.init), height: content.info?.height.map(Int.init),
                    mimeType: content.info?.mimetype, size: content.info?.size.map(Int.init), duration: content.info?.duration,
                    thumbnail: content.info?.thumbnailSource.map(ref)))
            case .audio(let content):
                .media(MediaAttachment(
                    kind: .audio, body: message.body, source: ref(content.source),
                    mimeType: content.info?.mimetype, size: content.info?.size.map(Int.init), duration: content.info?.duration))
            case .file(let content):
                .media(MediaAttachment(
                    kind: .file, body: message.body, source: ref(content.source),
                    mimeType: content.info?.mimetype, size: content.info?.size.map(Int.init)))
            default: .unsupported
            }
        case .sticker(let body, _, let source): .sticker(body: body, source: ref(source))
        case .redacted: .redacted
        case .unableToDecrypt(let message): .undecryptable(reason(of: message))
        case .poll, .other, .liveLocation: .unsupported
        }
    }

    /// `nil` means the event came from the server.
    static func sendState(of state: EventSendState?) -> SendState {
        switch state {
        case nil, .sent: .sent
        case .notSentYet: .sending
        case .sendingFailed(_, let isRecoverable): .failed(recoverable: isRecoverable)
        }
    }

    static func reason(of message: EncryptedMessage) -> UTDReason {
        guard case .megolmV1AesSha2(_, let cause) = message else { return .unknown }
        return switch cause {
        case .sentBeforeWeJoined: .sentBeforeJoining
        case .unsignedDevice, .unknownDevice: .keysNotShared
        case .verificationViolation: .senderVerificationProblem
        case .historicalMessageAndBackupIsDisabled: .backupDisabled
        default: .unknown
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

    /// The opaque reference the media port later turns back into an upstream `MediaSource`.
    static func ref(_ source: MediaSource) -> MediaRef { MediaRef(token: source.toJson()) }

    static func date(_ timestamp: UInt64) -> Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
}
