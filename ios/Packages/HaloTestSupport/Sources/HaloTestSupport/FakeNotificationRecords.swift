import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `NotificationRecordPort`.
public final class FakeNotificationRecords: NotificationRecordPort {
    private struct State {
        var records: [NotificationRecord] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func all() -> [NotificationRecord] { state.withLock { $0.records } }

    @discardableResult
    public func add(_ record: NotificationRecord) -> Bool {
        let result: (Bool, [AsyncStream<Void>.Continuation]) = state.withLock { state in
            guard !state.records.contains(where: { $0.eventID == record.eventID }) else { return (false, []) }
            state.records.append(record)
            return (true, Array(state.continuations.values))
        }
        for continuation in result.1 { continuation.yield() }
        return result.0
    }

    public func clear(room: RoomID) {
        let continuations = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            state.records.removeAll { $0.roomID == room }
            return Array(state.continuations.values)
        }
        for continuation in continuations { continuation.yield() }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }
}
