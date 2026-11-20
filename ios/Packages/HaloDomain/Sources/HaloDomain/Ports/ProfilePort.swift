import Foundation
import HaloFoundation

/// A user's public profile (docs/features/USER_PROFILES.md §7).
public struct UserProfile: Sendable, Equatable {
    public let userID: UserID
    public let displayName: String?

    public init(userID: UserID, displayName: String?) {
        self.userID = userID
        self.displayName = displayName
    }
}

/// Profiles and ignored users (USER_PROFILES FR-1…FR-4). Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`.
public protocol ProfilePort: Sendable {
    /// The signed-in user's display name; empty when none is set.
    func ownDisplayName() async throws(HaloError) -> String

    /// Sets the signed-in user's display name (FR-1).
    func setOwnDisplayName(_ name: String) async throws(HaloError)

    /// The signed-in user's avatar; `nil` when none is set.
    func ownAvatar() async throws(HaloError) -> MediaRef?

    /// Uploads `data` (already shrunk, `mimeType` such as image/jpeg) and sets it as the user's avatar (FR-1).
    func setOwnAvatar(mimeType: String, data: Data) async throws(HaloError)

    /// Removes the user's avatar.
    func removeOwnAvatar() async throws(HaloError)

    /// Another user's profile from the homeserver (FR-2). Throws `.notFound` for an unknown user.
    func profile(of user: UserID) async throws(HaloError) -> UserProfile

    /// The users the account ignores (FR-4).
    func ignoredUsers() async throws(HaloError) -> [UserID]

    /// Ignores `user`: their messages disappear after the next sync (FR-3).
    func ignore(_ user: UserID) async throws(HaloError)

    func unignore(_ user: UserID) async throws(HaloError)
}
