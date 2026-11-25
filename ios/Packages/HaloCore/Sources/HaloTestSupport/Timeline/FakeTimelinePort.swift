import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// An in-memory `TimelinePort`. Each known room has a list of items; `emit` changes it and tells every open session.
public final class FakeTimelinePort: TimelinePort {
    private struct Room {
        var items: [TimelineItem] = []
        /// Older items that `paginateBackwards` prepends, oldest batch last.
        var older: [[TimelineItem]] = []
        var continuations: [UUID: AsyncStream<TimelineDiff>.Continuation] = [:]
        var openSessions = 0
        var totalOpens = 0
        var sent: [String] = []
        var paginateCalls = 0
        var histories: [EventID: [EditRevision]] = [:]
        var typing: [UserID] = []
        var typingContinuations: [UUID: AsyncStream<[UserID]>.Continuation] = [:]
        var typingCalls: [Bool] = []
        var identityAlerts: [IdentityAlert] = []
        var sentAnyway: [String] = []
        var identityContinuations: [UUID: AsyncStream<[IdentityAlert]>.Continuation] = [:]
        var acceptedIdentities: [UserID] = []
        var retried: [String] = []
        var members: [RoomMember] = []
        var stickers: [Sticker] = []
        var images: [OutgoingImage] = []
        var files: [OutgoingFile] = []
        var locations: [OutgoingLocation] = []
        var polls: [OutgoingPoll] = []
        var pinned: [EventID] = []
        var fileFailure: HaloError?
        var imageFailure: HaloError?
        var stickerFailure: HaloError?
        var sentMentions: [[UserID]] = []
        /// Optional override for `latestEventID()` (e.g. a trailing hidden event like an encrypted poll vote, R-01/R-06).
        var latestEventOverride: EventID?
        var openedThreads: [EventID] = []
        /// What `openFocused` shows around an event, and what `paginateForwards` adds, one batch per call.
        var focused: [EventID: (items: [TimelineItem], newer: [[TimelineItem]])] = [:]
        var focusError: HaloError?
    }

    private let rooms = Mutex<[RoomID: Room]>([:])

    public init() {}

    public func addRoom(_ id: RoomID, items: [TimelineItem] = [], older: [[TimelineItem]] = []) {
        rooms.withLock { $0[id] = Room(items: items, older: older) }
    }

    public func emit(_ diff: TimelineDiff, in id: RoomID, validate: Bool = true) throws(HaloError) {
        let continuations: [AsyncStream<TimelineDiff>.Continuation] = try rooms.withLock { (rooms) throws(HaloError) in
            guard var room = rooms[id] else { throw .notFound }
            if validate { try ListReducer.apply(diff, to: &room.items) }
            rooms[id] = room
            return Array(room.continuations.values)
        }
        for continuation in continuations { continuation.yield(diff) }
    }

    /// Sets who is typing in the room and tells every open session.
    public func setTypingUsers(_ users: [UserID], in id: RoomID) {
        let continuations = rooms.withLock { rooms -> [AsyncStream<[UserID]>.Continuation] in
            rooms[id]?.typing = users
            return Array(rooms[id]?.typingContinuations.values ?? [:].values)
        }
        for continuation in continuations { continuation.yield(users) }
    }

    /// Sets which members' identities changed and tells every open session.
    public func setIdentityAlerts(_ alerts: [IdentityAlert], in id: RoomID) {
        let continuations = rooms.withLock { rooms -> [AsyncStream<[IdentityAlert]>.Continuation] in
            rooms[id]?.identityAlerts = alerts
            return Array(rooms[id]?.identityContinuations.values ?? [:].values)
        }
        for continuation in continuations { continuation.yield(alerts) }
    }

    /// The local IDs sent again after accepting the risk, in order.
    public func sentAnyway(in id: RoomID) -> [String] { rooms.withLock { $0[id]?.sentAnyway ?? [] } }

    /// The users whose new identity was accepted, in order. Accepting ends the user's alert, as the SDK does.
    public func acceptedIdentities(in id: RoomID) -> [UserID] { rooms.withLock { $0[id]?.acceptedIdentities ?? [] } }

    /// The `setTyping` values received, in order.
    public func typingCalls(in id: RoomID) -> [Bool] { rooms.withLock { $0[id]?.typingCalls ?? [] } }

