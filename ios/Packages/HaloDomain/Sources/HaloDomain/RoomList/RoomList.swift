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

    public init(id: RoomID, name: String?, isDirect: Bool, isEncrypted: Bool, membership: Membership) {
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

/// One change to the ordered room list. Mirrors the upstream list diff one to one
/// (`RoomListEntriesUpdate`: Append, Clear, PushFront, PushBack, PopFront, PopBack, Insert, Set,
/// Remove, Truncate, Reset), so the adapter maps without reinterpreting. Diffs are incremental and
/// must never be dropped (CONCURRENCY §3).
public enum RoomListDiff: Sendable, Equatable {
    case append([RoomSummary])
    case clear
    case pushFront(RoomSummary)
    case pushBack(RoomSummary)
    case popFront
    case popBack
    case insert(index: Int, RoomSummary)
    case set(index: Int, RoomSummary)
    case remove(index: Int)
    case truncate(length: Int)
    case reset([RoomSummary])
}

/// Applies room-list diffs to an array. Pure.
public enum RoomListReducer {
    /// Applies `diff` to `rooms`. A diff that doesn't fit the current list (index out of range,
    /// pop from an empty list) leaves `rooms` unchanged and throws
    /// `.internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE")`: the list and the SDK disagree, and the
    /// caller must resubscribe to get a `.reset`.
    public static func apply(_ diff: RoomListDiff, to rooms: inout [RoomSummary]) throws(HaloError) {
        switch diff {
        case .append(let values): rooms.append(contentsOf: values)
        case .clear: rooms.removeAll()
        case .pushFront(let value): rooms.insert(value, at: 0)
        case .pushBack(let value): rooms.append(value)
        case .popFront:
            guard !rooms.isEmpty else { throw outOfRange }
            rooms.removeFirst()
        case .popBack:
            guard !rooms.isEmpty else { throw outOfRange }
            rooms.removeLast()
        case .insert(let index, let value):
            guard (0...rooms.count).contains(index) else { throw outOfRange }
            rooms.insert(value, at: index)
        case .set(let index, let value):
            guard rooms.indices.contains(index) else { throw outOfRange }
            rooms[index] = value
        case .remove(let index):
            guard rooms.indices.contains(index) else { throw outOfRange }
            rooms.remove(at: index)
        case .truncate(let length):
            guard length >= 0 else { throw outOfRange }
            if length < rooms.count { rooms.removeLast(rooms.count - length) }
        case .reset(let values): rooms = values
        }
    }

    private static var outOfRange: HaloError { .internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE") }
}
