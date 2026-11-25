import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `MessageIndexSourcePort` over the SDK (ADR-0024). *Live lane:* per-room event listeners in the app's client deliver what sync brings,
/// decrypted; an event without a key arrives as `m.room.encrypted` with its ID. *History lane:* event-focused timelines in a client of its
/// own (`MatrixSessionPort.searchHistoryClient`), which the indexer drops every few rooms.
public final class MatrixMessageIndexSource: MessageIndexSourcePort {
    /// Polls are another event type; a listener per room and type costs about 7 KB, so only the most recent rooms get one.
    static let pollRooms = 200
    /// Listeners run on their own tasks, a moment behind the sync response that they belong to.
    private static let settle: Duration = .milliseconds(150)
    private static let unsettled: Duration = .milliseconds(750)

    private struct Raw: Sendable {
        enum Kind: Sendable { case message, poll, encrypted, redaction }
        let room: RoomID
        let kind: Kind
        let event: EventID
        let sender: String
        let timestamp: UInt64
        let json: String
    }

    private struct State {
        weak var client: Client?
        var handles: [RoomID: [TaskHandle]] = [:]
        var polls: Set<RoomID> = []
        var buffer: [Raw] = []
        var touched: Set<RoomID> = []
        var left: Set<RoomID> = []
        var catchUp = false
        var flush: Task<Void, Never>?
        var changes: Task<Void, Never>?
        var continuation: AsyncStream<SearchLiveBatch>.Continuation?
        var names: [RoomID: [String: String]] = [:]
    }

    private let session: MatrixSessionPort
    private let fetch: ClientServerGET.Fetch
    private let state = Mutex(State())

    public convenience init(session: MatrixSessionPort) { self.init(session: session, fetch: ClientServerGET.urlSessionFetch) }

    init(session: MatrixSessionPort, fetch: @escaping ClientServerGET.Fetch) {
        self.session = session
        self.fetch = fetch
    }

    deinit {
        state.withLock { state in
            state.changes?.cancel()
            state.flush?.cancel()
            for handle in state.handles.values.joined() { handle.cancel() }
        }
    }

    // MARK: Live lane

    public func batches() -> AsyncStream<SearchLiveBatch> {
        let (stream, continuation) = AsyncStream<SearchLiveBatch>.makeStream(bufferingPolicy: .unbounded)
        let session = session
        let changes = Task { [weak self] in
            for await change in await session.syncChanges() {
                self?.received(change)
            }
        }
        state.withLock { state in
            state.changes?.cancel()
            state.continuation?.finish()
            state.continuation = continuation
            state.changes = changes
        }
        return stream
    }

    private func follow(_ rooms: [RoomID], polls: Set<RoomID>) async {
        guard let client = try? await session.signedInClient() else { return }  // best-effort: a read; the caller falls back to a default and nothing changes
        let followed = state.withLock { $0.client === client ? Array($0.handles.keys) : [] }
        let leftRooms = followed.filter { (try? client.getRoom(roomId: $0.rawValue))?.membership() != .joined }
        let (missing, missingPolls, gone) = state.withLock { state -> ([RoomID], Set<RoomID>, [TaskHandle]) in
            var gone: [TaskHandle] = []
            if state.client !== client {
                gone = Array(state.handles.values.joined())
                state.handles = [:]
                state.polls = []
                state.names = [:]
                state.client = client
            }
            for room in leftRooms where state.handles[room] != nil {
                gone += state.handles.removeValue(forKey: room) ?? []
                state.polls.remove(room)
            }
            return (rooms.filter { state.handles[$0] == nil }, polls.subtracting(state.polls), gone)
        }
        for handle in gone { handle.cancel() }
        for id in rooms where missingPolls.contains(id) || missing.contains(id) {
            guard let room = try? client.getRoom(roomId: id.rawValue) else { continue }
            let (isNew, needsPolls) = state.withLock { ($0.handles[id] == nil, missingPolls.contains(id) && !$0.polls.contains(id)) }
            var handles: [TaskHandle] = []
            if isNew {
                handles.append(listen(room, id, .roomMessage, .message))
                handles.append(listen(room, id, .roomEncrypted, .encrypted))
                handles.append(listen(room, id, .roomRedaction, .redaction))
            }
            if needsPolls { handles.append(listen(room, id, .unstablePollStart, .poll)) }
            state.withLock { state in
                state.handles[id, default: []] += handles
                if needsPolls { state.polls.insert(id) }
            }
        }
    }