    /// The `retrySend` local IDs received, in order.
    public func retried(in id: RoomID) -> [String] { rooms.withLock { $0[id]?.retried ?? [] } }
    /// The images sent, in order.
    public func sentImages(in id: RoomID) -> [OutgoingImage] { rooms.withLock { $0[id]?.images ?? [] } }
    public func sentFiles(in id: RoomID) -> [OutgoingFile] { rooms.withLock { $0[id]?.files ?? [] } }
    /// The locations sent, in order.
    public func sentLocations(in id: RoomID) -> [OutgoingLocation] { rooms.withLock { $0[id]?.locations ?? [] } }

    /// The pinned event IDs in `id`, in order.
    public func pinnedEvents(in id: RoomID) -> [EventID] { rooms.withLock { $0[id]?.pinned ?? [] } }
    /// The polls started, in order.
    public func sentPolls(in id: RoomID) -> [OutgoingPoll] { rooms.withLock { $0[id]?.polls ?? [] } }
    /// The next `sendFile` in `id` throws `error`.
    public func failNextFile(in id: RoomID, with error: HaloError) { rooms.withLock { $0[id]?.fileFailure = error } }
    /// The next `sendImage` throws `error`.
    public func failNextImage(with error: HaloError, in id: RoomID) { rooms.withLock { $0[id]?.imageFailure = error } }
    /// The stickers sent, in order.
    public func sentStickers(in id: RoomID) -> [Sticker] { rooms.withLock { $0[id]?.stickers ?? [] } }
    /// The next `sendSticker` throws `error`.
    public func failNextSticker(with error: HaloError, in id: RoomID) { rooms.withLock { $0[id]?.stickerFailure = error } }
    /// The people the room offers for mentions.
    public func setMembers(_ members: [RoomMember], in id: RoomID) { rooms.withLock { $0[id]?.members = members } }
    /// The users mentioned (and still in the text) in each sent message, in order.
    public func sentMentions(in id: RoomID) -> [[UserID]] { rooms.withLock { $0[id]?.sentMentions ?? [] } }
    public func sentTexts(in id: RoomID) -> [String] { rooms.withLock { $0[id]?.sent ?? [] } }
    /// How many times `open(room:)` succeeded for `id` (closed sessions included).
    public func totalOpens(in id: RoomID) -> Int { rooms.withLock { $0[id]?.totalOpens ?? 0 } }
    public func openSessions(in id: RoomID) -> Int { rooms.withLock { $0[id]?.openSessions ?? 0 } }
    /// What `editHistory(of:)` returns for `event`.
    public func setEditHistory(_ revisions: [EditRevision], for event: EventID, in id: RoomID) { rooms.withLock { $0[id]?.histories[event] = revisions } }
    /// Overrides what `TimelineSession.latestEventID()` returns (models a trailing non-row event like a poll vote).
    public func setLatestEventID(_ eventID: EventID?, in id: RoomID) { rooms.withLock { $0[id]?.latestEventOverride = eventID } }
    public func paginateCalls(in id: RoomID) -> Int { rooms.withLock { $0[id]?.paginateCalls ?? 0 } }
    public func openedThreads(in id: RoomID) -> [EventID] { rooms.withLock { $0[id]?.openedThreads ?? [] } }

    // MARK: TimelinePort

    public func open(room id: RoomID) async throws(HaloError) -> any TimelineSession {
        try rooms.withLock { (rooms) throws(HaloError) in
            guard rooms[id] != nil else { throw .notFound }
            rooms[id]?.openSessions += 1
            rooms[id]?.totalOpens += 1
        }
        return Session(port: self, room: id)
    }

    public func openThread(room id: RoomID, rootEvent: EventID) async throws(HaloError) -> any TimelineSession {
        try rooms.withLock { (rooms) throws(HaloError) in
            guard rooms[id] != nil else { throw .notFound }
            rooms[id]?.openedThreads.append(rootEvent)
            rooms[id]?.openSessions += 1
            rooms[id]?.totalOpens += 1
        }
        return Session(port: self, room: id)
    }

    /// Makes `event` reachable by `openFocused`.
    public func addFocus(_ event: EventID, in id: RoomID, items: [TimelineItem], newer: [[TimelineItem]] = []) {
        rooms.withLock { $0[id]?.focused[event] = (items, newer) }
    }

