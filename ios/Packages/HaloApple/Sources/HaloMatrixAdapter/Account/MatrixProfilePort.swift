import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `ProfilePort` over `Client.displayName/setDisplayName/getProfile/ignoredUsers` and account data (USER_PROFILES, F-FFI-4).
public final class MatrixProfilePort: ProfilePort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func ownDisplayName() async throws(HaloError) -> String {
        let client = try await session.signedInClient()
        do { return try await client.displayName() } catch { throw ErrorMapper.map(error) }
    }

    public func setOwnDisplayName(_ name: String) async throws(HaloError) {
        let client = try await session.signedInClient()
        do { try await client.setDisplayName(name: name) } catch { throw ErrorMapper.map(error) }
    }

    public func ownAvatar() async throws(HaloError) -> MediaRef? {
        let client = try await session.signedInClient()
        do { return MatrixRoomListPort.avatar(try await client.avatarUrl()) } catch { throw ErrorMapper.map(error) }
    }

    public func setOwnAvatar(mimeType: String, data: Data) async throws(HaloError) {
        let client = try await session.signedInClient()
        do { try await client.uploadAvatar(mimeType: mimeType, data: data) } catch { throw ErrorMapper.map(error) }
    }

    public func removeOwnAvatar() async throws(HaloError) {
        let client = try await session.signedInClient()
        do { try await client.removeAvatar() } catch { throw ErrorMapper.map(error) }
    }

    public func profile(of user: UserID) async throws(HaloError) -> HaloDomain.UserProfile {
        let client = try await session.signedInClient()
        do {
            let profile = try await client.getProfile(userId: user.rawValue)
            return HaloDomain.UserProfile(userID: user, displayName: profile.displayName)
        } catch { throw ErrorMapper.map(error) }
    }

    public func ignoredUsers() async throws(HaloError) -> [UserID] {
        let client = try await session.signedInClient()
        do { return try await client.ignoredUsers().compactMap { try? UserID($0) } } catch { throw ErrorMapper.map(error) }
    }

    /// Ignoring and unignoring change the server's `m.ignored_user_list` (D120). The SDK's `ignoreUser`/`unignoreUser` work from
    /// its local copy: before the first sync is stored that drops the users already ignored, and an unignore right after an
    /// ignore changes nothing (both found against infra/dev).
    public func ignore(_ user: UserID) async throws(HaloError) {
        try await changeIgnored { users in
            guard users[user.rawValue] == nil else { return false }
            users[user.rawValue] = [String: Any]()
            return true
        }
    }

    public func unignore(_ user: UserID) async throws(HaloError) {
        try await changeIgnored { $0.removeValue(forKey: user.rawValue) != nil }
    }

    /// `change` returns whether it changed anything.
    private func changeIgnored(_ change: (inout [String: Any]) -> Bool) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            try await ServerAccountData(client).update("m.ignored_user_list") { current in
                var content = current ?? [:]
                var users = content["ignored_users"] as? [String: Any] ?? [:]
                guard change(&users) else { return nil }
                content["ignored_users"] = users
                return content
            }
        } catch { throw ErrorMapper.map(error) }
    }
}
