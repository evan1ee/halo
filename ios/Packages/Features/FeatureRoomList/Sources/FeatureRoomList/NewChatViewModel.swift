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
    /// The signed-in user: never offered as someone to chat with.
    private let ownUserID: UserID?
    private var searchTask: Task<Void, Never>?
    /// The term the current `results` answer, so "no one found" never shows for a search still running.
    private var answeredTerm: String?

    public init(port: any ChatCreationPort, ownUserID: UserID? = nil, onCreated: @escaping @MainActor (RoomID) -> Void) {
        self.ownUserID = ownUserID
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
        let all: [UserSummary]
        if let typed = typedUser, !results.contains(where: { $0.id == typed.id }) { all = [typed] + results } else { all = results }
        return all.filter { $0.id != ownUserID }
    }

    /// True while a search for the typed text hasn't answered yet.
    public var isSearching: Bool { !trimmedQuery.isEmpty && answeredTerm != query }

    /// The typed text was searched and nobody matched: the view says so instead of showing nothing.
    public var foundNobody: Bool { !trimmedQuery.isEmpty && answeredTerm == query && candidates.isEmpty }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func search() async {
        let term = query
        do {
            let found = try await port.searchUsers(term, limit: 20)
            guard !Task.isCancelled, term == query else { return }
            results = found
            answeredTerm = term
            errorText = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorText = Self.text(error)
            answeredTerm = term
        }
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
