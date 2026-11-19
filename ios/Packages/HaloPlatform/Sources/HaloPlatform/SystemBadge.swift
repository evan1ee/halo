import Foundation
import HaloDomain
import HaloFoundation
import UserNotifications

/// `BadgePort` over the system badge, plus a small cache of the rooms that need attention in the App Group so the
/// notification extension can add one more room without recomputing every room (UNREAD_STATE §8: only a fallback
/// value; the app's recomputation always overwrites it, D9).
public struct SystemBadge: BadgePort {
    private let attention: AttentionCache

    public init(suiteName: String) { attention = AttentionCache(suiteName: suiteName) }

    public func update(attentionRooms: Set<RoomID>) async {
        attention.store(attentionRooms)
        try? await UNUserNotificationCenter.current().setBadgeCount(attentionRooms.count)
    }
}

/// The set of rooms that needed attention at the app's last evaluation, shared through the App Group.
public struct AttentionCache: Sendable {
    private let suiteName: String
    private static let key = "attentionRooms.v1"

    public init(suiteName: String) { self.suiteName = suiteName }

    public func rooms() -> Set<String> {
        Set(UserDefaults(suiteName: suiteName)?.stringArray(forKey: Self.key) ?? [])
    }

    public func store(_ rooms: Set<RoomID>) {
        UserDefaults(suiteName: suiteName)?.set(rooms.map(\.rawValue).sorted(), forKey: Self.key)
    }

    /// Adds a room the extension just fetched a notifying event for and returns the new badge (the size of the set).
    public func adding(_ room: RoomID) -> Int {
        var current = rooms()
        current.insert(room.rawValue)
        UserDefaults(suiteName: suiteName)?.set(current.sorted(), forKey: Self.key)
        return current.count
    }
}
