import HaloFoundation

/// Which rooms an account-wide notification default applies to (SETTINGS §3 → Notifications).
public enum NotificationDefaultKind: Sendable, Equatable, CaseIterable {
    case directChats, groupChats
}

/// The mention push rules the account can switch (SETTINGS §3 → Notifications → mentions & keywords).
public enum NotificationMentionKind: Sendable, Equatable, CaseIterable {
    /// Messages that mention the user's name or Matrix ID.
    case user
    /// `@room` messages.
    case room
}

/// The account's default notification mode for rooms without their own setting, kept on the server as push rules.
public protocol NotificationDefaultsPort: Sendable {
    /// The current default for `kind` (the one for unencrypted rooms, which Halo keeps equal to the encrypted one).
    func mode(for kind: NotificationDefaultKind) async throws(HaloError) -> RoomNotificationChoice

    /// Sets the default for `kind` in both encrypted and unencrypted rooms.
    func setMode(_ mode: RoomNotificationChoice, for kind: NotificationDefaultKind) async throws(HaloError)

    /// Whether the push rule for `kind` is on.
    func isMentionEnabled(_ kind: NotificationMentionKind) async throws(HaloError) -> Bool

    func setMention(_ kind: NotificationMentionKind, enabled: Bool) async throws(HaloError)
}
