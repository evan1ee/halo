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

    /// Short-lived in-memory overlay of server-confirmed pin/unpin writes so leaving and immediately re-entering a room
    /// reflects the confirmed change even before the next sync tick updates `roomInfo().pinnedEventIds` or `accountData`.
    private let pinStore = PinOverlayStore()

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
        guard let client = try? await session.signedInClient() else { return }  // best-effort: a read; the caller falls back to a default and nothing changes
        warmState.withLock { state in
            if state.client !== client { state.client = client; state.timelines = [:] }
            state.timelines = state.timelines.filter { wanted.contains($0.key) }  // rooms that left the top are let go
        }
        for id in wanted {
            let needed = warmState.withLock { state in state.client === client && state.timelines[id] == nil && state.open[id, default: 0] == 0 }
            guard needed, let room = try? await session.room(id), let timeline = try? await room.timeline() else { continue }  // best-effort: a read; the caller falls back to a default and nothing changes
            // Kept only with its first page: a failed load would otherwise be served later as an empty room.
            guard (try? await timeline.paginateBackwards(numEvents: 20)) != nil else { continue }  // best-effort: a read; the caller falls back to a default and nothing changes
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

    /// Requests the first page of history and waits for it for at most 400 ms (it keeps loading afterwards).
    private static func firstPage(of timeline: Timeline) async {
        let page = Task { _ = try? await timeline.paginateBackwards(numEvents: 20) }  // best-effort: a read; the caller falls back to a default and nothing changes
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await page.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(400)) }
            await group.next()
            group.cancelAll()
        }
    }

    public func open(room id: RoomID) async throws(HaloError) -> any TimelineSession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let client = try? await session.signedInClient()  // best-effort: a read; the caller falls back to a default and nothing changes
        let ready = warmState.withLock { state -> Timeline? in
            state.open[id, default: 0] += 1
            guard let client, state.client === client else { return nil }
            return state.timelines.removeValue(forKey: id)
        }
        let release: @Sendable () -> Void = { [weak self] in self?.closed(id) }
        if let ready { return MatrixTimelineSession(pinStore: pinStore, session: session, roomID: id, room: room, timeline: ready, ownUserID: own, release: release) }
        do {
            let timeline = try await room.timeline()
            // Classic sync (D73) doesn't pre-fill a timeline the way sliding sync did: it starts empty and fills from the
            // server. Like a warm timeline, the first page is put in place before the first snapshot, so history never
            // arrives above the newest row right after the opening scroll. Bounded, so a room that needs the network
            // doesn't hold the open up; the page keeps loading in the background then.
            await Self.firstPage(of: timeline)
            return MatrixTimelineSession(pinStore: pinStore, session: session, roomID: id, room: room, timeline: timeline, ownUserID: own, release: release)
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
            reportUtds: false)  // `true` needs a hook on the client; without one the SDK refuses the timeline
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            await Self.firstPage(of: timeline)
            return MatrixTimelineSession(pinStore: pinStore, session: session, roomID: id, room: room, timeline: timeline, ownUserID: own)
        } catch {
            throw ErrorMapper.map(error)
        }
    }

    /// The SDK keeps what a focused timeline loads for the life of the client (F-FFI-26): about 0.5 KB per event, so a jump costs little.
    public func openFocused(room id: RoomID, event: EventID) async throws(HaloError) -> any TimelineSession {
        let room = try await session.room(id)
        let own = try await session.ownUserID()
        let config = TimelineConfiguration(
            focus: .event(eventId: event.rawValue, numContextEvents: 30, threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: "focus-\(event.rawValue)", dateDividerMode: .daily, trackReadReceipts: .disabled, reportUtds: false)
        do {
            let timeline = try await room.timelineWithConfiguration(configuration: config)
            return MatrixTimelineSession(pinStore: pinStore, session: session, roomID: id, room: room, timeline: timeline, ownUserID: own)
        } catch { throw ErrorMapper.mapFocus(error) }
    }
}

final class PinOverlayStore: Sendable {
    private struct State {
        weak var client: Client?
        var added: [RoomID: [EventID]] = [:]
        var removed: [RoomID: Set<EventID>] = [:]
    }
    private let state = Mutex(State())

    func recordPin(_ event: EventID, in room: RoomID, client: Client) {
        state.withLock { s in
            if s.client !== client { s = State(client: client) }
            s.removed[room]?.remove(event)
            var list = s.added[room] ?? []
            if !list.contains(event) { list.append(event) }
            s.added[room] = list
        }
    }

