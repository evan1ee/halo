import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

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
/// `NotificationRecordPort` (AC-U7), and evaluates the badge fallback through `ReadStatePolicy`: the app's last evaluation
/// plus the events recorded since, recomputed from the records for every push (never counted up), so a repeated, late or
/// concurrent push can't drift it. When the app is in the foreground, leaves `badge = nil` so the extension never
/// overwrites a newer app write.
public struct NotificationProcessor: Sendable {
    private let fetcher: any NotificationFetchPort
    private let records: any NotificationRecordPort
    private let attention: @Sendable () -> AttentionBaseline
    private let storeDisplayed: @Sendable ([RoomID: Int]) -> Void
    private let isAppForeground: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    /// iOS runs concurrent pushes in one extension process, each with its own processor: recording an event, recomputing and
    /// storing the result must not interleave, or the later store loses the other room's push.
    private static let commit = Mutex(())

    public init(
        fetcher: any NotificationFetchPort,
        records: any NotificationRecordPort,
        attention: @escaping @Sendable () -> AttentionBaseline,
        storeDisplayed: @escaping @Sendable ([RoomID: Int]) -> Void = { _ in },
        isAppForeground: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.records = records
        self.attention = attention
        self.storeDisplayed = storeDisplayed
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
            let committed = commit(record, membership: display.isInvite ? .invited : .joined, isEncrypted: false, mode: display.mode)
            guard case .recorded(let fallback) = committed else { return .suppressed(outcome: "duplicate") }
            return .deliver(
                title: display.title, body: display.body, threadID: room.rawValue,
                badge: fallback?.badge, outcome: "display", attentionCounts: fallback?.attentionCounts)

        case .encrypted(let roomName, let timestamp, let mode):
            let eventTimestamp = timestamp ?? deliveredAt
            let record = NotificationRecord(
                roomID: room, eventID: event, timestamp: eventTimestamp,
                isMention: false, deliveredAt: deliveredAt, source: .nse)
            let committed = commit(record, membership: .joined, isEncrypted: true, mode: mode)
            guard case .recorded(let fallback) = committed else { return .suppressed(outcome: "duplicate") }
            return .deliver(
                title: roomName ?? "Halo", body: "Encrypted message", threadID: room.rawValue,
                badge: fallback?.badge, outcome: "encrypted", attentionCounts: fallback?.attentionCounts)

        case .suppressed:
            return .suppressed(outcome: "suppressed")
        }
    }

    private struct Fallback {
        let badge: Int
        let attentionCounts: [RoomID: Int]
    }

    private enum Commit {
        case duplicate
        case recorded(Fallback?)
    }

    private func commit(_ record: NotificationRecord, membership: Membership, isEncrypted: Bool, mode: NotificationMode) -> Commit {
        Self.commit.withLock { _ in
            guard records.add(record) else { return .duplicate }
            let fallback = fallbackBadge(record, membership: membership, isEncrypted: isEncrypted, mode: mode)
            if let fallback { storeDisplayed(fallback.attentionCounts) }
            return .recorded(fallback)
        }
    }

    /// Mode-aware unread-message badge recomputation (R-08, D82): this room is the app's last evaluation plus its records
    /// since then; every other room stays as displayed (its own pushes were evaluated with its own mode).
    /// Returns `nil` while the app is foregrounded (the app handles the badge via Darwin signal), when the event
    /// does not give this room attention under `ReadStatePolicy` (e.g. non-mention in mentions-only or muted room), or
    /// when sync had already delivered the event to the app (a late push: the app has counted it, or the user has read it).
    private func fallbackBadge(_ record: NotificationRecord, membership: Membership, isEncrypted: Bool, mode: NotificationMode) -> Fallback? {
        guard !isAppForeground() else { return nil }
        let room = record.roomID
        let baseline = attention()
        func isNew(_ candidate: NotificationRecord) -> Bool {
            if let through = baseline.syncedThrough[room], candidate.timestamp <= through { return false }
            if let evaluatedAt = baseline.evaluatedAt, candidate.deliveredAt < evaluatedAt { return false }
            return true
        }
        guard isNew(record) else { return nil }
        func evaluate(_ events: [NotificationRecord]) -> RoomReadState {
            ReadStatePolicy.evaluate(RoomReadInputs(
                roomID: room, membership: membership, isEncrypted: isEncrypted,
                counts: RoomReadCounts(mode: mode, server: .zero, sdk: .zero, isMarkedUnread: false),
                unconfirmedNotified: events.map { NotifiedRef(timestamp: $0.timestamp, isMention: $0.isMention) }))
        }
        guard evaluate([record]).attention else { return nil }
        var since = records.all().filter { $0.roomID == room && isNew($0) }
        if !since.contains(where: { $0.eventID == record.eventID }) { since.append(record) }
        var counts = baseline.displayed
        counts[room] = (baseline.counts[room] ?? 0) + max(evaluate(since).badgeCount, 1)
        return Fallback(badge: counts.values.reduce(0, +), attentionCounts: counts)
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
