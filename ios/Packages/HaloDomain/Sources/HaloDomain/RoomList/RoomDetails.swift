import Foundation
import HaloFoundation

/// What the room info sheet shows (docs/features/ROOM_MANAGEMENT.md §7, FR-1).
public struct RoomDetails: Sendable, Equatable {
    public let id: RoomID
    public let name: String?
    public let topic: String?
    public let isDirect: Bool
    public let isEncrypted: Bool
    public let joinedMemberCount: Int
    public let notificationMode: RoomNotificationChoice
    /// The user may change the name and topic (power levels).
    public let canEditDetails: Bool
    /// The user may invite people.
    public let canInvite: Bool

    public init(
        id: RoomID, name: String?, topic: String?, isDirect: Bool, isEncrypted: Bool, joinedMemberCount: Int, notificationMode: RoomNotificationChoice,
        canEditDetails: Bool = false, canInvite: Bool = false
    ) {
        self.canEditDetails = canEditDetails
        self.canInvite = canInvite
        self.id = id
        self.name = name
        self.topic = topic
        self.isDirect = isDirect
        self.isEncrypted = isEncrypted
        self.joinedMemberCount = joinedMemberCount
        self.notificationMode = notificationMode
    }
}

extension RoomDetails {
    /// A copy with another notification mode.
    public func with(notificationMode: RoomNotificationChoice) -> RoomDetails {
        RoomDetails(id: id, name: name, topic: topic, isDirect: isDirect, isEncrypted: isEncrypted, joinedMemberCount: joinedMemberCount, notificationMode: notificationMode, canEditDetails: canEditDetails, canInvite: canInvite)
    }

    /// A copy with another name and topic.
    public func with(name: String?, topic: String?) -> RoomDetails {
        RoomDetails(id: id, name: name, topic: topic, isDirect: isDirect, isEncrypted: isEncrypted, joinedMemberCount: joinedMemberCount, notificationMode: notificationMode, canEditDetails: canEditDetails, canInvite: canInvite)
    }
}

/// The three notification modes of a room (ROOM_MANAGEMENT FR-3).
public enum RoomNotificationChoice: Sendable, Equatable, CaseIterable {
    case allMessages, mentionsAndKeywords, mute
}

/// A joined or invited member (ROOM_MANAGEMENT FR-2).
public struct RoomMemberInfo: Sendable, Equatable, Identifiable {
    public var id: String { userID }
    /// The raw Matrix user ID, shown to the user in the members list only; never logged.
    public let userID: String
    public let displayName: String?
    public let role: RoomMemberRole
    public let isInvited: Bool
    /// `true` for the signed-in user.
    public let isMe: Bool

    public init(userID: String, displayName: String?, role: RoomMemberRole, isInvited: Bool = false, isMe: Bool = false) {
        self.isMe = isMe
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.isInvited = isInvited
    }

    /// The name to show: the display name, else the user ID.
    public var title: String { displayName?.isEmpty == false ? displayName! : userID }
}

/// Power-level badge of a member (ROOM_MANAGEMENT FR-2).
public enum RoomMemberRole: Sendable, Equatable {
    case administrator, moderator, user
}
