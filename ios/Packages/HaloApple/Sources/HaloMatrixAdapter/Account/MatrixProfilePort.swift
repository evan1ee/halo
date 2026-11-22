import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `ProfilePort` over `Client.displayName/setDisplayName/getProfile/ignoreUser/unignoreUser/ignoredUsers` (USER_PROFILES, F-FFI-4).
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

    public func ignore(_ user: UserID) async throws(HaloError) {
        let client = try await session.signedInClient()
        do { try await client.ignoreUser(userId: user.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    /// Unignores `user`. Found against infra/dev: right after `ignoreUser` the SDK's `unignoreUser` can succeed without changing the
    /// server's list (it works from its local copy, which the sync echo of the first call hasn't updated yet), so the result is read
    /// back and the call repeated after a short wait, up to four times.
    public func unignore(_ user: UserID) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            for attempt in 0..<4 {
                try await client.unignoreUser(userId: user.rawValue)
                guard try await client.ignoredUsers().contains(user.rawValue) else { return }
                if attempt < 3 { try await Task.sleep(for: .seconds(2)) }
            }
        } catch { throw ErrorMapper.map(error) }
    }
}
