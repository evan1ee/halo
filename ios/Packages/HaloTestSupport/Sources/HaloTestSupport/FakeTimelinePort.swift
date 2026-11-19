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
        var sent: [String] = []
        var paginateCalls = 0
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

    public func sentTexts(in id: RoomID) -> [String] { rooms.withLock { $0[id]?.sent ?? [] } }
    public func openSessions(in id: RoomID) -> Int { rooms.withLock { $0[id]?.openSessions ?? 0 } }
    public func paginateCalls(in id: RoomID) -> Int { rooms.withLock { $0[id]?.paginateCalls ?? 0 } }

    // MARK: TimelinePort

    public func open(room id: RoomID) async throws(HaloError) -> any TimelineSession {
        try rooms.withLock { (rooms) throws(HaloError) in
            guard rooms[id] != nil else { throw .notFound }
            rooms[id]?.openSessions += 1
        }
        return Session(port: self, room: id)
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

        func send(text: String) async throws(HaloError) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_MESSAGE") }
            let count = port.rooms.withLock { rooms -> Int in
                rooms[room]?.sent.append(trimmed)
                return rooms[room]?.items.count ?? 0
            }
            let item = TimelineItem(
                id: TimelineItemID("local-\(UUID().uuidString)"),
                content: .event(TimelineEvent(
                    eventID: nil, sender: nil, senderName: nil, timestamp: Date(), isOwn: true,
                    kind: .text(trimmed, isEdited: false), sendState: .sending)))
            try? port.emit(.pushBack(item), in: room)
            // The server confirms: the echo turns into the sent event in place.
            let confirmed = TimelineItem(
                id: item.id,
                content: .event(TimelineEvent(
                    eventID: nil, sender: nil, senderName: nil, timestamp: Date(), isOwn: true,
                    kind: .text(trimmed, isEdited: false), sendState: .sent)))
            try? port.emit(.set(index: count, confirmed), in: room)
        }

        func close() async { port.rooms.withLock { $0[room]?.openSessions -= 1 } }
    }
}