    /// What `openFocused` throws for events without `addFocus` (default `.unsupported`).
    public func setFocusError(_ error: HaloError, in id: RoomID) { rooms.withLock { $0[id]?.focusError = error } }

    public func openFocused(room id: RoomID, event: EventID) async throws(HaloError) -> any TimelineSession {
        let found = try rooms.withLock { (rooms) throws(HaloError) in
            guard let room = rooms[id] else { throw .notFound }
            guard let found = room.focused[event] else { throw room.focusError ?? .unsupported("FOCUS") }
            rooms[id]?.openSessions += 1
            return found
        }
        return FocusedSession(live: Session(port: self, room: id), items: found.items, newer: found.newer)
    }

    /// A focused timeline: its own items, everything else as the room's.
    private final class FocusedSession: TimelineSession {
        private let live: Session
        private let state: Mutex<(items: [TimelineItem], newer: [[TimelineItem]], continuation: AsyncStream<TimelineDiff>.Continuation?)>

        init(live: Session, items: [TimelineItem], newer: [[TimelineItem]]) {
            self.live = live
            state = Mutex((items, newer, nil))
        }

        func items() -> AsyncStream<TimelineDiff> {
            let (stream, continuation) = AsyncStream<TimelineDiff>.makeStream()
            state.withLock { state in
                state.continuation = continuation
                continuation.yield(.reset(state.items))
            }
            return stream
        }

        func paginateForwards(count: UInt16) async throws(HaloError) -> Bool {
            state.withLock { state in
                guard !state.newer.isEmpty else { return true }
                let batch = state.newer.removeFirst()
                state.items += batch
                state.continuation?.yield(.append(batch))
                return state.newer.isEmpty
            }
        }

        func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool { true }
        func members() async throws(HaloError) -> [RoomMember] { try await live.members() }
        func send(text: String, mentions: [Mention]) async throws(HaloError) { try await live.send(text: text, mentions: mentions) }
        func typingUsers() -> AsyncStream<[UserID]> { live.typingUsers() }
        func identityAlerts() -> AsyncStream<[IdentityAlert]> { live.identityAlerts() }
        func sendAnyway(localID: String) async throws(HaloError) { try await live.sendAnyway(localID: localID) }
        func acceptIdentity(of user: UserID) async throws(HaloError) { try await live.acceptIdentity(of: user) }
        func setTyping(_ isTyping: Bool) async throws(HaloError) { try await live.setTyping(isTyping) }
        func reply(to event: EventID, text: String, mentions: [Mention]) async throws(HaloError) { try await live.reply(to: event, text: text, mentions: mentions) }
        func toggleReaction(on event: EventID, key: String) async throws(HaloError) { try await live.toggleReaction(on: event, key: key) }
        func edit(event: EventID, newText: String) async throws(HaloError) { try await live.edit(event: event, newText: newText) }
        func delete(event: EventID) async throws(HaloError) { try await live.delete(event: event) }
        func sendSticker(_ sticker: Sticker) async throws(HaloError) { try await live.sendSticker(sticker) }
        func sendImage(_ image: OutgoingImage) async throws(HaloError) { try await live.sendImage(image) }
        func sendFile(_ file: OutgoingFile) async throws(HaloError) { try await live.sendFile(file) }
        func sendLocation(_ location: OutgoingLocation) async throws(HaloError) { try await live.sendLocation(location) }
        func createPoll(_ poll: OutgoingPoll) async throws(HaloError) { try await live.createPoll(poll) }
        func retrySend(localID: String) async throws(HaloError) { try await live.retrySend(localID: localID) }
        func abortSend(localID: String) async throws(HaloError) { try await live.abortSend(localID: localID) }
        func close() async { await live.close() }
    }

    private final class Session: TimelineSession {
        let port: FakeTimelinePort
        let room: RoomID
        init(port: FakeTimelinePort, room: RoomID) {
            self.port = port
            self.room = room
        }

