import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// `MessageIndexSourcePort` over rooms held in memory. Event `n` of a room has the ID `$<room>-<n>`.
public final class FakeMessageIndexSource: MessageIndexSourcePort {
    public struct Event: Sendable {
        public var entry: SearchIndexEntry
        public var readable: Bool
    }

    private struct State {
        var rooms: [RoomID: [Event]] = [:]
        var continuation: AsyncStream<SearchLiveBatch>.Continuation?
        var followed: [RoomID] = []
        var reads: [(room: RoomID, from: EventID)] = []
        var batchesEnded = 0
        var stopped = false
        var errors: [RoomID: HaloError] = [:]
        var rechecks: [EventID: SearchRecheck] = [:]
        var rechecked: [EventID] = []
        var recheckError: HaloError?
        var recheckHangs = false
        var joined: Set<RoomID>?
        var readsHang = false
    }

    private let state = Mutex(State())
    private let eventsPerPage: Int

    public init(eventsPerPage: Int = 2) { self.eventsPerPage = eventsPerPage }

    public static func entry(_ room: RoomID, _ number: Int, _ body: String? = nil, sender: String = "@bob:x.org") throws -> SearchIndexEntry {
        SearchIndexEntry(
            room: room, event: try EventID("$\(room.rawValue)-\(number)"), sender: try UserID(sender), senderName: "Bob", threadRoot: nil,
            timestamp: Date(timeIntervalSince1970: Double(1000 + number)), content: SearchableContent(kind: .message, body: body ?? "message \(number)"))
    }

    /// Adds events to the end of `room`'s history, on the server only.
    public func add(_ entries: [SearchIndexEntry], to room: RoomID, readable: Bool = true) {
        state.withLock { $0.rooms[room, default: []] += entries.map { Event(entry: $0, readable: readable) } }
    }

    public func makeReadable(_ room: RoomID) {
        state.withLock { state in
            for index in (state.rooms[room] ?? []).indices { state.rooms[room]?[index].readable = true }
        }
    }

    public func fail(_ room: RoomID, with error: HaloError?) { state.withLock { $0.errors[room] = error } }
    public func set(_ answer: SearchRecheck, for event: EventID) { state.withLock { $0.rechecks[event] = answer } }
    public func failRechecks(with error: HaloError?) { state.withLock { $0.recheckError = error } }
    /// History reads never return, like a call into the SDK on a dead network.
    public func hangReads() { state.withLock { $0.readsHang = true } }
    public func hangRechecks() { state.withLock { $0.recheckHangs = true } }
    public func yield(_ batch: SearchLiveBatch) { _ = state.withLock { $0.continuation }?.yield(batch) }

    public var reads: [(room: RoomID, from: EventID)] { state.withLock { $0.reads } }
    public var followed: [RoomID] { state.withLock { $0.followed } }
    public var batchesEnded: Int { state.withLock { $0.batchesEnded } }
    public var isStopped: Bool { state.withLock { $0.stopped } }
    public var rechecked: [EventID] { state.withLock { $0.rechecked } }

    public func batches() -> AsyncStream<SearchLiveBatch> {
        let (stream, continuation) = AsyncStream<SearchLiveBatch>.makeStream()
        state.withLock { $0.continuation = continuation }
        return stream
    }

    public func followKnownRooms() async {}
    public func joinedRooms() async -> Set<RoomID>? { state.withLock { $0.joined } }
    public func setJoined(_ rooms: Set<RoomID>?) { state.withLock { $0.joined = rooms } }

    public func follow(_ rooms: [RoomID]) async { state.withLock { $0.followed = rooms } }

    private func events(_ room: RoomID) throws(HaloError) -> [Event] {
        let (error, events) = state.withLock { ($0.errors[room], $0.rooms[room] ?? []) }
        if let error { throw error }
        return events
    }

    public func newestEvent(in room: RoomID) async throws(HaloError) -> EventID? { try events(room).last?.entry.event }

    public func recentMessages(in room: RoomID, limit: Int) async throws(HaloError) -> [SearchRecentMessage] {
        try events(room).suffix(limit).reversed().map { SearchRecentMessage(event: $0.entry.event, isThreaded: $0.entry.threadRoot != nil) }
    }

