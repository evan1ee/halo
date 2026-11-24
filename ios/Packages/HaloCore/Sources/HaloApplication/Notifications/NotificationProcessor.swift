import Foundation
import HaloDomain
import HaloFoundation

/// What the notification service extension should deliver to Notification Center (PUSH_NOTIFICATIONS §3, R-08).
public enum NotificationDecision: Sendable, Equatable {
    /// Rewrite the notification content. `badge` and `attentionCounts` are `nil` when the app is foregrounded
    /// (avoiding an overwrite race, R-08) or when the event does not add attention to the room under `ReadStatePolicy`.
    case deliver(title: String, body: String, threadID: String, badge: Int?, outcome: String, attentionCounts: [RoomID: Int]? = nil)
    /// Nothing should be shown (filtered out, redacted, or duplicate push AC-U7).
    case suppressed(outcome: String)
    /// Fetch failed: deliver the original generic content with no badge.
    case fallback(outcome: String)
}

/// Pure application logic for the notification service extension (Phase 1.1, R-08).
///
/// Fetches the event through `NotificationFetchPort` (never trusting push payload fields, D65), de-duplicates via
/// `NotificationRecordPort` (AC-U7), and evaluates the badge fallback through `ReadStatePolicy` using the app's
/// last authoritative attention set plus this room only if the policy gives it attention (mode-aware, R-08).
/// When the app is in the foreground, leaves `badge = nil` so the extension never overwrites a newer app write.
public struct NotificationProcessor: Sendable {
    private let fetcher: any NotificationFetchPort
    private let records: any NotificationRecordPort
    private let lastAttention: @Sendable () -> (counts: [RoomID: Int], updatedAt: Date?)
    private let isAppForeground: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        fetcher: any NotificationFetchPort,
        records: any NotificationRecordPort,
        lastAttention: @escaping @Sendable () -> (counts: [RoomID: Int], updatedAt: Date?),
        isAppForeground: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.records = records
        self.lastAttention = lastAttention
        self.isAppForeground = isAppForeground
        self.now = now
    }

    public init(
        fetcher: any NotificationFetchPort,
        records: any NotificationRecordPort,
        lastAttention: @escaping @Sendable () -> [RoomID: Int],
        isAppForeground: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            fetcher: fetcher, records: records,
            lastAttention: { (lastAttention(), nil) },
            isAppForeground: isAppForeground, now: now)
    }

    public func process(room: RoomID, event: EventID) async -> NotificationDecision {
        let fetched: NotificationFetchResult
        do {
            fetched = try await fetcher.fetch(room: room, event: event)
        } catch {
            return .fallback(outcome: "error")
        }

        let deliveredAt = now()
        switch fetched {
        case .display(let display):
            let timestamp = display.timestamp ?? deliveredAt
            let record = NotificationRecord(
                roomID: room, eventID: event, timestamp: timestamp,
                isMention: display.isMention, deliveredAt: deliveredAt, source: .nse)
            guard records.add(record) else { return .suppressed(outcome: "duplicate") }
            let fallback = fallbackBadge(
                room: room, membership: display.isInvite ? .invited : .joined,
                isEncrypted: false, mode: display.mode, timestamp: timestamp, isMention: display.isMention)
            return .deliver(
                title: display.title, body: display.body, threadID: room.rawValue,
                badge: fallback?.badge, outcome: "display", attentionCounts: fallback?.attentionCounts)

        case .encrypted(let roomName, let timestamp, let mode):
            let eventTimestamp = timestamp ?? deliveredAt
            let record = NotificationRecord(
                roomID: room, eventID: event, timestamp: eventTimestamp,
                isMention: false, deliveredAt: deliveredAt, source: .nse)
            guard records.add(record) else { return .suppressed(outcome: "duplicate") }
            let fallback = fallbackBadge(
                room: room, membership: .joined,
                isEncrypted: true, mode: mode, timestamp: eventTimestamp, isMention: false)
            return .deliver(
                title: roomName ?? "Halo", body: "Encrypted message", threadID: room.rawValue,
                badge: fallback?.badge, outcome: "encrypted", attentionCounts: fallback?.attentionCounts)

        case .suppressed:
            return .suppressed(outcome: "suppressed")
        }
    }

    /// Mode-aware unread-message badge recomputation over the app's last authoritative per-room counts plus
    /// unconfirmed `notification_record` entries delivered since that write across all rooms (R-08, D82).
    /// Returns `nil` while the app is foregrounded (the app handles the badge via Darwin signal) or when the event
    /// does not give this room attention under `ReadStatePolicy` (e.g. non-mention in mentions-only or muted room).
    private func fallbackBadge(
        room: RoomID, membership: Membership, isEncrypted: Bool, mode: NotificationMode,
        timestamp: Date, isMention: Bool
    ) -> (badge: Int, attentionCounts: [RoomID: Int])? {
        guard !isAppForeground() else { return nil }
        let single = ReadStatePolicy.evaluate(RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: isEncrypted,
            counts: RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false),
            unconfirmedNotified: [NotifiedRef(timestamp: timestamp, isMention: isMention)]))
        guard single.attention else { return nil }

        let snapshot = lastAttention()
        let recentAll = records.all().filter { record in
            if let cutoff = snapshot.updatedAt { return record.deliveredAt >= cutoff }
            return true
        }
        let byRoom = Dictionary(grouping: recentAll, by: \.roomID)
        let currentRoomRecords = byRoom[room] ?? []
        let unconfirmed = currentRoomRecords.isEmpty
            ? [NotifiedRef(timestamp: timestamp, isMention: isMention)]
            : currentRoomRecords.map { NotifiedRef(timestamp: $0.timestamp, isMention: $0.isMention) }
        let roomDelta = ReadStatePolicy.evaluate(RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: isEncrypted,
            counts: RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false),
            unconfirmedNotified: unconfirmed))
        guard roomDelta.attention else { return nil }

        var effective = snapshot.counts
        effective[room] = (effective[room] ?? 0) + max(roomDelta.badgeCount, 1)
        // Preserve unconfirmed background pushes that arrived in other rooms since the app's last authoritative write.
        for (otherRoom, otherRecords) in byRoom where otherRoom != room && !otherRecords.isEmpty {
            let otherDelta = ReadStatePolicy.evaluate(RoomReadInputs(
                roomID: otherRoom, membership: .joined, isEncrypted: false,
                counts: RoomReadCounts(mode: .allMessages, server: .zero, sdk: .zero, isMarkedUnread: false),
                unconfirmedNotified: otherRecords.map { NotifiedRef(timestamp: $0.timestamp, isMention: $0.isMention) }))
            if otherDelta.attention {
                effective[otherRoom] = (effective[otherRoom] ?? 0) + max(otherDelta.badgeCount, 1)
            }
        }
        return (effective.values.reduce(0, +), effective)
    }
}

/// Caches one initialized resource per key and coalesces concurrent builds (used by the NSE to reuse one
/// SDK `Client` + DB across pushes in the same extension process, R-23).
public actor SingleFlightCache<Key: Hashable & Sendable, Value: Sendable> {
    private var cached: (key: Key, value: Value)?
    private var inFlight: (id: UUID, key: Key, task: Task<Value, any Error>)?

    public init() {}

    public func value(for key: Key, build: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let cached, cached.key == key { return cached.value }
        if let inFlight, inFlight.key == key { return try await inFlight.task.value }
        let id = UUID()
        let task = Task { try await build() }
        inFlight = (id, key, task)
        do {
            let value = try await task.value
            if inFlight?.id == id { inFlight = nil }
            cached = (key, value)
            return value
        } catch {
            if inFlight?.id == id { inFlight = nil }
            throw error
        }
    }

    public func invalidate(key: Key? = nil) {
        if let key {
            if cached?.key == key { cached = nil }
        } else {
            cached = nil
        }
    }
}