        func items() -> AsyncStream<TimelineDiff> {
            let (stream, continuation) = AsyncStream<TimelineDiff>.makeStream(bufferingPolicy: .unbounded)
            let id = UUID()
            let room = self.room
            let current = port.rooms.withLock { rooms -> [TimelineItem] in
                rooms[room]?.continuations[id] = continuation
                return rooms[room]?.items ?? []
            }
            continuation.yield(.reset(current))
            continuation.onTermination = { [port] _ in port.rooms.withLock { _ = $0[room]?.continuations.removeValue(forKey: id) } }
            return stream
        }

        func paginateBackwards(count: UInt16) async throws(HaloError) -> Bool {
            let (batch, reachedStart, continuations): ([TimelineItem], Bool, [AsyncStream<TimelineDiff>.Continuation]) =
                port.rooms.withLock { rooms in
                    guard var state = rooms[room] else { return ([], true, []) }
                    state.paginateCalls += 1
                    let batch = state.older.isEmpty ? [] : state.older.removeFirst()
                    state.items = batch + state.items
                    rooms[room] = state
                    return (batch, state.older.isEmpty, Array(state.continuations.values))
                }
            // Older events arrive as inserts at the front, oldest first, like the SDK's pagination diffs.
            for (offset, item) in batch.enumerated() {
                for continuation in continuations { continuation.yield(.insert(index: offset, item)) }
            }
            return reachedStart
        }

        func typingUsers() -> AsyncStream<[UserID]> {
            let (stream, continuation) = AsyncStream<[UserID]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            let room = self.room
            let current = port.rooms.withLock { rooms -> [UserID] in
                rooms[room]?.typingContinuations[id] = continuation
                return rooms[room]?.typing ?? []
            }
            continuation.yield(current)
            continuation.onTermination = { [port] _ in port.rooms.withLock { _ = $0[room]?.typingContinuations.removeValue(forKey: id) } }
            return stream
        }

        func setTyping(_ isTyping: Bool) async throws(HaloError) {
            port.rooms.withLock { $0[room]?.typingCalls.append(isTyping) }
        }

        func sendAnyway(localID: String) async throws(HaloError) {
            port.rooms.withLock { $0[room]?.sentAnyway.append(localID) }
        }

        func identityAlerts() -> AsyncStream<[IdentityAlert]> {
            let (stream, continuation) = AsyncStream<[IdentityAlert]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            let room = self.room
            let current = port.rooms.withLock { rooms -> [IdentityAlert] in
                rooms[room]?.identityContinuations[id] = continuation
                return rooms[room]?.identityAlerts ?? []
            }
            continuation.yield(current)
            continuation.onTermination = { [port] _ in port.rooms.withLock { _ = $0[room]?.identityContinuations.removeValue(forKey: id) } }
            return stream
        }

        func acceptIdentity(of user: UserID) async throws(HaloError) {
            let (remaining, continuations) = port.rooms.withLock { rooms -> ([IdentityAlert], [AsyncStream<[IdentityAlert]>.Continuation]) in
                rooms[room]?.acceptedIdentities.append(user)
                rooms[room]?.identityAlerts.removeAll { $0.user == user }
                return (rooms[room]?.identityAlerts ?? [], Array(rooms[room]?.identityContinuations.values ?? [:].values))
            }
            for continuation in continuations { continuation.yield(remaining) }
        }

        func sendSticker(_ sticker: Sticker) async throws(HaloError) {
            if let failure = port.rooms.withLock({ rooms -> HaloError? in
                guard let f = rooms[room]?.stickerFailure else { return nil }
                rooms[room]?.stickerFailure = nil
                return f
            }) { throw failure }
            port.rooms.withLock { $0[room]?.stickers.append(sticker) }
        }

        func sendImage(_ image: OutgoingImage) async throws(HaloError) {
            try image.validate()
            if let failure = port.rooms.withLock({ rooms -> HaloError? in
                guard let f = rooms[room]?.imageFailure else { return nil }
                rooms[room]?.imageFailure = nil
                return f
            }) { throw failure }
            port.rooms.withLock { $0[room]?.images.append(image) }
        }

        func sendFile(_ file: OutgoingFile) async throws(HaloError) {
            try file.validate()
            if let failure = port.rooms.withLock({ rooms -> HaloError? in
                guard let f = rooms[room]?.fileFailure else { return nil }
                rooms[room]?.fileFailure = nil
                return f
            }) { throw failure }
            port.rooms.withLock { $0[room]?.files.append(file) }
        }

