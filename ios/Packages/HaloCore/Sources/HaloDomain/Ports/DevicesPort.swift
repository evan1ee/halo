import Foundation
import HaloFoundation

/// One of the account's signed-in sessions, as the homeserver lists them (docs/features/SETTINGS.md §3 → Account → Sessions).
public struct SessionDevice: Sendable, Equatable, Identifiable {
    public let id: String
    /// The name the device gave itself at sign-in; `nil` when it has none.
    public let displayName: String?
    /// When the homeserver last heard from the device; `nil` when it never recorded one.
    public let lastSeen: Date?
    /// This is the device the app runs on.
    public let isCurrent: Bool

    public init(id: String, displayName: String?, lastSeen: Date?, isCurrent: Bool) {
        self.id = id
        self.displayName = displayName
        self.lastSeen = lastSeen
        self.isCurrent = isCurrent
    }
}

/// The account's sessions on the homeserver, and signing the others out (M18-13). Signing out needs interactive authentication
/// with the password; an account that signs in through an account page (OIDC) does that there (D117).
public protocol DevicesPort: Sendable {
    /// All sessions of the signed-in account, this device first, then the most recently seen.
    func devices() async throws(HaloError) -> [SessionDevice]
    /// Whether Halo can sign other sessions out itself (password accounts); `false` when the account page does it.
    func canSignOutOthers() async -> Bool
    /// Signs these sessions out, confirmed with the account password. This device can't be one of them
    /// (`.invalidInput("CURRENT_DEVICE")`); a wrong password is `.invalidInput("CURRENT_PASSWORD")`.
    func signOut(devices: [String], password: String) async throws(HaloError)
}

extension DevicesPort {
    public func canSignOutOthers() async -> Bool { false }
    public func signOut(devices: [String], password: String) async throws(HaloError) { throw .unsupported("SIGN_OUT_OTHERS") }
}
