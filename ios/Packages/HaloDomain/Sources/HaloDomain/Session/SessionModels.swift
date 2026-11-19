import Foundation
import HaloFoundation

/// What a homeserver offers for signing in (docs/features/AUTHENTICATION.md §7).
public struct ServerDetails: Sendable, Equatable {
    public let homeserverURL: URL
    public let supportsPassword: Bool
    public let supportsOIDC: Bool
    /// Native Simplified Sliding Sync (MSC4186). Halo requires it (D4, AUTHENTICATION FR-5).
    public let supportsNativeSlidingSync: Bool

    public init(homeserverURL: URL, supportsPassword: Bool, supportsOIDC: Bool, supportsNativeSlidingSync: Bool) {
        self.homeserverURL = homeserverURL
        self.supportsPassword = supportsPassword
        self.supportsOIDC = supportsOIDC
        self.supportsNativeSlidingSync = supportsNativeSlidingSync
    }
}

/// Credentials for native Matrix password login (D64). `description` never contains the password.
public struct PasswordCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String
    public let deviceDisplayName: String

    public init(username: String, password: String, deviceDisplayName: String) {
        self.username = username
        self.password = password
        self.deviceDisplayName = deviceDisplayName
    }

    public var description: String { "PasswordCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

/// A signed-in session as the adapter serialised it. Only the adapter interprets `payload`
/// (AUTHENTICATION §7); Halo stores it in the Keychain as an opaque value.
public struct StoredSession: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UserID
    public let deviceID: DeviceID
    public let payload: Data

    public init(userID: UserID, deviceID: DeviceID, payload: Data) {
        self.userID = userID
        self.deviceID = deviceID
        self.payload = payload
    }

    public var description: String { "StoredSession(<redacted>)" }
    public var debugDescription: String { description }
}

/// Session changes that originate in the SDK rather than in a user action.
public enum SessionEvent: Sendable, Equatable {
    /// Tokens were refreshed; the new session must be persisted at once (AUTHENTICATION FR-7).
    case tokensRefreshed(StoredSession)
    /// The token was rejected but local data is kept (FR-9).
    case softLoggedOut
    /// The session is gone for good (e.g. signed out from another device).
    case loggedOut
}
