import HaloFoundation

/// Which rooms an account-wide notification default applies to (SETTINGS §3 → Notifications).
public enum NotificationDefaultKind: Sendable, Equatable, CaseIterable {
    case directChats, groupChats
}

/// The account's default notification mode for rooms without their own setting, kept on the server as push rules.
public protocol NotificationDefaultsPort: Sendable {
    /// The current default for `kind` (the one for unencrypted rooms, which Halo keeps equal to the encrypted one).
    func mode(for kind: NotificationDefaultKind) async throws(HaloError) -> RoomNotificationChoice

    /// Sets the default for `kind` in both encrypted and unencrypted rooms.
    func setMode(_ mode: RoomNotificationChoice, for kind: NotificationDefaultKind) async throws(HaloError)
}
