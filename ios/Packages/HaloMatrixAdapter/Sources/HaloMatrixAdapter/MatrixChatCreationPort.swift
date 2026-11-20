import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `ChatCreationPort` over `Client.searchUsers`, `getDmRoom` and `createRoom` (ROOM_MANAGEMENT FR-5, F-FFI-18).
public final class MatrixChatCreationPort: ChatCreationPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func searchUsers(_ term: String, limit: Int) async throws(HaloError) -> [UserSummary] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let client = try await session.signedInClient()
        let own = try await session.ownUserID()
        do {
            let found = try await client.searchUsers(searchTerm: trimmed, limit: UInt64(limit))
            return found.results.compactMap { profile in
                guard profile.userId != own, let id = try? UserID(profile.userId) else { return nil }
                return UserSummary(id: id, displayName: profile.displayName)
            }
        } catch { throw ErrorMapper.map(error) }
    }

    public func startDirectChat(with user: UserID) async throws(HaloError) -> RoomID {
        let client = try await session.signedInClient()
        do {
            if let existing = try client.getDmRoom(userId: user.rawValue) { return try RoomID(existing.id()) }
            let id = try await client.createRoom(request: CreateRoomParameters(name: nil, isEncrypted: true, isDirect: true, visibility: .private, preset: .trustedPrivateChat, invite: [user.rawValue]))
            return try RoomID(id)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    public func createRoom(name: String, invite: [UserID]) async throws(HaloError) -> RoomID {
        let client = try await session.signedInClient()
        do {
            let id = try await client.createRoom(request: CreateRoomParameters(name: name, isEncrypted: true, visibility: .private, preset: .privateChat, invite: invite.map(\.rawValue)))
            return try RoomID(id)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }
}
