import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// Maps upstream messages to what search finds them by. Mapped at once in the callbacks: no upstream type is kept.
enum SearchMapper {
    /// One item of a history timeline.
    enum Item: Sendable, Equatable {
        case message(SearchIndexEntry)
        case undecryptable(EventID, Date, threadRoot: EventID?)
        case other(EventID, Date, threadRoot: EventID?)
        /// A date divider or marker.
        case none

        var event: (id: EventID, time: Date, threadRoot: EventID?)? {
            switch self {
            case .message(let entry): (entry.event, entry.timestamp, entry.threadRoot)
            case .undecryptable(let id, let time, let root), .other(let id, let time, let root): (id, time, root)
            case .none: nil
            }
        }
    }

    static func map(_ diff: MatrixRustSDK.TimelineDiff, room: RoomID) -> ListDiff<Item> {
        func convert(_ item: MatrixRustSDK.TimelineItem) -> Item { map(item, room: room) }
        switch diff {
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

    static func map(_ item: MatrixRustSDK.TimelineItem, room: RoomID) -> Item {
        guard let event = item.asEvent(), case .eventId(let raw) = event.eventOrTransactionId, let id = try? EventID(raw) else { return .none }
        let time = TimelineMapper.date(event.timestamp)
        guard case .msgLike(let content) = event.content else { return .other(id, time, threadRoot: nil) }
        let root = content.threadRoot.flatMap { try? EventID($0) }
        let found: SearchableContent?
        switch content.kind {
        case .message(let message): found = self.content(of: message.msgType)
        case .poll(let question, _, _, let answers, _, _, _): found = SearchContent.poll(question: question, options: answers.map(\.text))
        case .unableToDecrypt: return .undecryptable(id, time, threadRoot: root)
        default: found = nil
        }
        guard let found, let sender = try? UserID(event.sender) else { return .other(id, time, threadRoot: root) }
        var name: String?
        if case .ready(let displayName, _, _, _, _) = event.senderProfile { name = displayName }
        return .message(SearchIndexEntry(room: room, event: id, sender: sender, senderName: name, threadRoot: root, timestamp: time, content: found))
    }

    /// `nil` for a type without words (a location, an unknown type).
    static func content(of type: MessageType) -> SearchableContent? {
        switch type {
        case .text(let content): SearchContent.text(content.body, html: content.formatted?.body)
        case .notice(let content): SearchContent.text(content.body, html: content.formatted?.body)
        case .emote(let content): SearchContent.text(content.body, html: content.formatted?.body)
        case .image(let content):
            SearchContent.attachment(
                .image, filename: content.filename, caption: content.caption,
                mimeType: content.info?.mimetype, sizeBytes: clampedInt(content.info?.size),
                thumbnail: TimelineMapper.ref(content.info?.thumbnailSource ?? content.source))
        case .video(let content):
            SearchContent.attachment(
                .video, filename: content.filename, caption: content.caption,
                mimeType: content.info?.mimetype, sizeBytes: clampedInt(content.info?.size),
                thumbnail: content.info?.thumbnailSource.map(TimelineMapper.ref))
        case .audio(let content):
            SearchContent.attachment(
                .audio, filename: content.filename, caption: content.caption,
                mimeType: content.info?.mimetype, sizeBytes: clampedInt(content.info?.size))
        case .file(let content):
            SearchContent.attachment(
                .file, filename: content.filename, caption: content.caption,
                mimeType: content.info?.mimetype, sizeBytes: clampedInt(content.info?.size),
                thumbnail: content.info?.thumbnailSource.map(TimelineMapper.ref))
        case .gallery(let content):
            gallery(
                body: content.body,
                names: content.itemtypes.map { item in
                    switch item {
                    case .image(let content): content.filename
                    case .audio(let content): content.filename
                    case .video(let content): content.filename
                    case .file(let content): content.filename
                    case .other(_, let body): body
                    }
                },
                firstPreview: content.itemtypes.lazy.compactMap { item -> SearchAttachment? in
                    switch item {
                    case .image(let c):
                        SearchAttachment(
                            mediaKind: .image, filename: c.filename, mimeType: c.info?.mimetype,
                            sizeBytes: clampedInt(c.info?.size), thumbnail: TimelineMapper.ref(c.info?.thumbnailSource ?? c.source))
                    case .video(let c):
                        SearchAttachment(
                            mediaKind: .video, filename: c.filename, mimeType: c.info?.mimetype,
                            sizeBytes: clampedInt(c.info?.size), thumbnail: c.info?.thumbnailSource.map(TimelineMapper.ref))
                    default: nil
                    }
                }.first)
        case .location, .other: nil
        }
    }

    static func clampedInt(_ value: UInt64?) -> Int? { value.map { Int(clamping: $0) } }

    private static func gallery(body: String, names: [String], firstPreview: SearchAttachment? = nil) -> SearchableContent? {
        let shown = body.isEmpty ? names.joined(separator: ", ") : body
        return shown.isEmpty ? nil : SearchableContent(kind: .media, body: shown, extra: names, attachment: firstPreview)
    }

    enum ServerAnswer: Equatable {
        case result(SearchRecheck)
        case encryptedEdit
    }

    /// An event as the server returns it, with the newest edit it bundles.
    static func recheck(_ event: [String: Any]) -> ServerAnswer {
        let unsigned = event["unsigned"] as? [String: Any] ?? [:]
        let content = event["content"] as? [String: Any] ?? [:]
        guard !content.isEmpty, unsigned["redacted_because"] == nil else { return .result(.gone) }
        guard let edit = (unsigned["m.relations"] as? [String: Any])?["m.replace"] as? [String: Any], edit["sender"] as? String == event["sender"] as? String else { return .result(.unchanged) }
        if edit["type"] as? String == "m.room.encrypted" { return .encryptedEdit }
        guard let body = edit["content"] as? [String: Any], let json = try? JSONSerialization.data(withJSONObject: body),
              let new = SearchContent.parse(message: String(decoding: json, as: UTF8.self))?.content else { return .result(.unchanged) }
        return .result(.edited(new))
    }

    /// The newest readable edit among `related`.
    static func edit(of event: MatrixRustSDK.TimelineEvent, related: [MatrixRustSDK.TimelineEvent]) -> SearchRecheck {
        for edit in related.filter({ $0.senderId() == event.senderId() }).sorted(by: { $0.timestamp() > $1.timestamp() }) {
            guard case .messageLike(.roomMessage(let type, _)) = try? edit.content(), let content = self.content(of: type) else { continue }
            // The fallback of an edit is its text after "* ".
            let body = content.body.hasPrefix("* ") ? String(content.body.dropFirst(2)) : content.body
            return .edited(SearchableContent(kind: content.kind, body: body, extra: content.extra, attachment: content.attachment))
        }
        return .unchanged
    }
}
