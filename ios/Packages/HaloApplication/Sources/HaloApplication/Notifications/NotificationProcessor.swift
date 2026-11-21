import Foundation
import HaloDomain
import HaloFoundation

/// What the notification service extension should deliver to Notification Center (PUSH_NOTIFICATIONS §3, R-08).
public enum NotificationDecision: Sendable, Equatable {
    /// Rewrite the notification content. `badge` is `nil` when the app is foregrounded (avoiding an overwrite race,
    /// R-08) or when the event does not add attention to the room under `ReadStatePolicy`.
    case deliver(title: String, body: String, threadID: String, badge: Int?, outcome: String)
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
    private let lastAttention: @Sendable () -> Set<RoomID>
    private let isAppForeground: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    public init(
        fetcher: any NotificationFetchPort,
        records: any NotificationRecordPort,
        lastAttention: @escaping @Sendable () -> Set<RoomID>,
        isAppForeground: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.records = records
        self.lastAttention = lastAttention
        self.isAppForeground = isAppForeground
        self.now = now
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
            let badge = fallbackBadge(
                room: room, membership: display.isInvite ? .invited : .joined,
                isEncrypted: false, mode: display.mode, timestamp: timestamp, isMention: display.isMention)
            return .deliver(
                title: display.title, body: display.body, threadID: room.rawValue,
                badge: badge, outcome: "display")

        case .encrypted(let roomName, let timestamp, let mode):
            let eventTimestamp = timestamp ?? deliveredAt
            let record = NotificationRecord(
                roomID: room, eventID: event, timestamp: eventTimestamp,
                isMention: false, deliveredAt: deliveredAt, source: .nse)
            guard records.add(record) else { return .suppressed(outcome: "duplicate") }
            let badge = fallbackBadge(
                room: room, membership: .joined,
                isEncrypted: true, mode: mode, timestamp: eventTimestamp, isMention: false)
            return .deliver(
                title: roomName ?? "Halo", body: "Encrypted message", threadID: room.rawValue,
                badge: badge, outcome: "encrypted")

        case .suppressed:
            return .suppressed(outcome: "suppressed")
        }
    }

    /// Mode-aware badge delta over the app's last authoritative attention set (R-08).
    /// Returns `nil` while the app is foregrounded (the app handles the badge via Darwin signal) or when the event
    /// does not give this room attention under `ReadStatePolicy` (e.g. non-mention in mentions-only or muted room).
    private func fallbackBadge(
        room: RoomID, membership: Membership, isEncrypted: Bool, mode: NotificationMode,
        timestamp: Date, isMention: Bool
    ) -> Int? {
        guard !isAppForeground() else { return nil }
        let input = RoomReadInputs(
            roomID: room, membership: membership, isEncrypted: isEncrypted,
            counts: RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false),
            unconfirmedNotified: [NotifiedRef(timestamp: timestamp, isMention: isMention)])
        let state = ReadStatePolicy.evaluate(input)
        guard state.attention else { return nil }
        return lastAttention().union([room]).count
    }
}
