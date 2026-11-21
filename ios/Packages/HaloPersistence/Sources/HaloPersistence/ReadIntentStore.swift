import Foundation
import GRDB
import HaloDomain
import HaloFoundation

/// `ReadIntentPort` over `read_intent` (docs/data/DATA_MODELS.md). Timestamps are stored in milliseconds. The upsert is
/// monotonic so the app and the extension can both write (docs/data/PERSISTENCE.md §4).
public struct ReadIntentStore: ReadIntentPort {
    private let database: HaloDatabase
    private let account: String

    /// - Parameter account: the signed-in user ID; every row is scoped by it.
    public init(database: HaloDatabase, account: UserID) {
        self.database = database
        self.account = account.rawValue
    }

    public func all() async throws(HaloError) -> [ReadIntent] {
        do {
            let account = account
            return try await database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT room_id, event_id, event_ts, created_at, state, attempts, last_error, timeline_order FROM read_intent WHERE account = ?", arguments: [account])
                    .compactMap { row in
                        guard let room = try? RoomID(row["room_id"]), let event = try? EventID(row["event_id"]) else { return nil }
                        return ReadIntent(
                            room: room, event: event, timestamp: Self.date(row["event_ts"]),
                            isSent: (row["state"] as String) == "sent", createdAt: Self.date(row["created_at"]),
                            attempts: row["attempts"], lastError: row["last_error"], sequence: row["timeline_order"])
                    }
            }
        } catch { throw .storage(.corrupted) }
    }

    public func save(_ intent: ReadIntent) async throws(HaloError) {
        do {
            let account = account
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO read_intent (account, room_id, event_id, event_ts, created_at, state, receipt_type, timeline_order)
                        VALUES (?, ?, ?, ?, ?, ?, 'read', ?)
                        ON CONFLICT (account, room_id) DO UPDATE SET
                          attempts = CASE WHEN read_intent.event_id = excluded.event_id THEN read_intent.attempts ELSE 0 END,
                          last_error = CASE WHEN read_intent.event_id = excluded.event_id THEN read_intent.last_error ELSE NULL END,
                          event_id = excluded.event_id, event_ts = excluded.event_ts, created_at = excluded.created_at,
                          timeline_order = excluded.timeline_order,
                          state = CASE WHEN read_intent.event_id = excluded.event_id AND read_intent.state = 'sent' THEN 'sent' ELSE excluded.state END
                        WHERE excluded.timeline_order > read_intent.timeline_order
                           OR (excluded.timeline_order = read_intent.timeline_order AND excluded.event_ts >= read_intent.event_ts)
                        """,
                    arguments: [
                        account, intent.room.rawValue, intent.event.rawValue, Self.millis(intent.timestamp), Self.millis(intent.createdAt),
                        intent.isSent ? "sent" : "pending", intent.sequence,
                    ])
            }
        } catch { throw .storage(.corrupted) }
    }

    public func recordFailure(room: RoomID, event: EventID, code: String) async throws(HaloError) {
        do {
            let account = account
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        UPDATE read_intent SET attempts = attempts + 1, last_error = ?
                        WHERE account = ? AND room_id = ? AND event_id = ? AND state = 'pending'
                        """,
                    arguments: [code, account, room.rawValue, event.rawValue])
            }
        } catch { throw .storage(.corrupted) }
    }

    public func removeSent(createdBefore date: Date) async throws(HaloError) {
        do {
            let account = account
            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM read_intent WHERE account = ? AND state = 'sent' AND created_at < ?",
                    arguments: [account, Self.millis(date)])
            }
        } catch { throw .storage(.corrupted) }
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
