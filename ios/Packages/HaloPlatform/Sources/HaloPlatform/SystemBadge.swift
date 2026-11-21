import Foundation
import HaloDomain
import HaloFoundation
import UserNotifications

/// `BadgePort` over the system badge, plus a small cache of per-room unread badge counts in the App Group so the
/// notification extension can recompute the badge without evaluating every room (UNREAD_STATE §8: only a fallback
/// value; the app's recomputation always overwrites it, D9, D82).
public struct SystemBadge: BadgePort {
    private let attention: AttentionCache

    public init(suiteName: String) { attention = AttentionCache(suiteName: suiteName) }

    public func lastAttention() async -> [RoomID: Int] { attention.roomCounts() }

    public func reset() async {
        attention.store([:])
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    public func update(attentionCounts: [RoomID: Int]) async {
        attention.store(attentionCounts)
        // Notifications of rooms that no longer need attention are removed from Notification Center (read here, PUSH §5).
        let center = UNUserNotificationCenter.current()
        let keep = Set(attentionCounts.keys.map(\.rawValue))
        let stale = await center.deliveredNotifications().map(\.request).filter { !$0.content.threadIdentifier.isEmpty && !keep.contains($0.content.threadIdentifier) }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale.map(\.identifier)) }
        let total = attentionCounts.values.reduce(0, +)
        var failure: String?
        do { try await UNUserNotificationCenter.current().setBadgeCount(total) } catch { failure = "\(error)" }
        #if DEBUG
        // Debug aid: what the app computed and what iOS said, readable with `devicectl … copy from Documents/badge-debug.txt`.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let text = "at=\(Date()) badge=\(total) rooms=\(attentionCounts.count) badgeSetting=\(settings.badgeSetting.rawValue) auth=\(settings.authorizationStatus.rawValue) setBadgeError=\(failure ?? "none")\n"
        let file = URL.documentsDirectory.appendingPathComponent("badge-debug.txt")
        if let handle = try? FileHandle(forWritingTo: file) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8)); try? handle.close() } else { try? text.write(to: file, atomically: true, encoding: .utf8) }
        #endif
    }
}

/// Per-room unread badge counts from the app's last authoritative evaluation, shared through the App Group (D82).
public struct AttentionCache: Sendable {
    private let suiteName: String
    private static let legacyStorageName = "attentionRooms.v1"
    private static let countsStorageName = "attentionCounts.v2"
    private static let updatedAtName = "attentionCountsUpdatedAt.v2"
    private static let foregroundName = "appForeground.v1"

    public init(suiteName: String) { self.suiteName = suiteName }

    public func counts() -> [String: Int] {
        let defaults = UserDefaults(suiteName: suiteName)
        if let stored = defaults?.dictionary(forKey: Self.countsStorageName) as? [String: Int] {
            return stored.filter { $0.value > 0 }
        }
        // Seamless upgrade from v1 (attentionRooms.v1): treat each previously stored room as 1 until next sync.
        let legacy = defaults?.stringArray(forKey: Self.legacyStorageName) ?? []
        return Dictionary(uniqueKeysWithValues: legacy.map { ($0, 1) })
    }

    public func roomCounts() -> [RoomID: Int] {
        var result: [RoomID: Int] = [:]
        for (raw, count) in counts() where count > 0 {
            if let id = try? RoomID(raw) { result[id] = count }
        }
        return result
    }

    public func updatedAt() -> Date? {
        guard let seconds = UserDefaults(suiteName: suiteName)?.object(forKey: Self.updatedAtName) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func rooms() -> Set<String> { Set(counts().keys) }

    public func roomIDs() -> Set<RoomID> { Set(roomCounts().keys) }

    public func store(_ roomCounts: [RoomID: Int], at date: Date = Date()) {
        let defaults = UserDefaults(suiteName: suiteName)
        let encoded = Dictionary(uniqueKeysWithValues: roomCounts.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) })
        defaults?.set(encoded, forKey: Self.countsStorageName)
        defaults?.set(date.timeIntervalSince1970, forKey: Self.updatedAtName)
        defaults?.removeObject(forKey: Self.legacyStorageName)
    }

    /// Convenience for tests and callers migrating from room-set storage.
    public func store(_ rooms: Set<RoomID>, at date: Date = Date()) {
        store(Dictionary(uniqueKeysWithValues: rooms.map { ($0, 1) }), at: date)
    }

    /// Records whether the app is currently active in the foreground so the NSE leaves the badge alone when the app
    /// is running and recomputing it (R-08).
    public func setForeground(_ active: Bool) {
        UserDefaults(suiteName: suiteName)?.set(active, forKey: Self.foregroundName)
    }

    public func isForeground() -> Bool {
        UserDefaults(suiteName: suiteName)?.bool(forKey: Self.foregroundName) ?? false
    }
}
