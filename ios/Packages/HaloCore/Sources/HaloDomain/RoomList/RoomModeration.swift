import Foundation
import HaloFoundation

/// A Matrix member's effective power level, supporting room v12 infinite creator power levels (ROOM_MANAGEMENT FR-10, M20-12).
public enum RoomPowerLevel: Sendable, Equatable, Comparable {
    case level(Int64)
    /// Room v12 creator power level: strictly greater than any finite power level.
    case infinite

    public static func < (lhs: RoomPowerLevel, rhs: RoomPowerLevel) -> Bool {
        switch (lhs, rhs) {
        case (.level(let a), .level(let b)): a < b
        case (.level, .infinite): true
        case (.infinite, _): false
        }
    }
}

/// Live moderation capabilities of the signed-in user in a room, derived from `m.room.power_levels` (M20-12).
public struct RoomModerationPermissions: Sendable, Equatable {
    public let canKick: Bool
    public let canBan: Bool
    public let ownPowerLevel: RoomPowerLevel

    public static let none = RoomModerationPermissions(canKick: false, canBan: false, ownPowerLevel: .level(0))

    public init(canKick: Bool, canBan: Bool, ownPowerLevel: RoomPowerLevel) {
        self.canKick = canKick
        self.canBan = canBan
        self.ownPowerLevel = ownPowerLevel
    }
}

/// Pure policy gating remove, ban, and unban actions by live Matrix power levels (ROOM_MANAGEMENT FR-10, AC-ROOM-4, M20-12).
public enum RoomModerationPolicy {
    public enum Action: Sendable, Equatable {
        case remove
        case ban
        case unban
    }

    public struct MemberActions: Sendable, Equatable {
        public let canRemove: Bool
        public let canBan: Bool
        public let canUnban: Bool

        public static let none = MemberActions(canRemove: false, canBan: false, canUnban: false)

        public var isEmpty: Bool { !canRemove && !canBan && !canUnban }

        public init(canRemove: Bool, canBan: Bool, canUnban: Bool) {
            self.canRemove = canRemove
            self.canBan = canBan
            self.canUnban = canUnban
        }
    }

    /// Computes which moderation actions may be offered for `target` under live `permissions` (AC-ROOM-4).
    ///
    /// Matrix specification rules:
    /// - A user can never remove, ban, or unban themselves through moderation actions.
    /// - The acting user's power level must be strictly greater than `target.powerLevel`.
    /// - Unbanning requires both `ban` and `kick` permissions (Matrix Client-Server API §10.2.2).
    public static func actions(for target: RoomMemberInfo, permissions: RoomModerationPermissions) -> MemberActions {
        guard !target.isMe, permissions.ownPowerLevel > target.powerLevel else {
            return .none
        }
        if target.isBanned {
            return MemberActions(canRemove: false, canBan: false, canUnban: permissions.canBan && permissions.canKick)
        }
        return MemberActions(canRemove: permissions.canKick, canBan: permissions.canBan, canUnban: false)
    }

    /// Role label displayed alongside a member in the room members list (M20-12).
    public static func roleLabel(for member: RoomMemberInfo) -> String? {
        if member.powerLevel == .infinite { return "Creator" }
        switch member.role {
        case .administrator: return "Admin"
        case .moderator: return "Moderator"
        case .user: return nil
        }
    }

    /// Honest, user-facing explanation when a moderation request is refused or fails (AC-ROOM-4).
    public static func errorMessage(for error: HaloError, action: Action) -> String {
        switch error {
        case .forbidden:
            switch action {
            case .remove: "You don't have permission to remove this person from the room."
            case .ban: "You don't have permission to ban this person from the room."
            case .unban: "You don't have permission to unban this person."
            }
        case .network:
            "You appear to be offline. Try again."
        case .notFound:
            switch action {
            case .unban: "That person isn't banned from this room."
            case .remove, .ban: "That person isn't in this room any more."
            }
        default:
            switch action {
            case .remove: "Couldn't remove this person. Try again."
            case .ban: "Couldn't ban this person. Try again."
            case .unban: "Couldn't unban this person. Try again."
            }
        }
    }
}
