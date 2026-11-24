import Foundation
import HaloDomain
import HaloFoundation
import UserNotifications
import WidgetKit

/// `BadgePort` over the system badge, plus a small cache of per-room unread badge counts in the App Group so the
/// notification extension can recompute the badge without evaluating every room (UNREAD_STATE §8: only a fallback
/// value; the app's recomputation always overwrites it, D9, D82).
public struct SystemBadge: BadgePort {
    private let attention: AttentionCache

    public init(suiteName: String) { attention = AttentionCache(suiteName: suiteName) }

    public func lastAttention() async -> [RoomID: Int] { attention.roomCounts() }

    public func reset() async {
        attention.store(BadgeSnapshot(attentionCounts: [:], evaluatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    public func update(_ snapshot: BadgeSnapshot) async {
        let changed = attention.roomCounts() != snapshot.attentionCounts || attention.updatedAt() == nil
        attention.store(snapshot)
        // The widgets show these counts (D89). Asked for when a widget shows something else, not on every write: iOS gives
        // widgets a daily reload budget, and one spent on an unchanged count is missing for the next message.
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            for kind in attention.staleWidgets() { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
        let center = UNUserNotificationCenter.current()
        // The icon first: reading Notification Center below takes a while, and iOS may suspend the app meanwhile.
        var failure: String?
        do { try await center.setBadgeCount(snapshot.total) } catch { failure = "\(error)" }
        // Notifications of rooms that no longer need attention are removed from Notification Center (read here, PUSH §5).
        let keep = Set(snapshot.attentionCounts.keys.map(\.rawValue))
        let stale = await center.deliveredNotifications().map(\.request).filter { !$0.content.threadIdentifier.isEmpty && !keep.contains($0.content.threadIdentifier) }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale.map(\.identifier)) }
        #if DEBUG
        // Debug aid: what the app computed and what iOS said, readable with `devicectl … copy from Documents/badge-debug.txt`.
        guard changed || failure != nil else { return }
        let settings = await center.notificationSettings()
        let text = "at=\(Date()) badge=\(snapshot.total) rooms=\(snapshot.attentionCounts.count) badgeSetting=\(settings.badgeSetting.rawValue) auth=\(settings.authorizationStatus.rawValue) setBadgeError=\(failure ?? "none")\n"
        let file = URL.documentsDirectory.appendingPathComponent("badge-debug.txt")
        if let handle = try? FileHandle(forWritingTo: file) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(text.utf8)); try? handle.close() } else { try? text.write(to: file, atomically: true, encoding: .utf8) }
        #endif
    }
}

/// What the app, the notification extension and the widgets share through the App Group (D82): the unread counts shown now
/// (widgets, and the icon), and the app's last evaluation, which the extension adds the pushes since to.
public struct AttentionCache: Sendable {
    private let suiteName: String
    private static let legacyStorageName = "attentionRooms.v1"
    private static let countsStorageName = "attentionCounts.v2"
    private static let updatedAtName = "attentionCountsUpdatedAt.v2"
    private static let baselineName = "attentionBaseline.v3"
    private static let renderedName = "widgetRendered.v1"
    private static let legacyForegroundName = "appForeground.v1"
    private static let foregroundUntilName = "appForegroundUntil.v2"

    /// How long "the app is in the foreground" holds without being renewed. A crash, a kill by iOS or a debugger stop in the
    /// foreground never reports "background"; without an end the extension would then leave the badge alone forever.
    public static let foregroundLease: TimeInterval = 45
    public static let foregroundRenewal: TimeInterval = 15

    private struct Baseline: Codable {
        let counts: [String: Int]
        let evaluatedAt: Date
        let syncedThrough: [String: Date]
    }

    public init(suiteName: String) { self.suiteName = suiteName }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// The counts shown now, by raw room ID.
    public func counts() -> [String: Int] {
        if let stored = defaults?.dictionary(forKey: Self.countsStorageName) as? [String: Int] {
            return stored.filter { $0.value > 0 }
        }
        // Seamless upgrade from v1 (attentionRooms.v1): treat each previously stored room as 1 until next sync.
        let legacy = defaults?.stringArray(forKey: Self.legacyStorageName) ?? []
        return Dictionary(uniqueKeysWithValues: legacy.map { ($0, 1) })
    }

