import Foundation
import HaloFoundation

/// A room as the room list shows it (docs/features/ROOM_LIST.md §7). M0 subset; avatar, latest event,
/// favourite flag and notification mode are added with the room list in M1.
public struct RoomSummary: Sendable, Equatable, Identifiable {
    public let id: RoomID
    /// The computed display name, or `nil` while the SDK has none.
    public let name: String?
    public let isDirect: Bool
    public let isEncrypted: Bool
    public let membership: Membership
    /// Unread inputs for the read-state policy (`ReadStatePolicy`); `.none` until known.
    public let read: RoomReadCounts
    /// The newest event the SDK knows in the room (time and whether the user sent it); `nil` when unknown.
    public let latestEvent: LatestEventRef?
    /// The time of the event the user's own newest read receipt (any device) points at; `nil` when unknown or not resolved.
    public let ownReadThrough: Date?
    /// The user marked the room as a favourite (room tag `m.favourite`).
    public let isFavourite: Bool

    public init(
        id: RoomID, name: String?, isDirect: Bool, isEncrypted: Bool, membership: Membership, read: RoomReadCounts = .none,
        latestEvent: LatestEventRef? = nil, ownReadThrough: Date? = nil, isFavourite: Bool = false
    ) {
        self.isFavourite = isFavourite
        self.latestEvent = latestEvent
        self.ownReadThrough = ownReadThrough
        self.read = read
        self.id = id
        self.name = name
        self.isDirect = isDirect
        self.isEncrypted = isEncrypted
        self.membership = membership
    }
}

public enum Membership: Sendable, Equatable {
    case joined, invited, knocked, left, banned
}

/// Room-list filters (ROOM_LIST §2, FR-2).
public enum RoomListFilter: Sendable, Equatable {
    case all, unread, people, rooms, favourites, invites
}

/// One change to the ordered room list (see `ListDiff`).
public typealias RoomListDiff = ListDiff<RoomSummary>

/// Applies room-list diffs to an array. Pure.
public enum RoomListReducer {
    /// Applies `diff` to `rooms`; throws `.internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE")` for a diff that
    /// doesn't fit, leaving `rooms` unchanged. The caller must resubscribe to get a `.reset`.
    public static func apply(_ diff: RoomListDiff, to rooms: inout [RoomSummary]) throws(HaloError) {
        do { try ListReducer.apply(diff, to: &rooms) } catch { throw .internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE") }
    }
}
