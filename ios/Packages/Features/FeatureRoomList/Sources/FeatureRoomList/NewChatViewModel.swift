import Foundation
import HaloDomain
import HaloFoundation
import Observation

/// "New chat": search the directory, start a direct chat or create a private room (ROOM_MANAGEMENT FR-5).
@MainActor @Observable
public final class NewChatViewModel: Identifiable {
    public private(set) var results: [UserSummary] = []
    public private(set) var isWorking = false
    public private(set) var errorText: String?
    /// Matrix IDs the user typed in full are offered even when the directory doesn't list them.
    public var query = "" { didSet { if query != oldValue { searchTask?.cancel(); searchTask = Task { await search() } } } }
    public var roomName = ""
    /// Users picked for the new room.
    public private(set) var invited: [UserSummary] = []

    private let port: any ChatCreationPort
    private let onCreated: @MainActor (RoomID) -> Void
    private var searchTask: Task<Void, Never>?

    public init(port: any ChatCreationPort, onCreated: @escaping @MainActor (RoomID) -> Void) {
        self.port = port
        self.onCreated = onCreated
    }

    isolated deinit { searchTask?.cancel() }

    /// The typed text as a user, when it is a complete Matrix ID.
    public var typedUser: UserSummary? {
        guard let id = try? UserID(query.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return UserSummary(id: id, displayName: nil)
    }

    /// Directory matches, preceded by the typed Matrix ID when the directory doesn't list it.
    public var candidates: [UserSummary] {
        if let typed = typedUser, !results.contains(where: { $0.id == typed.id }) { return [typed] + results }
        return results
    }

    func search() async {
        let term = query
        do {
            let found = try await port.searchUsers(term, limit: 20)
            guard !Task.isCancelled, term == query else { return }
            results = found
            errorText = nil
        } catch { if !Task.isCancelled { errorText = Self.text(error) } }
    }

    public func startChat(with user: UserSummary) async {
        await run { () async throws(HaloError) -> RoomID in try await port.startDirectChat(with: user.id) }
    }

    public func toggleInvite(_ user: UserSummary) {
        if let index = invited.firstIndex(where: { $0.id == user.id }) { invited.remove(at: index) } else { invited.append(user) }
    }

    public var canCreateRoom: Bool { !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking }

    public func createRoom() async {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let ids = invited.map(\.id)
        await run { () async throws(HaloError) -> RoomID in try await port.createRoom(name: name, invite: ids) }
    }

    private func run(_ action: () async throws(HaloError) -> RoomID) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do throws(HaloError) {
            let room = try await action()
            errorText = nil
            onCreated(room)
        } catch { errorText = Self.text(error) }
    }

    private static func text(_ error: HaloError) -> String {
        switch error {
        case .network: "You appear to be offline. Try again."
        case .forbidden: "You can't do that on this server."
        default: "That didn't work. Try again."
        }
    }
}