    public func roomCounts() -> [RoomID: Int] { Self.typed(counts().filter { $0.value > 0 }) }

    public func updatedAt() -> Date? {
        guard let seconds = defaults?.object(forKey: Self.updatedAtName) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func rooms() -> Set<String> { Set(counts().keys) }

    public func roomIDs() -> Set<RoomID> { Set(roomCounts().keys) }

    /// The app's evaluation: becomes both what is shown and what the extension starts from.
    public func store(_ snapshot: BadgeSnapshot) {
        // A push can only be late by so much; older rooms don't need their position.
        let recent = snapshot.evaluatedAt.addingTimeInterval(-2 * 24 * 3600)
        let baseline = Baseline(
            counts: Self.raw(snapshot.attentionCounts), evaluatedAt: snapshot.evaluatedAt,
            syncedThrough: Dictionary(uniqueKeysWithValues: snapshot.syncedThrough.filter { $0.value > recent }.map { ($0.key.rawValue, $0.value) }))
        if let data = try? JSONEncoder().encode(baseline) { defaults?.set(data, forKey: Self.baselineName) }
        storeDisplayed(snapshot.attentionCounts, at: snapshot.evaluatedAt)
    }

    /// The extension's fallback: only what is shown; the app's evaluation stays the base for the next push.
    public func storeDisplayed(_ roomCounts: [RoomID: Int], at date: Date = Date()) {
        defaults?.set(Self.raw(roomCounts), forKey: Self.countsStorageName)
        defaults?.set(date.timeIntervalSince1970, forKey: Self.updatedAtName)
        defaults?.removeObject(forKey: Self.legacyStorageName)
    }

    /// A widget calls this with the counts its new timeline shows. The app and the extension can store counts iOS never
    /// rendered (it may ignore a reload asked for in the background), so stored and rendered must be told apart.
    public func markRendered(_ counts: [String: Int], widget kind: String) {
        var all = defaults?.dictionary(forKey: Self.renderedName) ?? [:]
        all[kind] = counts
        all["\(kind).at"] = Date().timeIntervalSince1970
        defaults?.set(all, forKey: Self.renderedName)
    }

    /// The kinds of widget that have rendered before and show other counts than the current ones.
    public func staleWidgets() -> [String] {
        let current = counts()
        return (defaults?.dictionary(forKey: Self.renderedName) ?? [:]).compactMap { kind, value in
            guard let shown = value as? [String: Int], shown != current else { return nil }
            return kind
        }.sorted()
    }

    public func baseline() -> AttentionBaseline {
        let displayed = roomCounts()
        guard let data = defaults?.data(forKey: Self.baselineName), let stored = try? JSONDecoder().decode(Baseline.self, from: data) else {
            return AttentionBaseline(counts: displayed, evaluatedAt: updatedAt())
        }
        return AttentionBaseline(
            counts: Self.typed(stored.counts), displayed: displayed, evaluatedAt: stored.evaluatedAt, syncedThrough: Self.typed(stored.syncedThrough))
    }

    /// Records whether the app is in the foreground, so the extension leaves the badge to it (R-08). Renewed every
    /// `foregroundRenewal` while it is; ends by itself after `foregroundLease`.
    public func setForeground(_ active: Bool, at date: Date = Date()) {
        defaults?.removeObject(forKey: Self.legacyForegroundName)
        if active {
            defaults?.set(date.addingTimeInterval(Self.foregroundLease).timeIntervalSince1970, forKey: Self.foregroundUntilName)
        } else {
            defaults?.removeObject(forKey: Self.foregroundUntilName)
        }
    }

    public func isForeground(at date: Date = Date()) -> Bool {
        guard let until = defaults?.object(forKey: Self.foregroundUntilName) as? Double else { return false }
        return date.timeIntervalSince1970 < until
    }

    private static func raw(_ counts: [RoomID: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) })
    }

    private static func typed<Value>(_ values: [String: Value]) -> [RoomID: Value] {
        values.reduce(into: [:]) { result, pair in
            if let id = try? RoomID(pair.key) { result[id] = pair.value }
        }
    }
}
