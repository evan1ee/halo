import Foundation
import HaloFoundation

/// Reference to the replacement room announced by an `m.room.tombstone` event (ROOM_MANAGEMENT FR-11, GA-23, M20-8).
public struct RoomSuccessor: Sendable, Equatable {
    public let roomID: RoomID
    public let reason: String?

    public init(roomID: RoomID, reason: String? = nil) {
        self.roomID = roomID
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// How non-members may enter a room, mapped from Matrix `m.room.join_rules` (ROOM_MANAGEMENT FR-11, M20-8).
public enum RoomJoinAccess: Sendable, Equatable {
    case `public`
    case knock
    case inviteOnly
    case restricted
    case unknown
}

/// Preview metadata for a room before joining, knocking, or managing a left/banned state (M20-8).
public struct RoomLifecyclePreview: Sendable, Equatable, Identifiable {
    public var id: String { roomID?.rawValue ?? address }
    public let roomID: RoomID?
    public let address: String
    public let name: String?
    public let topic: String?
    public let avatar: MediaRef?
    public let memberCount: Int?
    public let membership: Membership?
    public let joinAccess: RoomJoinAccess

    public init(
        roomID: RoomID?,
        address: String,
        name: String? = nil,
        topic: String? = nil,
        avatar: MediaRef? = nil,
        memberCount: Int? = nil,
        membership: Membership? = nil,
        joinAccess: RoomJoinAccess = .unknown
    ) {
        self.roomID = roomID
        self.address = address
        self.name = name
        self.topic = topic
        self.avatar = avatar
        self.memberCount = memberCount
        self.membership = membership
        self.joinAccess = joinAccess
    }

    /// Best human-readable label for the room.
    public var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return address
    }
}

/// Explicit UI state and allowed actions for a room preview (ROADMAP M20-8: each state has a screen and an action).
public enum RoomPreviewPresentation: Sendable, Equatable {
    case alreadyJoined(RoomID)
    case invited(RoomID)
    case canJoin
    case canKnock
    case knocked(RoomID?)
    case inviteOnly
    case banned(RoomID?)
    case left(RoomID, canRejoin: Bool)
}

/// Non-composer lifecycle banner shown inside an open timeline when the room can no longer be messaged normally (M20-8).
public enum RoomBannerState: Sendable, Equatable {
    case upgraded(RoomSuccessor)
    case left(RoomID)
    case banned(RoomID)
    case knocked(RoomID)
}

/// Pure policy mapping room membership, join rules, and tombstone state into honest screens and actions (M20-8).
public enum RoomLifecyclePolicy {
    public static func presentation(for preview: RoomLifecyclePreview) -> RoomPreviewPresentation {
        switch preview.membership {
        case .joined:
            if let id = preview.roomID { return .alreadyJoined(id) }
        case .invited:
            if let id = preview.roomID { return .invited(id) }
        case .knocked:
            return .knocked(preview.roomID)
        case .banned:
            return .banned(preview.roomID)
        case .left:
            if let id = preview.roomID {
                let canRejoin = preview.joinAccess == .public || preview.joinAccess == .restricted
                return .left(id, canRejoin: canRejoin)
            }
        case nil:
            break
        }

        switch preview.joinAccess {
        case .public, .restricted, .unknown:
            return .canJoin
        case .knock:
            return .canKnock
        case .inviteOnly:
            return .inviteOnly
        }
    }

    public static func banner(
        membership: Membership,
        successor: RoomSuccessor?,
        roomID: RoomID
    ) -> RoomBannerState? {
        switch membership {
        case .banned: return .banned(roomID)
        case .left: return .left(roomID)
        case .knocked: return .knocked(roomID)
        case .joined, .invited:
            if let successor { return .upgraded(successor) }
            return nil
        }
    }
}
