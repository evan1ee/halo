import Foundation
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
        var joined: [String] = []
        var started: [UserID] = []
        var savedRoom: RoomID?
        var counter = 0
    }
    private let state: Mutex<State>

    public init(directory: [UserSummary] = [], existing: [UserID: RoomID] = [:]) { state = Mutex(State(directory: directory, existing: existing)) }

    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    public var createdRooms: [(name: String, invite: [UserID])] { state.withLock { $0.created } }
    public var joinedAddresses: [String] { state.withLock { $0.joined } }
    /// The people `startDirectChat` was called for, in order.
    public var startedChats: [UserID] { state.withLock { $0.started } }

    public func searchUsers(_ term: String, limit: Int) async throws(HaloError) -> [UserSummary] {
        let (directory, error) = state.withLock { ($0.directory, $0.error) }
        if let error { throw error }
        let needle = term.lowercased()
        guard !needle.isEmpty else { return [] }
        return Array(directory.filter { $0.title.lowercased().contains(needle) || $0.id.rawValue.lowercased().contains(needle) }.prefix(limit))
    }

    public func startDirectChat(with user: UserID) async throws(HaloError) -> RoomID {
        state.withLock { $0.started.append(user) }
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

    public func openOrCreateSavedRoom() async throws(HaloError) -> RoomID {
        if let error = state.withLock({ $0.error }) { throw error }
        if let existing = state.withLock({ $0.savedRoom }) { return existing }
        let id = try nextRoom()
        state.withLock { $0.savedRoom = id }
        return id
    }

    public func joinRoom(_ idOrAlias: String) async throws(HaloError) -> RoomID {
        if let error = state.withLock({ $0.error }) { throw error }
        let trimmed = idOrAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("#") || trimmed.hasPrefix("!")), trimmed.contains(":") else {
            throw .invalidInput("ROOM_ADDRESS")
        }
        state.withLock { $0.joined.append(trimmed) }
        if trimmed.hasPrefix("!"), let direct = try? RoomID(trimmed) { return direct }
        return try nextRoom()
    }

    private func nextRoom() throws(HaloError) -> RoomID {
        let n = state.withLock { state -> Int in state.counter += 1; return state.counter }
        return try RoomID("!new\(n):x.org")
    }
}
