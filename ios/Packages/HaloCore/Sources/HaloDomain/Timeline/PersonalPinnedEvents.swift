import Foundation
import HaloFoundation

/// Pure codec for per-user pinned messages in Matrix account data (`one.mbm.halo.pinned_events`, D63).
/// Used as a Matrix-synced fallback so normal room members (PL 0) can pin messages in any room where
/// `m.room.pinned_events` state writes are restricted to moderators.
public enum PersonalPinnedEvents {
    public static let eventType = "one.mbm.halo.pinned_events"

    public static func pinned(in room: RoomID, from content: [String: Any]?) -> [EventID] {
        guard let rooms = content?["rooms"] as? [String: Any],
              let raw = rooms[room.rawValue] as? [String] else { return [] }
        return raw.compactMap { try? EventID($0) }
    }

    /// Adds `event` to `room`'s personal pins. Returns `nil` if stored content is from a newer schema version.
    public static func pinning(_ event: EventID, in room: RoomID, content: [String: Any]?) -> [String: Any]? {
        var updated = content ?? ["version": 1]
        guard (updated["version"] as? Int ?? 1) <= 1 else { return nil }
        var rooms = updated["rooms"] as? [String: Any] ?? [:]
        var list = rooms[room.rawValue] as? [String] ?? []
        if !list.contains(event.rawValue) { list.append(event.rawValue) }
        rooms[room.rawValue] = list
        updated["rooms"] = rooms
        updated["version"] = 1
        return updated
    }

    /// Removes `event` from `room`'s personal pins. Returns `nil` if absent or stored content is from a newer version.
    public static func unpinning(_ event: EventID, in room: RoomID, content: [String: Any]?) -> [String: Any]? {
        guard var updated = content,
              (updated["version"] as? Int ?? 1) <= 1,
              var rooms = updated["rooms"] as? [String: Any],
              var list = rooms[room.rawValue] as? [String],
              list.contains(event.rawValue) else { return nil }
        list.removeAll { $0 == event.rawValue }
        rooms[room.rawValue] = list.isEmpty ? nil : list
        updated["rooms"] = rooms
        updated["version"] = 1
        return updated
    }
}