    func recordUnpin(_ event: EventID, in room: RoomID, client: Client) {
        state.withLock { s in
            if s.client !== client { s = State(client: client) }
            s.added[room]?.removeAll { $0 == event }
            var set = s.removed[room] ?? []
            set.insert(event)
            s.removed[room] = set
        }
    }

    func apply(to base: [EventID], in room: RoomID, client: Client) -> [EventID] {
        state.withLock { s in
            guard s.client === client else { return base }
            let removed = s.removed[room] ?? []
            let added = s.added[room] ?? []
            var result: [EventID] = []
            var seen: Set<EventID> = []
            for id in base where !removed.contains(id) && seen.insert(id).inserted { result.append(id) }
            for id in added where !removed.contains(id) && seen.insert(id).inserted { result.append(id) }
            return result
        }
    }
}

final class MatrixTimelineSession: TimelineSession {
    private let pinStore: PinOverlayStore
    private let session: MatrixSessionPort
    private let roomID: RoomID
    private let room: Room
    private let timeline: Timeline
    private let ownUserID: String
    /// Tells the port this session is gone; runs once, on `close` or when the session is dropped.
    private let release: Mutex<(@Sendable () -> Void)?>
    /// The send handles of own messages that failed for an encryption reason ("send anyway", AC-SEC-2).
    private let sendHandles = SendHandleStore()

