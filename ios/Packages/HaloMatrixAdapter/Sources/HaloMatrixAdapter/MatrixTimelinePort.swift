import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `TimelinePort` over the SDK `Timeline` (SDK_INTEGRATION §6). Each session owns its upstream
/// subscriptions and cancels them when its stream ends or it is closed (AGENTS.md §8).
public final class MatrixTimelinePort: TimelinePort {
    private let session: MatrixSessionPort

    /// Timelines prepared for the top of the room list (`warm`), each with its first page loaded. `open` takes one out rather
    /// than sharing it, so a reopened room starts from a fresh timeline instead of everything paginated last time. They belong
    /// to the client that built it, held weakly: a freed client never matches, and a new sign-in never sees them.
    private struct WarmState {
        weak var client: Client?
        var timelines: [RoomID: Timeline] = [:]
        /// Open sessions per room: a room on screen isn't prepared again behind it.
        var open: [RoomID: Int] = [:]
        var running = false
        var pending: [RoomID]?
    }
    private let warmState = Mutex(WarmState())
    static let warmLimit = 6

    public init(session: MatrixSessionPort) { self.session = session }

    /// One warm-up runs at a time; a request arriving meanwhile replaces any waiting one and runs after it.
    public func warm(_ rooms: [RoomID]) async {
        let wanted = Array(rooms.prefix(Self.warmLimit))
        let starts = warmState.withLock { state -> Bool in
            if state.running { state.pending = wanted; return false }
            state.running = true
            return true
        }
        guard starts else { return }
        var next: [RoomID]? = wanted
        while let request = next {
            await warmOnce(request)
            next = warmState.withLock { state in
                let pending = state.pending
                state.pending = nil
                if pending == nil { state.running = false }
                return pending
            }
        }
    }

    private func warmOnce(_ wanted: [RoomID]) async {
        guard let client = try? await session.signedInClient() else { return }
        warmState.withLock { state in
            if state.client !== client { state.client = client; state.timelines = [:] }
            state.timelines = state.timelines.filter { wanted.contains($0.key) }  // rooms that left the top are let go
        }
        for id in wanted {
            let needed = warmState.withLock { state in state.client === client && state.timelines[id] == nil && state.open[id, default: 0] == 0 }
            guard needed, let room = try? await session.room(id), let timeline = try? await room.timeline() else { continue }
            // Kept only with its first page: a failed load would otherwise be served later as an empty room.
            guard (try? await timeline.paginateBackwards(numEvents: 20)) != nil else { continue }
            warmState.withLock { state in
                if state.client === client, state.open[id, default: 0] == 0 { state.timelines[id] = timeline }
            }
        }
    }

    /// Lets go of every prepared timeline (sign-out).
    public func dropWarm() async {
        warmState.withLock { state in
            state.client = nil
            state.timelines = [:]
            state.pending = nil
        }
    }

    private func closed(_ id: RoomID) {
        warmState.withLock { state in
            let count = state.open[id, default: 1] - 1
            state.open[id] = count > 0 ? count : nil
        }
    }

    /// Whether `room` has a prepared timeline waiting (tests).
    func isWarm(_ room: RoomID) -> Bool { warmState.withLock { $0.timelines[room] != nil } }

    public func open(room id: RoomID) async throws(HaloError) -> any TimelineSession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let client = try? await session.signedInClient()
        let ready = warmState.withLock { state -> Timeline? in
            state.open[id, default: 0] += 1
            guard let client, state.client === client else { return nil }
            return state.timelines.removeValue(forKey: id)
        }
        let release: @Sendable () -> Void = { [weak self] in self?.closed(id) }
        if let ready { return MatrixTimelineSession(room: room, timeline: ready, ownUserID: own, release: release) }
        do {
            let timeline = try await room.timeline()
            // Classic sync (D73) doesn't pre-fill a timeline the way sliding sync did: it starts empty and fills from the
            // server. One page is requested at once, in the background; its events arrive through `items()`.
            Task { _ = try? await timeline.paginateBackwards(numEvents: 20) }
            return MatrixTimelineSession(room: room, timeline: timeline, ownUserID: own, release: release)
        } catch {
            release()
            throw ErrorMapper.map(error)
        }
    }

    public func openThread(room id: RoomID, rootEvent: EventID) async throws(HaloError) -> any TimelineSession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let config = TimelineConfiguration(
            focus: .thread(rootEventId: rootEvent.rawValue),
            filter: .all,
            internalIdPrefix: "thread-\(rootEvent.rawValue)",
            dateDividerMode: .daily,
            trackReadReceipts: .allEvents,
            reportUtds: true)
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            Task { _ = try? await timeline.paginateBackwards(numEvents: 20) }
            return MatrixTimelineSession(room: room, timeline: timeline, ownUserID: own)
        } catch {
            throw ErrorMapper.map(error)
        }
    }
}

