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

/// The account's sessions on the homeserver. Read-only: signing other sessions out needs interactive authentication and is
/// not built.
public protocol DevicesPort: Sendable {
    /// All sessions of the signed-in account, this device first, then the most recently seen.
    func devices() async throws(HaloError) -> [SessionDevice]
}