    public func history(in room: RoomID, from event: EventID, pages: Int) async throws(HaloError) -> SearchHistorySlice {
        let hangs = state.withLock { state in
            state.reads.append((room, event))
            return state.readsHang
        }
        if hangs { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
        let events = try events(room)
        guard let index = events.firstIndex(where: { $0.entry.event == event }) else { throw .notFound }
        let first = max(0, index - eventsPerPage * pages)
        let part = events[first...index]
        return SearchHistorySlice(
            entries: part.filter(\.readable).map(\.entry), undecryptable: part.filter { !$0.readable }.map(\.entry.event),
            oldest: part.first?.entry.event, oldestTime: part.first?.entry.timestamp, reachedStart: first == 0)
    }

    public func recheck(_ event: EventID, in room: RoomID) async throws(HaloError) -> SearchRecheck {
        let (error, hangs, answer) = state.withLock { state in
            state.rechecked.append(event)
            return (state.recheckError, state.recheckHangs, state.rechecks[event] ?? .unchanged)
        }
        // Like a call into the SDK while offline: not cancellable.
        if hangs { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
        if let error { throw error }
        return answer
    }

    public func endBatch() async { state.withLock { $0.batchesEnded += 1 } }

    public func stop() async {
        state.withLock { state in
            state.stopped = true
            state.continuation?.finish()
            state.continuation = nil
        }
    }
}

/// `LocalSearchIndexPort` in memory, with the same rules as the store, without full-text search: a query matches by tokens.
public final class FakeSearchIndex: LocalSearchIndexPort {
    private struct State {
        var entries: [EventID: (entry: SearchIndexEntry, checkedAt: Date, row: Int64)] = [:]
        var undecryptable: [EventID: RoomID] = [:]
        var due: Set<EventID> = []
        var coverage: [RoomID: RoomSearchCoverage] = [:]
        var checks: Set<RoomID> = []
        var gaps: [RoomID: EventID] = [:]
        var nextRow: Int64 = 1
        var error: HaloError?
        var operations: [SearchIndexOperation] = []
        var checkedAt = Date(timeIntervalSince1970: 0)
    }

    private let state = Mutex(State())
    public init() {}

    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    public func setCheckedAt(_ date: Date) { state.withLock { $0.checkedAt = date } }
    public var bodies: Set<String> { state.withLock { Set($0.entries.values.map(\.entry.content.body)) } }
    public var operations: [SearchIndexOperation] { state.withLock { $0.operations } }

    private func checkError() throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
    }

    public func apply(_ operations: [SearchIndexOperation]) async throws(HaloError) {
        try checkError()
        state.withLock { state in
            state.operations += operations
            for operation in operations { Self.apply(operation, &state) }
        }
    }

    private static func put(_ entry: SearchIndexEntry, _ state: inout State) {
        state.entries[entry.event] = (entry, state.checkedAt, state.entries[entry.event]?.row ?? state.nextRow)
        state.nextRow += 1
        state.undecryptable[entry.event] = nil
    }

    private static func apply(_ operation: SearchIndexOperation, _ state: inout State) {
        switch operation {
        case .live(let events):
            for event in events {
                switch event {
                case .message(let entry): put(entry, &state)
                case .edit(_, let target, _, let content):
                    guard let old = state.entries[target]?.entry else { continue }
                    put(SearchIndexEntry(room: old.room, event: old.event, sender: old.sender, senderName: old.senderName, threadRoot: old.threadRoot, timestamp: old.timestamp, content: content), &state)
                case .undecryptable(let room, let event): state.undecryptable[event] = room
                case .removed(_, let event): state.entries[event] = nil
                }
            }
        case .slice(let slice, let target):
            let known = slice.entries.first.map { state.entries[$0.event] != nil } ?? true
            for entry in slice.entries { put(entry, &state) }
            for event in slice.undecryptable { state.undecryptable[event] = target.room }
            switch target {
            case .history(let room):
                state.coverage[room] = RoomSearchCoverage(room: room, state: slice.reachedStart ? .complete : .partial, anchor: slice.oldest, oldest: slice.oldestTime)
            case .gap(let room, _): state.gaps[room] = known || slice.reachedStart ? nil : slice.oldest
            case .retry(_, let around): state.due.subtract(slice.entries.map(\.event) + slice.undecryptable + [around])
            }
        case .check(let rooms): state.checks.formUnion(rooms.filter { state.coverage[$0] != nil })
        case .checked(let room, let gapFrom):
            state.checks.remove(room)
            state.gaps[room] = gapFrom
        case .blocked(let room): state.coverage[room] = RoomSearchCoverage(room: room, state: .blocked, anchor: nil, oldest: nil)
        case .removeRooms(let rooms):
            for room in rooms {
                state.entries = state.entries.filter { $0.value.entry.room != room }
                state.coverage[room] = nil
                state.checks.remove(room)
                state.gaps[room] = nil
            }
        }
    }

    public func hits(match: String, room: RoomID?, kinds: Set<SearchKind>, excluding: Set<UserID>, after cursor: SearchCursor?, limit: Int) async throws(HaloError) -> [SearchIndexHit] {
        try checkError()
        let wanted = SearchTokeniser.terms(match)
        return state.withLock { state in
            let rows = state.entries.values.filter { row in
                guard room == nil || row.entry.room == room, kinds.contains(row.entry.content.kind), !excluding.contains(row.entry.sender) else { return false }
                let words = row.entry.indexText.split(separator: " ").map(String.init)
                return wanted.allSatisfy { term in
                    switch term {
                    case .prefix(let prefix): words.contains { $0.hasPrefix(prefix) }
                    case .phrase(let phrase): words.indices.contains { words[$0...].starts(with: phrase) }
                    }
                }
            }.sorted { ($0.entry.timestamp, $0.row) > ($1.entry.timestamp, $1.row) }
            return rows.map { SearchIndexHit(entry: $0.entry, cursor: SearchCursor(timestamp: Int64($0.entry.timestamp.timeIntervalSince1970 * 1000), row: $0.row), checkedAt: $0.checkedAt) }
                .filter { hit in cursor.map { (hit.cursor.timestamp, hit.cursor.row) < ($0.timestamp, $0.row) } ?? true }
                .prefix(limit).map { $0 }
        }
    }

    public func record(_ rechecks: [(room: RoomID, event: EventID, result: SearchRecheck)]) async throws(HaloError) {
        try checkError()
        state.withLock { state in
            for recheck in rechecks where recheck.result == .gone { state.entries[recheck.event] = nil }
        }
    }

    public func nextWork(rooms: [RoomID], limit: Int) async throws(HaloError) -> [SearchHistoryWork] {
        try checkError()
        return state.withLock { state in
            var result: [SearchHistoryWork] = rooms.filter(state.checks.contains).map { .check($0) }
            result += rooms.compactMap { room in state.gaps[room].map { .gap(room, before: $0) } }
            result += state.due.sorted { $0.rawValue < $1.rawValue }.compactMap { event in state.undecryptable[event].map { .retry($0, around: event) } }
            for room in rooms {
                switch state.coverage[room]?.state {
                case nil: result.append(.start(room))
                case .partial?: if let anchor = state.coverage[room]?.anchor { result.append(.history(room, before: anchor)) }
                case .complete?, .blocked?: break
                }
            }
            return Array(result.prefix(limit))
        }
    }

    public func known(_ events: [EventID], in room: RoomID) async throws(HaloError) -> Set<EventID> {
        try checkError()
        return state.withLock { state in Set(events.filter { state.entries[$0] != nil || state.undecryptable[$0] != nil }) }
    }

    public func coverage() async throws(HaloError) -> [RoomID: RoomSearchCoverage] {
        try checkError()
        return state.withLock { $0.coverage }
    }

    public func statistics() async throws(HaloError) -> SearchIndexStatistics {
        try checkError()
        return state.withLock { SearchIndexStatistics(messages: $0.entries.count, bytes: 1, undecryptable: $0.undecryptable.count) }
    }

    public func indexedRooms() async throws(HaloError) -> Set<RoomID> {
        try checkError()
        return state.withLock { Set($0.coverage.keys).union($0.entries.values.map(\.entry.room)) }
    }

    public func retryUndecryptableNow() async throws(HaloError) {
        try checkError()
        state.withLock { $0.due = Set($0.undecryptable.keys) }
    }

    public func clear() async throws(HaloError) {
        try checkError()
        state.withLock { state in
            state.entries = [:]
            state.coverage = [:]
            state.gaps = [:]
            state.checks = []
            state.undecryptable = [:]
        }
    }
}