final class MatrixTimelineSession: TimelineSession {
    private let room: Room
    private let timeline: Timeline
    private let ownUserID: String
    /// Tells the port this session is gone; runs once, on `close` or when the session is dropped.
    private let release: Mutex<(@Sendable () -> Void)?>

    init(room: Room, timeline: Timeline, ownUserID: String, release: @escaping @Sendable () -> Void = {}) {
        self.room = room
        self.timeline = timeline
        self.ownUserID = ownUserID
        self.release = Mutex(release)
    }

    deinit {
        let done = release.withLock { action in
            defer { action = nil }
            return action
        }
        done?()
    }

    func items() -> AsyncStream<HaloDomain.TimelineDiff> {
        let (output, continuation) = AsyncStream<HaloDomain.TimelineDiff>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [timeline, ownUserID] in
            let (raw, rawContinuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: Listener(rawContinuation))
            defer { handle.cancel() }
            for await batch in raw {
                for update in batch { continuation.yield(TimelineMapper.map(update, ownUserID: ownUserID)) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return output
    }

    func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool {
        do { return try await timeline.paginateBackwards(numEvents: count) } catch { throw ErrorMapper.map(error) }
    }

    func send(text: String, mentions: [Mention]) async throws(HaloError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do {
            // Markdown is converted to the message content (formatted body) by the SDK. The returned handle (to abort
            // a queued send) isn't needed yet; failed sends are retried by the send queue.
            _ = try await timeline.send(msg: Self.content(text, mentions))
        } catch { throw ErrorMapper.map(error) }
    }

    /// The message content: mentions as `matrix.to` links in the formatted body plus `m.mentions`.
    private static func content(_ text: String, _ mentions: [Mention]) -> RoomMessageEventContentWithoutRelation {
        let formatted = MentionFormatter.apply(text, mentions: mentions)
        let content = messageEventContentFromMarkdown(md: formatted.markdown)
        return formatted.users.isEmpty ? content : content.withMentions(mentions: Mentions(userIds: formatted.users.map(\.rawValue), room: false))
    }

    /// Upper bound on `@`-mention autocomplete candidates scanned in `members()` so a 10,000-member room doesn't
    /// exhaust the FFI iterator on the first `@` keystroke (`ROADMAP.md` M5 performance pass).
    static let maxMentionCandidates = 1_000

    func members() async throws(HaloError) -> [HaloDomain.RoomMember] {
        do {
            let iterator = try await room.members()
            var result: [HaloDomain.RoomMember] = []
            while result.count < Self.maxMentionCandidates, let chunk = iterator.nextChunk(chunkSize: 200) {
                for member in chunk where member.membership == .join {
                    guard let user = try? UserID(member.userId), member.userId != ownUserID else { continue }
                    result.append(HaloDomain.RoomMember(user: user, displayName: member.displayName))
                    if result.count >= Self.maxMentionCandidates { break }
                }
            }
            return result
        } catch { throw ErrorMapper.map(error) }
    }

    func typingUsers() -> AsyncStream<[UserID]> {
        let (output, continuation) = AsyncStream<[UserID]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = room.subscribeToTypingNotifications(listener: TypingListener(own: ownUserID, continuation: continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return output
    }

    func setTyping(_ isTyping: Bool) async throws(HaloError) {
        do { try await room.typingNotice(isTyping: isTyping) } catch { throw ErrorMapper.map(error) }
    }

    func reply(to event: EventID, text: String, mentions: [Mention]) async throws(HaloError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do { _ = try await timeline.sendReply(msg: Self.content(text, mentions), eventId: event.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    func toggleReaction(on event: EventID, key: String) async throws(HaloError) {
        do { _ = try await timeline.toggleReaction(itemId: .eventId(eventId: event.rawValue), key: key) } catch { throw ErrorMapper.map(error) }
    }

    func edit(event: EventID, newText: String) async throws(HaloError) {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
        do {
            try await timeline.edit(
                eventOrTransactionId: .eventId(eventId: event.rawValue),
                newContent: .roomMessage(content: messageEventContentFromMarkdown(md: newText)))
        } catch { throw ErrorMapper.map(error) }
    }

    func addReaction(on event: EventID, key: String) async throws(HaloError) -> Bool {
        do {
            let item = try await timeline.getEventTimelineItemByEventId(eventId: event.rawValue)
            let reacted = item.reactions.contains { reaction in reaction.key == key && reaction.senders.contains { $0.senderId == ownUserID } }
            if reacted { return false }
            _ = try await timeline.toggleReaction(itemId: .eventId(eventId: event.rawValue), key: key)
            return true
        } catch { throw ErrorMapper.map(error) }
    }

    func editHistory(of event: EventID) async throws(HaloError) -> [EditRevision] {
        do {
            return try await timeline.editRevisions(eventId: event.rawValue).map { record in
                let text: String
                switch TimelineMapper.kind(of: record.content) {
                case .text(let body, _), .notice(let body, _), .emote(let body, _): text = body
                default: text = ""
                }
                return EditRevision(text: text, timestamp: record.timestamp.map { TimelineMapper.date($0) })
            }
        } catch { throw ErrorMapper.map(error) }
    }

    func delete(event: EventID) async throws(HaloError) {
        do { try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: event.rawValue), reason: nil) } catch { throw ErrorMapper.map(error) }
    }

    func sendSticker(_ sticker: Sticker) async throws(HaloError) {
        do {
            // Not through the send queue: `send_raw` sends at once and fails when offline.
            _ = try await room.sendRaw(eventType: "m.sticker", content: try Self.stickerContent(sticker), requestConfigOverride: nil)
        } catch { throw ErrorMapper.map(error) }
    }

    /// The `m.sticker` content as JSON. `info` is always present, empty when the pack gives no details: the spec requires it, and
    /// the SDK (Ruma) refuses a sticker without it, which then shows as an unsupported event for everyone using it.
    static func stickerContent(_ sticker: Sticker) throws -> String {
        var info: [String: Any] = [:]
        if let i = sticker.info {
            if let w = i.width { info["w"] = w }
            if let h = i.height { info["h"] = h }
            if let m = i.mimeType { info["mimetype"] = m }
            if let size = i.size { info["size"] = size }
        }
        let content: [String: Any] = ["body": sticker.eventBody, "url": sticker.url, "info": info]
        return String(decoding: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self)
    }

    func sendImage(_ image: OutgoingImage) async throws(HaloError) {
        try image.validate()
        let info = ImageInfo(
            height: image.height.map(UInt64.init), width: image.width.map(UInt64.init), mimetype: image.mimeType, size: UInt64(image.data.count),
            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: image.mimeType == "image/gif")
        let params = UploadParameters(
            source: .data(bytes: image.data, filename: image.filename), caption: image.caption, formattedCaption: nil, mentions: nil, inReplyTo: nil)
        do {
            let handle = try timeline.sendAttachment(params: params, attachment: .image(imageInfo: info, thumbnailSource: nil))
            try await handle.join()
        } catch { throw ErrorMapper.map(error) }
    }

    func sendFile(_ file: OutgoingFile) async throws(HaloError) {
        try file.validate()
        let params = UploadParameters(
            source: .data(bytes: file.data, filename: file.filename), caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: nil)
        let size = UInt64(file.data.count)
        do {
            let handle: SendAttachmentJoinHandle
            switch file.kind {
            case .audio:
                handle = try timeline.sendAudio(params: params, audioInfo: AudioInfo(duration: nil, size: size, mimetype: file.mimeType))
            case .video:
                handle = try timeline.sendVideo(
                    params: params, thumbnailSource: nil,
                    videoInfo: VideoInfo(duration: nil, height: nil, width: nil, mimetype: file.mimeType, size: size, thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil))
            case .file:
                handle = try timeline.sendFile(params: params, fileInfo: FileInfo(mimetype: file.mimeType, size: size, thumbnailInfo: nil, thumbnailSource: nil))
            }
            try await handle.join()
        } catch { throw ErrorMapper.map(error) }
    }

    func retrySend(localID: String) async throws(HaloError) {
        do {
            guard try await timeline.retrySend(itemId: .transactionId(transactionId: localID), target: .event) else {
                throw HaloError.notFound
            }
        } catch let error as HaloError {
            throw error
        } catch {
            // Map EventNotInTimeline to `.notFound` while preserving all other SDK errors (R-27).
            throw ErrorMapper.mapLocalEcho(error)
        }
        // `retrySend` only unparks an unrecoverable failure; a recoverable one (offline) disabled the room's send queue and goes
        // out once it is enabled again. Enabled after the unpark, so the echo is still there to be found.
        room.enableSendQueue(enable: true)
    }

    func abortSend(localID: String) async throws(HaloError) {
        do {
            guard try await timeline.abortSend(itemId: .transactionId(transactionId: localID), target: .event) else {
                throw HaloError.notFound
            }
        } catch let error as HaloError {
            throw error
        } catch {
            throw ErrorMapper.mapLocalEcho(error)
        }
    }

    func latestEventID() async -> EventID? {
        guard let raw = await timeline.latestEventId() else { return nil }
        return try? EventID(raw)
    }

    func close() async {
        let done = release.withLock { action in
            defer { action = nil }
            return action
        }
        done?()
    }
}

private final class Listener: TimelineListener {
    private let continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation
    init(_ continuation: AsyncStream<[MatrixRustSDK.TimelineDiff]>.Continuation) { self.continuation = continuation }
    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) { continuation.yield(diff) }
}

/// Forwards the SDK's typing set, without the signed-in user.
private final class TypingListener: TypingNotificationsListener {
    let own: String
    let continuation: AsyncStream<[UserID]>.Continuation
    init(own: String, continuation: AsyncStream<[UserID]>.Continuation) {
        self.own = own
        self.continuation = continuation
    }

    func call(typingUserIds: [String]) {
        continuation.yield(typingUserIds.filter { $0 != own }.compactMap { try? UserID($0) })
    }
}
