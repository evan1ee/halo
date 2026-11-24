import Foundation
import GRDB
import HaloDomain
import HaloFoundation
import Synchronization

/// `NotificationRecordPort` over the GRDB `notification_record` table (docs/data/DATA_MODELS.md §3,
/// docs/matrix/UNREAD_STATE.md §8, R-13). Every mutation is an atomic SQLite statement scoped by `account`
/// (`INSERT OR IGNORE`, `DELETE`), so concurrent app and NSE writes never resurrect cleared records.
public final class NotificationRecordStore: NotificationRecordPort {
    public static let maximumAge: TimeInterval = 7 * 24 * 3600

    private let database: HaloDatabase
    private let account: String
    private let now: @Sendable () -> Date
    private let onChange: (@Sendable () -> Void)?
    private let externalChanges: (@Sendable () -> AsyncStream<Void>)?
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    /// - Parameters:
    ///   - database: Halo's shared WAL SQLite database (`halo.sqlite`).
    ///   - account: the signed-in user ID; every row is scoped by it.
    ///   - now: wall clock for the 7-day retention cutoff (injectable for tests).
    ///   - onChange: called after any write that changed rows (wired to a Darwin signal in the app/NSE).
    ///   - externalChanges: stream of notifications from other processes (wired to a Darwin signal in the app).
    public init(
        database: HaloDatabase, account: UserID, now: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable () -> Void)? = nil, externalChanges: (@Sendable () -> AsyncStream<Void>)? = nil
    ) {
        self.database = database
        self.account = account.rawValue
        self.now = now
        self.onChange = onChange
        self.externalChanges = externalChanges
    }

    public func all() -> [NotificationRecord] { load() ?? [] }

    public func load() -> [NotificationRecord]? {
        let cutoff = Self.millis(now().addingTimeInterval(-Self.maximumAge))
        let account = account
        return try? database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT room_id, event_id, event_ts, is_mention, delivered_at, source
                    FROM notification_record
                    WHERE account = ? AND delivered_at >= ?
                    ORDER BY event_ts ASC, event_id ASC
                    """,
                arguments: [account, cutoff]
            ).compactMap { row -> NotificationRecord? in
                guard let room = try? RoomID(row["room_id"]),
                      let event = try? EventID(row["event_id"]),
                      let source = NotificationRecord.Source(rawValue: row["source"]) else { return nil }
                return NotificationRecord(
                    roomID: room, eventID: event, timestamp: Self.date(row["event_ts"]),
                    isMention: (row["is_mention"] as Int) != 0, deliveredAt: Self.date(row["delivered_at"]),
                    source: source)
            }
        }
    }

    @discardableResult
    public func add(_ record: NotificationRecord) -> Bool {
        let account = account
        let cutoff = Self.millis(now().addingTimeInterval(-Self.maximumAge))
        let inserted = (try? database.pool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM notification_record WHERE account = ? AND delivered_at < ?",
                arguments: [account, cutoff])
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO notification_record
                      (account, event_id, room_id, event_ts, is_mention, delivered_at, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    account, record.eventID.rawValue, record.roomID.rawValue,
                    Self.millis(record.timestamp), record.isMention ? 1 : 0,
                    Self.millis(record.deliveredAt), record.source.rawValue,
                ])
            return db.changesCount > 0
        }) ?? false
        if inserted { notifyChanged() }
        return inserted
    }

    public func clear(room: RoomID) {
        clear(rooms: [room])
    }

    public func clear(rooms: Set<RoomID>) {
        guard !rooms.isEmpty else { return }
        let account = account
        let ids = Array(rooms.map(\.rawValue))
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let changed = (try? database.pool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM notification_record WHERE account = ? AND room_id IN (\(placeholders))",
                arguments: StatementArguments([account] + ids))
            return db.changesCount > 0
        }) ?? false
        if changed { notifyChanged() }
    }

    public func remove(events: Set<EventID>) {
        guard !events.isEmpty else { return }
        let account = account
        let ids = Array(events.map(\.rawValue))
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let changed = (try? database.pool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM notification_record WHERE account = ? AND event_id IN (\(placeholders))",
                arguments: StatementArguments([account] + ids))
            return db.changesCount > 0
        }) ?? false
        if changed { notifyChanged() }
    }

    public func clearAll() {
        let account = account
        let changed = (try? database.pool.write { db -> Bool in
            try db.execute(sql: "DELETE FROM notification_record WHERE account = ?", arguments: [account])
            return db.changesCount > 0
        }) ?? false
        if changed { notifyChanged() }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        let externalTask: Task<Void, Never>? = externalChanges.map { makeStream in
            let incoming = makeStream()
            return Task {
                for await _ in incoming { continuation.yield() }
            }
        }
        continuation.onTermination = { [weak self] _ in
            externalTask?.cancel()
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    private func notifyChanged() {
        let listeners = continuations.withLock { Array($0.values) }
        for listener in listeners { listener.yield() }
        onChange?()
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
