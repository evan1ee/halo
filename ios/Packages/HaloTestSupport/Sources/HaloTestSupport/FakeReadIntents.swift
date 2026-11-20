import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `ReadIntentPort` with the same monotonic rules as the database.
public final class FakeReadIntents: ReadIntentPort {
    private let store = Mutex<[RoomID: ReadIntent]>([:])

    public init(_ initial: [ReadIntent] = []) { store.withLock { for i in initial { $0[i.room] = i } } }

    public var intents: [ReadIntent] { store.withLock { Array($0.values) } }

    public func all() async throws(HaloError) -> [ReadIntent] { intents }

    public func save(_ intent: ReadIntent) async throws(HaloError) {
        store.withLock { rooms in
            if let existing = rooms[intent.room] {
                if intent.timestamp < existing.timestamp { return }
                if intent.event == existing.event, existing.isSent, !intent.isSent { return }
            }
            rooms[intent.room] = intent
        }
    }

    public func recordFailure(room: RoomID, event: EventID, code: String) async throws(HaloError) {
        store.withLock { rooms in
            guard let i = rooms[room], i.event == event, !i.isSent else { return }
            rooms[room] = ReadIntent(
                room: room, event: event, timestamp: i.timestamp, isSent: false, createdAt: i.createdAt, attempts: i.attempts + 1, lastError: code)
        }
    }

    public func removeSent(createdBefore date: Date) async throws(HaloError) {
        store.withLock { rooms in rooms = rooms.filter { !($0.value.isSent && $0.value.createdAt < date) } }
    }
}