    init(pinStore: PinOverlayStore, session: MatrixSessionPort, roomID: RoomID, room: Room, timeline: Timeline, ownUserID: String, release: @escaping @Sendable () -> Void = {}) {
        self.pinStore = pinStore
        self.session = session
        self.roomID = roomID
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
        let handles = sendHandles
        let task = Task { [timeline, ownUserID] in
            let (raw, rawContinuation) = AsyncStream<[MatrixRustSDK.TimelineDiff]>.makeStream(bufferingPolicy: .unbounded)
            let handle = await timeline.addListener(listener: Listener(rawContinuation))
            defer { handle.cancel() }
            // The SDK confirms a local echo as remove + push of the same item; folded into one `set` so the row (and its
            // photo) never leaves the list (TimelineDiffCoalescer).
            var coalescer = TimelineDiffCoalescer()
            for await batch in raw {
                for diff in coalescer.coalesce(batch.map { TimelineMapper.map($0, ownUserID: ownUserID, handles: handles) }) { continuation.yield(diff) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return output
    }

    func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool {
        do { return try await timeline.paginateBackwards(numEvents: count) } catch { throw ErrorMapper.map(error) }
    }

    func paginateForwards(count: UInt16) async throws(HaloError) -> Bool {
        do { return try await timeline.paginateForwards(numEvents: count) } catch { throw ErrorMapper.map(error) }
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

    func sendAnyway(localID: String) async throws(HaloError) {
        guard let entry = sendHandles.entry(localID: localID) else { throw .notFound }
        do {
            switch entry.error {
            case .insecureDevices(let devices): try await room.ignoreDeviceTrustAndResend(devices: devices, sendHandle: entry.handle)
            case .identityViolations(let users): try await room.withdrawVerificationAndResend(userIds: users, sendHandle: entry.handle)
            default: throw HaloError.notFound
            }
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
        sendHandles.forget(localID: localID)
    }

    func identityAlerts() -> AsyncStream<[IdentityAlert]> {
        let (output, continuation) = AsyncStream<[IdentityAlert]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let listener = IdentityListener(own: ownUserID, continuation: continuation)
        // The SDK reports the state of the members it knows when the subscription starts, then changes.
        let room = self.room
        let subscription = Task { try? await room.subscribeToIdentityStatusChanges(listener: listener) }  // best-effort: a read; the caller falls back to a default and nothing changes
        continuation.onTermination = { _ in Task { await subscription.value?.cancel() } }
        return output
    }

    func acceptIdentity(of user: UserID) async throws(HaloError) {
        do {
            guard let identity = try await session.userIdentity(user.rawValue) else { throw HaloError.notFound }
            // A verified contact whose identity changed stays "in violation" until verification is withdrawn or redone.
            if identity.wasPreviouslyVerified() { try await identity.withdrawVerification() }
            try await identity.pin()
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
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
            if let w = i.width, w > 0 { info["w"] = w }
            if let h = i.height, h > 0 { info["h"] = h }
            if let m = i.mimeType, !m.isEmpty { info["mimetype"] = m }
            if let size = i.size, size > 0 { info["size"] = size }
        }
        let body = sticker.eventBody.isEmpty ? "sticker" : sticker.eventBody
        let content: [String: Any] = ["body": body, "url": sticker.url, "info": info]
        return String(decoding: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self)
    }

    func sendImage(_ image: OutgoingImage) async throws(HaloError) {
        try image.validate()
        let thumbInfo = image.thumbnail.map {
            ThumbnailInfo(height: UInt64($0.height), width: UInt64($0.width), mimetype: $0.mimeType, size: UInt64($0.data.count))
        }
        let thumbSource = image.thumbnail.map {
            UploadSource.data(bytes: $0.data, filename: "thumb-\(image.filename)")
        }
        let info = ImageInfo(
            height: image.height.map(UInt64.init), width: image.width.map(UInt64.init), mimetype: image.mimeType, size: UInt64(image.data.count),
            thumbnailInfo: thumbInfo, thumbnailSource: nil, blurhash: nil, isAnimated: image.mimeType == "image/gif")
        let params = UploadParameters(
            source: .data(bytes: image.data, filename: image.filename), caption: image.caption, formattedCaption: nil, mentions: nil, inReplyTo: nil)
        do {
            let handle = try timeline.sendAttachment(params: params, attachment: .image(imageInfo: info, thumbnailSource: thumbSource))
            try await handle.join()
        } catch { throw ErrorMapper.map(error) }
    }

    func sendFile(_ file: OutgoingFile) async throws(HaloError) {
        try file.validate()
        let uploadSource: UploadSource = file.fileURL.map { .file(filename: $0.path) } ?? .data(bytes: file.data, filename: file.filename)
        let params = UploadParameters(
            source: uploadSource, caption: file.caption, formattedCaption: nil, mentions: nil, inReplyTo: nil)
        let size = UInt64(file.byteCount)
        do {
            let handle: SendAttachmentJoinHandle
            switch file.kind {
            case .audio:
                let audioInfo = AudioInfo(duration: file.duration, size: size, mimetype: file.mimeType)
                if file.isVoiceMessage {
                    handle = try timeline.sendAttachment(params: params, attachment: .voice(audioInfo: audioInfo, waveform: file.waveform ?? []))
                } else {
                    handle = try timeline.sendAttachment(params: params, attachment: .audio(audioInfo: audioInfo))
                }
            case .video:
                let thumbInfo = file.thumbnail.map {
                    ThumbnailInfo(height: UInt64($0.height), width: UInt64($0.width), mimetype: $0.mimeType, size: UInt64($0.data.count))
                }
                let thumbSource = file.thumbnail.map {
                    UploadSource.data(bytes: $0.data, filename: "thumb-\(file.filename).jpg")
                }
                handle = try timeline.sendAttachment(
                    params: params,
                    attachment: .video(
                        videoInfo: VideoInfo(
                            duration: file.duration, height: file.height.map(UInt64.init), width: file.width.map(UInt64.init),
                            mimetype: file.mimeType, size: size,
                            thumbnailInfo: thumbInfo, thumbnailSource: nil, blurhash: nil),
                        thumbnailSource: thumbSource))
            case .file:
                handle = try timeline.sendAttachment(
                    params: params,
                    attachment: .file(fileInfo: FileInfo(mimetype: file.mimeType, size: size, thumbnailInfo: nil, thumbnailSource: nil)))
            }
            try await handle.join()
        } catch { throw ErrorMapper.map(error) }
    }

    func sendLocation(_ location: OutgoingLocation) async throws(HaloError) {
        try location.validate()
        do {
            try await timeline.sendLocation(
                body: location.body, geoUri: location.geoURI, description: location.description, zoomLevel: 15,
                assetType: location.isOwnLocation ? .sender : .pin, repliedToEventId: nil)
        } catch { throw ErrorMapper.map(error) }
    }

    func createPoll(_ poll: OutgoingPoll) async throws(HaloError) {
        try poll.validate()
        do {
            try await timeline.createPoll(
                question: poll.question, answers: poll.answers, maxSelections: UInt8(clamping: poll.maxSelections),
                pollKind: poll.hidesResultsUntilEnd ? .undisclosed : .disclosed)
        } catch { throw ErrorMapper.map(error) }
    }

    func votePoll(pollEventID: EventID, answers: [String]) async throws(HaloError) {
        do {
            try await timeline.sendPollResponse(pollStartEventId: pollEventID.rawValue, answers: answers)
        } catch { throw ErrorMapper.map(error) }
    }

    func endPoll(pollEventID: EventID, fallbackText: String) async throws(HaloError) {
        do {
            try await timeline.endPoll(pollStartEventId: pollEventID.rawValue, text: fallbackText)
        } catch { throw ErrorMapper.map(error) }
    }

    func pinnedEventIDs() async -> [EventID] {
        var result: [EventID] = []
        var seen: Set<EventID> = []
        if let info = try? await room.roomInfo() {  // best-effort: a read; the caller falls back to a default and nothing changes
            for raw in info.pinnedEventIds {
                if let id = try? EventID(raw), seen.insert(id).inserted { result.append(id) }
            }
        }
        guard let client = try? await session.signedInClient() else { return result }  // best-effort: a read; the caller falls back to a default and nothing changes
        if let content = await readPersonalPins(client: client) {
            for id in PersonalPinnedEvents.pinned(in: roomID, from: content) where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return pinStore.apply(to: result, in: roomID, client: client)
    }

    func pin(event: EventID) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            _ = try await timeline.pinEvent(eventId: event.rawValue)
            pinStore.recordPin(event, in: roomID, client: client)
            return
        } catch {
            let mapped = ErrorMapper.map(error)
            // Network/auth failures propagate; permission or SDK-wrapped room-state errors fall back to personal pins
            // so normal room members (PL 0) can pin messages in any room.
            if case .network = mapped { throw mapped }
            if case .unauthorized = mapped { throw mapped }
        }
        do {
            try await ServerAccountData(client).update(PersonalPinnedEvents.eventType) {
                PersonalPinnedEvents.pinning(event, in: roomID, content: $0)
            }
            pinStore.recordPin(event, in: roomID, client: client)
        } catch { throw ErrorMapper.map(error) }
    }

    func unpin(event: EventID) async throws(HaloError) {
        let client = try await session.signedInClient()
        var removedPersonal = false
        do {
            try await ServerAccountData(client).update(PersonalPinnedEvents.eventType) {
                let updated = PersonalPinnedEvents.unpinning(event, in: roomID, content: $0)
                removedPersonal = updated != nil
                return updated
            }
        } catch { throw ErrorMapper.map(error) }
        let isRoomPinned = (try? await room.roomInfo().pinnedEventIds.contains(event.rawValue)) ?? false  // best-effort: a read; the caller falls back to a default and nothing changes
        if isRoomPinned || !removedPersonal {
            do {
                _ = try await timeline.unpinEvent(eventId: event.rawValue)
            } catch {
                let mapped = ErrorMapper.map(error)
                if !(removedPersonal && (mapped == .forbidden || mapped == .internal(code: "SDK_GENERIC"))) {
                    throw mapped
                }
            }
        }
        pinStore.recordUnpin(event, in: roomID, client: client)
    }

    private func readPersonalPins(client: Client) async -> [String: Any]? {
        guard let json = try? await client.accountData(eventType: PersonalPinnedEvents.eventType) else { return nil }  // best-effort: a read; the caller falls back to a default and nothing changes
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
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

/// Keeps who is in a changed state and forwards the whole set on every change (the SDK reports differences only).
private final class IdentityListener: IdentityStatusChangeListener {
    private let own: String
    private let continuation: AsyncStream<[IdentityAlert]>.Continuation
    private let states = Mutex<[String: IdentityAlert.Kind]>([:])

    init(own: String, continuation: AsyncStream<[IdentityAlert]>.Continuation) {
        self.own = own
        self.continuation = continuation
    }

    func call(identityStatusChange: [IdentityStatusChange]) {
        let alerts = states.withLock { states -> [IdentityAlert] in
            for change in identityStatusChange where change.userId != own {
                switch change.changedTo {
                case .pinViolation: states[change.userId] = .changed
                case .verificationViolation: states[change.userId] = .verifiedBefore
                case .verified, .pinned: states[change.userId] = nil
                }
            }
            return states.compactMap { id, kind in (try? UserID(id)).map { IdentityAlert(user: $0, kind: kind) } }
                .sorted { $0.user.rawValue < $1.user.rawValue }
        }
        continuation.yield(alerts)
    }
}

/// What "send anyway" needs for a failed own message: the SDK's handle on it and the error that stopped it.
final class SendHandleStore: Sendable {
    struct Entry { let handle: SendHandle; let error: QueueWedgeError }
    private let entries = Mutex<[String: Entry]>([:])

    func remember(localID: String, handle: SendHandle, error: QueueWedgeError) { entries.withLock { $0[localID] = Entry(handle: handle, error: error) } }
    func entry(localID: String) -> Entry? { entries.withLock { $0[localID] } }
    func forget(localID: String) { entries.withLock { _ = $0.removeValue(forKey: localID) } }
}