    public func joinedRooms() async -> Set<RoomID>? {
        guard let client = try? await session.signedInClient() else { return nil }  // best-effort: a read; the caller falls back to a default and nothing changes
        return Set(client.rooms().filter { $0.membership() == .joined }.compactMap { try? RoomID($0.id()) })
    }

    /// All joined rooms the store knows, before the room list is ready and before the first sync of a run.
    public func followKnownRooms() async {
        guard let client = try? await session.signedInClient() else { return }  // best-effort: a read; the caller falls back to a default and nothing changes
        let joined = client.rooms().filter { $0.membership() == .joined }.compactMap { try? RoomID($0.id()) }
        // Without an order nobody knows which are recent: polls wait for `follow`.
        await follow(joined, polls: [])
    }

    public func follow(_ rooms: [RoomID]) async { await follow(rooms, polls: Set(rooms.prefix(Self.pollRooms))) }

    private func listen(_ room: Room, _ id: RoomID, _ type: MessageLikeEventType, _ kind: Raw.Kind) -> TaskHandle {
        room.subscribeToMessageLikeEvents(eventType: type, listener: EventListener { [weak self] event in
            guard let event = try? Raw(room: id, kind: kind, event: EventID(event.eventId), sender: event.sender, timestamp: event.timestamp, json: event.contentJson) else { return }
            self?.received(event)
        })
    }

    private func received(_ event: Raw) {
        state.withLock { state in
            state.buffer.append(event)
            if state.flush == nil { state.flush = flushTask(after: Self.unsettled) }
        }
    }

    private func received(_ change: MatrixSessionPort.SyncChange) {
        state.withLock { state in
            state.touched.formUnion(change.joined.compactMap { try? RoomID($0) })
            state.left.formUnion(change.left.compactMap { try? RoomID($0) })
            state.catchUp = state.catchUp || change.isCatchUp
            state.flush?.cancel()
            state.flush = flushTask(after: Self.settle)
        }
    }