        func sendLocation(_ location: OutgoingLocation) async throws(HaloError) {
            try location.validate()
            port.rooms.withLock { $0[room]?.locations.append(location) }
        }

        func createPoll(_ poll: OutgoingPoll) async throws(HaloError) {
            try poll.validate()
            port.rooms.withLock { $0[room]?.polls.append(poll) }
        }

        func pinnedEventIDs() async -> [EventID] {
            port.rooms.withLock { $0[room]?.pinned ?? [] }
        }

        func pin(event: EventID) async throws(HaloError) {
            port.rooms.withLock { rooms in
                guard var state = rooms[room] else { return }
                if !state.pinned.contains(event) { state.pinned.append(event) }
                rooms[room] = state
            }
        }

        func unpin(event: EventID) async throws(HaloError) {
            port.rooms.withLock { rooms in
                guard var state = rooms[room] else { return }
                state.pinned.removeAll { $0 == event }
                rooms[room] = state
            }
        }

        func members() async throws(HaloError) -> [RoomMember] { port.rooms.withLock { $0[room]?.members ?? [] } }

        func send(text: String, mentions: [Mention]) async throws(HaloError) { try await send(text: text, replyTo: nil, mentions: mentions) }

        func reply(to event: EventID, text: String, mentions: [Mention]) async throws(HaloError) {
            let original: TimelineEvent? = port.rooms.withLock { rooms in
                for item in rooms[room]?.items ?? [] { if case .event(let e) = item.content, e.eventID == event { return e } }
                return nil
            }
            guard let original else { throw .notFound }
            var snippet: String?
            if case .text(let body, _) = original.kind { snippet = body }
            try await send(text: text, replyTo: ReplyPreview(eventID: event, senderName: original.senderName, snippet: snippet), mentions: mentions)
        }

        private func send(text: String, replyTo: ReplyPreview?, mentions: [Mention]) async throws(HaloError) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
            let count = port.rooms.withLock { rooms -> Int in
                rooms[room]?.sent.append(trimmed)
                rooms[room]?.sentMentions.append(MentionFormatter.apply(trimmed, mentions: mentions).users)
                return rooms[room]?.items.count ?? 0
            }
            let item = TimelineItem(
                id: TimelineItemID("local-\(UUID().uuidString)"),
                content: .event(TimelineEvent(
                    eventID: nil, sender: nil, senderName: nil, timestamp: Date(), isOwn: true,
                    kind: .text(trimmed, isEdited: false), sendState: .sending, replyTo: replyTo)))
            try? port.emit(.pushBack(item), in: room)
            // The server confirms: the echo turns into the sent event in place.
            let confirmed = TimelineItem(
                id: item.id,
                content: .event(TimelineEvent(
                    eventID: try? EventID("$fake-\(UUID().uuidString.prefix(8))"), sender: nil, senderName: nil, timestamp: Date(), isOwn: true,
                    kind: .text(trimmed, isEdited: false), sendState: .sent, replyTo: replyTo)))
            try? port.emit(.set(index: count, confirmed), in: room)
        }

        func toggleReaction(on event: EventID, key: String) async throws(HaloError) {
            try modify(event) { e in
                var reactions = e.reactions
                if let index = reactions.firstIndex(where: { $0.key == key }) {
                    let current = reactions[index]
                    if current.reactedByMe {
                        if current.count <= 1 { reactions.remove(at: index) } else { reactions[index] = ReactionSummary(key: key, count: current.count - 1, reactedByMe: false) }
                    } else {
                        reactions[index] = ReactionSummary(key: key, count: current.count + 1, reactedByMe: true)
                    }
                } else {
                    reactions.append(ReactionSummary(key: key, count: 1, reactedByMe: true))
                }
                return TimelineEvent(eventID: e.eventID, sender: e.sender, senderName: e.senderName, timestamp: e.timestamp, isOwn: e.isOwn, kind: e.kind, sendState: e.sendState, reactions: reactions, replyTo: e.replyTo, formattedBody: e.formattedBody, localID: e.localID)
            }
        }

