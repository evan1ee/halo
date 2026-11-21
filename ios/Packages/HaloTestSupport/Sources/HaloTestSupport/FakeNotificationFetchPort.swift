import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `NotificationFetchPort` for unit testing the NSE notification pipeline.
public final class FakeNotificationFetchPort: NotificationFetchPort {
    private struct State {
        var results: [EventID: Result<NotificationFetchResult, HaloError>] = [:]
        var fetched: [(RoomID, EventID)] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func setResult(_ result: Result<NotificationFetchResult, HaloError>, for event: EventID) {
        state.withLock { $0.results[event] = result }
    }

    public var fetched: [(RoomID, EventID)] { state.withLock { $0.fetched } }

    public func fetch(room: RoomID, event: EventID) async throws(HaloError) -> NotificationFetchResult {
        let outcome = state.withLock { state -> Result<NotificationFetchResult, HaloError> in
            state.fetched.append((room, event))
            return state.results[event] ?? .failure(.notFound)
        }
        return try outcome.get()
    }
}