    private func flushTask(after delay: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flush()
        }
    }

    private func flush() async {
        let (raw, touched, left, catchUp) = state.withLock { state in
            defer {
                state.buffer = []
                state.touched = []
                state.left = []
                state.catchUp = false
                state.flush = nil
            }
            return (state.buffer, state.touched, state.left, state.catchUp)
        }
        var events: [SearchLiveEvent] = []
        for event in raw {
            if let mapped = await map(event) { events.append(mapped) }
        }
        guard !events.isEmpty || !touched.isEmpty || !left.isEmpty || catchUp else { return }
        let batch = SearchLiveBatch(events: events, touched: touched, left: left, isCatchUp: catchUp)
        _ = state.withLock { $0.continuation }?.yield(batch)
    }

    private func map(_ event: Raw) async -> SearchLiveEvent? {
        switch event.kind {
        case .encrypted: return .undecryptable(event.room, event.event)
        case .redaction:
            // Older room versions keep the deleted event's ID outside the content, where only the typed event has it.
            guard let room = try? await session.room(event.room), let full = try? await room.loadOrFetchEvent(eventId: event.event.rawValue),  // best-effort: a read; the caller falls back to a default and nothing changes
                  case .messageLike(.roomRedaction(let target, _)) = try? full.content(), let target, let id = try? EventID(target) else { return nil }
            return .removed(event.room, id)
        case .message, .poll:
            guard let parsed = event.kind == .poll ? SearchContent.parse(poll: event.json) : SearchContent.parse(message: event.json),
                  let content = parsed.content, let sender = try? UserID(event.sender) else { return nil }
            if let target = parsed.replaces { return .edit(event.room, target: target, sender: sender, content) }
            return .message(SearchIndexEntry(
                room: event.room, event: event.event, sender: sender, senderName: await name(of: event.sender, in: event.room), threadRoot: parsed.threadRoot,
                timestamp: TimelineMapper.date(event.timestamp), content: content))
        }
    }

    private func name(of user: String, in id: RoomID) async -> String? {
        if let known = state.withLock({ $0.names[id]?[user] }) { return known }
        guard let room = try? await session.room(id), let name = try? await room.memberDisplayName(userId: user) else { return nil }  // best-effort: a read; the caller falls back to a default and nothing changes
        state.withLock { $0.names[id, default: [:]][user] = name }
        return name
    }

    // MARK: From the server

    public func newestEvent(in room: RoomID) async throws(HaloError) -> EventID? {
        for event in try await messages(in: room, limit: 5, filter: nil) {
            // Not inside a thread: an event-focused timeline there would page through the thread only.
            guard Self.relation(of: event) != "m.thread", let id = (event["event_id"] as? String).flatMap({ try? EventID($0) }) else { continue }
            return id
        }
        // Only thread messages among the newest five: look further.
        return try await messages(in: room, limit: 100, filter: nil).lazy
            .filter { Self.relation(of: $0) != "m.thread" }.compactMap { ($0["event_id"] as? String).flatMap { try? EventID($0) } }.first
    }

    public func recentMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [SearchRecentMessage] {
        let types = ["m.room.message", "m.room.encrypted", "m.poll.start", "org.matrix.msc3381.poll.start"]
        let filter = #"{"types":["\#(types.joined(separator: #"",""#))"]}"#
        return try await messages(in: room, limit: limit, filter: filter).compactMap { event in
            let content = event["content"] as? [String: Any] ?? [:]
            guard !content.isEmpty else { return nil }  // deleted
            // Edits and answers to polls belong to another message.
            guard !["m.replace", "m.reference", "m.annotation"].contains(Self.relation(of: event)) else { return nil }
            guard let id = (event["event_id"] as? String).flatMap({ try? EventID($0) }) else { return nil }
            return SearchRecentMessage(event: id, isThreaded: Self.relation(of: event) == "m.thread")
        }
    }

    private static func relation(of event: [String: Any]) -> String {
        ((event["content"] as? [String: Any])?["m.relates_to"] as? [String: Any])?["rel_type"] as? String ?? ""
    }

    /// The room's newest events. Direct, because the SDK's latest event has no ID (F-FFI-15) and says nothing about what a limited sync left out.
    private func messages(in room: RoomID, limit: Int, filter: String?) async throws(HaloError) -> [[String: Any]] {
        let client = try await session.signedInClient()
        var query = [URLQueryItem(name: "dir", value: "b"), URLQueryItem(name: "limit", value: String(limit))]
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        do {
            guard let data = try await ClientServerGET(fetch: fetch).get(client, "rooms/\(ClientServerGET.escape(room.rawValue))/messages", query: query) else { throw HaloError.notFound }
            guard let chunk = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["chunk"] as? [[String: Any]] else { throw HaloError.internal(code: "MESSAGES_MALFORMED") }
            return chunk
        } catch is ClientServerGET.Forbidden { throw .forbidden } catch { throw ErrorMapper.map(error) }
    }

    // MARK: History lane

    public func history(in id: RoomID, from event: EventID, pages: Int) async throws(HaloError) -> SearchHistorySlice {
        let client = try await session.searchHistoryClient()
        do {
            guard let room = try client.getRoom(roomId: id.rawValue) else { throw HaloError.notFound }
            // Keys of older messages come from the backup, after the decryption failed; without a backup there is nothing to wait for.
            let waits = (try? await session.encryption().backupState()) == .enabled  // best-effort: a read; the caller falls back to a default and nothing changes
            return try await read(room, id, from: event, pages: pages, waitsForKeys: waits)
        } catch { throw ErrorMapper.map(error) }
    }

    private func read(_ room: Room, _ id: RoomID, from event: EventID, pages: Int, waitsForKeys: Bool) async throws -> SearchHistorySlice {
        let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            focus: .event(eventId: event.rawValue, numContextEvents: 0, threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: "search", dateDividerMode: .monthly, trackReadReceipts: .disabled, reportUtds: false))
        let mirror = HistoryMirror(room: id)
        let handle = await timeline.addListener(listener: mirror)
        defer { handle.cancel() }
        await mirror.settle(after: 0)  // the first update carries what is there
        var reachedStart = false
        for _ in 0..<pages where !reachedStart {
            try Task.checkCancellation()
            let seen = mirror.updates
            reachedStart = try await timeline.paginateBackwards(numEvents: 100)
            await mirror.settle(after: seen)
        }
        if waitsForKeys { await mirror.waitForKeys() }
        return mirror.slice(reachedStart: reachedStart)
    }

    /// Asks the server, not the SDK: a deletion inside a part of the room that sync left out never reaches the SDK's cache.
    public func recheck(_ event: EventID, in id: RoomID) async throws(HaloError) -> SearchRecheck {
        let client = try await session.signedInClient()
        do {
            let path = "rooms/\(ClientServerGET.escape(id.rawValue))/event/\(ClientServerGET.escape(event.rawValue))"
            guard let data = try await ClientServerGET(fetch: fetch).get(client, path) else { return .gone }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HaloError.internal(code: "EVENT_MALFORMED") }
            switch SearchMapper.recheck(object) {
            case .result(let result): return result
            case .encryptedEdit:
                // The text of an encrypted edit only the SDK can read.
                let found = try await (try await session.room(id)).loadOrFetchEventWithRelations(eventId: event.rawValue, relationFilter: [.replacement])
                return SearchMapper.edit(of: found.event, related: found.relatedEvents)
            }
        } catch is ClientServerGET.Forbidden { throw .forbidden } catch { throw ErrorMapper.map(error) }
    }

    public func endBatch() async { await session.dropHistoryClient() }

    public func stop() async {
        let (handles, tasks) = state.withLock { state in
            defer {
                state.continuation?.finish()
                let old = state
                state = State()
                _ = old
            }
            return (Array(state.handles.values.joined()), [state.changes, state.flush])
        }
        for handle in handles { handle.cancel() }
        for task in tasks { task?.cancel() }
        await session.dropHistoryClient()
    }
}