        func addReaction(on event: EventID, key: String) async throws(HaloError) -> Bool {
            let reacted = port.rooms.withLock { rooms -> Bool in
                for item in rooms[room]?.items ?? [] {
                    if case .event(let e) = item.content, e.eventID == event { return e.reactions.contains { $0.key == key && $0.reactedByMe } }
                }
                return false
            }
            if reacted { return false }
            try await toggleReaction(on: event, key: key)
            return true
        }

        func edit(event: EventID, newText: String) async throws(HaloError) {
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
            nonisolated(unsafe) var original = ""
            try modify(event) { e in
                guard e.isOwn else { return nil }
                if case .text(let before, _) = e.kind { original = before }
                return TimelineEvent(eventID: e.eventID, sender: e.sender, senderName: e.senderName, timestamp: e.timestamp, isOwn: true, kind: .text(trimmed, isEdited: true), sendState: e.sendState, reactions: e.reactions)
            }
            port.rooms.withLock {
                var history = $0[room]?.histories[event] ?? [EditRevision(text: original, timestamp: nil)]
                history.append(EditRevision(text: trimmed, timestamp: nil))
                $0[room]?.histories[event] = history
            }
        }

        func editHistory(of event: EventID) async throws(HaloError) -> [EditRevision] {
            guard let revisions = port.rooms.withLock({ $0[room]?.histories[event] }) else { throw .notFound }
            return revisions
        }

        func delete(event: EventID) async throws(HaloError) {
            try modify(event) { e in
                guard e.isOwn else { return nil }
                return TimelineEvent(eventID: e.eventID, sender: e.sender, senderName: e.senderName, timestamp: e.timestamp, isOwn: true, kind: .redacted, sendState: e.sendState)
            }
        }

        /// Replaces the event with `event` in the room's items and tells subscribers. `nil` from `change` means forbidden.
        private func modify(_ id: EventID, _ change: (TimelineEvent) -> TimelineEvent?) throws(HaloError) {
            let found: (Int, TimelineItem)? = port.rooms.withLock { rooms in
                guard let items = rooms[room]?.items else { return nil }
                for (index, item) in items.enumerated() {
                    if case .event(let event) = item.content, event.eventID == id { return (index, item) }
                }
                return nil
            }
            guard let (index, item) = found, case .event(let event) = item.content else { throw .notFound }
            guard let changed = change(event) else { throw .forbidden }
            try port.emit(.set(index: index, TimelineItem(id: item.id, content: .event(changed))), in: room)
        }

        func retrySend(localID: String) async throws(HaloError) {
            let found = localEcho(localID)
            guard let (index, item) = found, case .event(let e) = item.content else { throw .notFound }
            let sending = TimelineEvent(
                eventID: nil, sender: e.sender, senderName: e.senderName, timestamp: e.timestamp, isOwn: true, kind: e.kind, sendState: .sending,
                replyTo: e.replyTo, localID: localID)
            try port.emit(.set(index: index, TimelineItem(id: item.id, content: .event(sending))), in: room)
            port.rooms.withLock { $0[room]?.retried.append(localID) }
            let sent = TimelineEvent(
                eventID: try? EventID("$fake-\(UUID().uuidString.prefix(8))"), sender: e.sender, senderName: e.senderName, timestamp: e.timestamp,
                isOwn: true, kind: e.kind, sendState: .sent, replyTo: e.replyTo)
            try port.emit(.set(index: index, TimelineItem(id: item.id, content: .event(sent))), in: room)
        }

        func abortSend(localID: String) async throws(HaloError) {
            guard let (index, _) = localEcho(localID) else { throw .notFound }
            try port.emit(.remove(index: index), in: room)
        }

        private func localEcho(_ localID: String) -> (Int, TimelineItem)? {
            port.rooms.withLock { rooms in
                for (index, item) in (rooms[room]?.items ?? []).enumerated() {
                    if case .event(let e) = item.content, e.localID == localID, e.eventID == nil { return (index, item) }
                }
                return nil
            }
        }

        func latestEventID() async -> EventID? {
            port.rooms.withLock { rooms in
                guard let r = rooms[room] else { return nil }
                if let override = r.latestEventOverride { return override }
                for item in r.items.reversed() {
                    if case .event(let e) = item.content, let id = e.eventID { return id }
                }
                return nil
            }
        }

        func close() async { port.rooms.withLock { $0[room]?.openSessions -= 1 } }
    }
}
