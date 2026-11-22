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

    /// Account data key storing the user's private encrypted Saved Messages room (D63 namespace `one.mbm.halo.*`, M8).
    public static let savedRoomAccountDataType = "one.mbm.halo.saved_room"

    public func createRoom(name: String, invite: [UserID]) async throws(HaloError) -> RoomID {
        let client = try await session.signedInClient()
        do {
            let id = try await client.createRoom(request: CreateRoomParameters(name: name, isEncrypted: true, visibility: .private, preset: .privateChat, invite: invite.map(\.rawValue)))
            return try RoomID(id)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    public func openOrCreateSavedRoom() async throws(HaloError) -> RoomID {
        let client = try await session.signedInClient()
        do {
            if let raw = try await client.accountData(eventType: Self.savedRoomAccountDataType),
               let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let existingID = obj["room_id"] as? String,
               let room = try? client.getRoom(roomId: existingID),
               room.membership() == .joined {
                return try RoomID(existingID)
            }
            let created = try await client.createRoom(request: CreateRoomParameters(
                name: "Saved Messages", isEncrypted: true, visibility: .private, preset: .privateChat, invite: []))
            let payload = try JSONSerialization.data(withJSONObject: ["room_id": created, "version": 1], options: [.sortedKeys])
            try await client.setAccountData(
                eventType: Self.savedRoomAccountDataType,
                content: String(decoding: payload, as: UTF8.self))
            return try RoomID(created)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    public func joinRoom(_ idOrAlias: String) async throws(HaloError) -> RoomID {
        let trimmed = idOrAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("#") || trimmed.hasPrefix("!")),
              let colon = trimmed.firstIndex(of: ":"),
              trimmed.distance(from: trimmed.startIndex, to: colon) > 1
        else {
            throw .invalidInput("ROOM_ADDRESS")
        }
        let server = String(trimmed[trimmed.index(after: colon)...])
        guard !server.isEmpty else { throw .invalidInput("ROOM_ADDRESS") }
        let client = try await session.signedInClient()
        do {
            let room = try await client.joinRoomByIdOrAlias(roomIdOrAlias: trimmed, serverNames: [server])
            return try RoomID(room.id())
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }
}