private final class EventListener: RoomMessageLikeEventsListener {
    private let handler: @Sendable (RoomMessageLikeEvent) -> Void
    init(_ handler: @escaping @Sendable (RoomMessageLikeEvent) -> Void) { self.handler = handler }
    func onEvent(event: RoomMessageLikeEvent) { handler(event) }
}

/// The items of a history timeline, kept from its updates.
private final class HistoryMirror: TimelineListener {
    private let room: RoomID
    private let state = Mutex((items: [SearchMapper.Item](), updates: 0))

    init(room: RoomID) { self.room = room }

    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) {
        let mapped = diff.map { SearchMapper.map($0, room: room) }
        state.withLock { state in
            // A diff that doesn't fit is followed by a reset; what is missing until then is read again with the next slice.
            for diff in mapped { try? ListReducer.apply(diff, to: &state.items) }
            state.updates += 1
        }
    }

    var updates: Int { state.withLock { $0.updates } }

    /// Updates arrive on another thread a moment after the call that caused them: waits for one, then until 10 ms pass without another.
    func settle(after count: Int) async {
        for _ in 0..<300 where updates <= count { try? await Task.sleep(for: .milliseconds(1)) }
        var last = updates
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(10))
            if updates == last { return }
            last = updates
        }
    }

    /// Until every message is readable, nothing changed for a second and a half, or 20 seconds passed.
    func waitForKeys() async {
        var left = undecryptable, quiet = 0
        for _ in 0..<200 where left > 0 && quiet < 15 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let now = undecryptable
            quiet = now == left ? quiet + 1 : 0
            left = now
        }
    }

    private var undecryptable: Int {
        state.withLock { $0.items.reduce(0) { count, item in if case .undecryptable = item { count + 1 } else { count } } }
    }

    func slice(reachedStart: Bool) -> SearchHistorySlice {
        let items = state.withLock { $0.items }
        var slice = SearchHistorySlice(reachedStart: reachedStart)
        for item in items {
            switch item {
            case .message(let entry): slice.entries.append(entry)
            case .undecryptable(let id, _, _): slice.undecryptable.append(id)
            case .other(let id, _, _): slice.other.append(id)
            case .none: break
            }
        }
        // Not inside a thread: the next slice would page through the thread only.
        let oldest = items.lazy.compactMap(\.event).first { $0.threadRoot == nil }
        slice.oldest = oldest?.id
        slice.oldestTime = oldest?.time
        return slice
    }
}
