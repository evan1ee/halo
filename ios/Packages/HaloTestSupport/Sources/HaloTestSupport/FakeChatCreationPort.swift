import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `ChatCreationPort`: a fixed directory, one existing DM per user, and records of what was created.
public final class FakeChatCreationPort: ChatCreationPort {
    private struct State {
        var directory: [UserSummary]
        var existing: [UserID: RoomID]
        var error: HaloError?
        var created: [(name: String, invite: [UserID])] = []
        var counter = 0
    }
    private let state: Mutex<State>

    public init(directory: [UserSummary] = [], existing: [UserID: RoomID] = [:]) { state = Mutex(State(directory: directory, existing: existing)) }

    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    public var createdRooms: [(name: String, invite: [UserID])] { state.withLock { $0.created } }

    public func searchUsers(_ term: String, limit: Int) async throws(HaloError) -> [UserSummary] {
        let (directory, error) = state.withLock { ($0.directory, $0.error) }
        if let error { throw error }
        let needle = term.lowercased()
        guard !needle.isEmpty else { return [] }
        return Array(directory.filter { $0.title.lowercased().contains(needle) || $0.id.rawValue.lowercased().contains(needle) }.prefix(limit))
    }

    public func startDirectChat(with user: UserID) async throws(HaloError) -> RoomID {
        let (known, error) = state.withLock { ($0.existing[user], $0.error) }
        if let error { throw error }
        if let known { return known }
        let id = try nextRoom()
        state.withLock { $0.existing[user] = id }
        return id
    }

    public func createRoom(name: String, invite: [UserID]) async throws(HaloError) -> RoomID {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.created.append((name, invite)) }
        return try nextRoom()
    }

    private func nextRoom() throws(HaloError) -> RoomID {
        let n = state.withLock { state -> Int in state.counter += 1; return state.counter }
        return try RoomID("!new\(n):x.org")
    }
}
