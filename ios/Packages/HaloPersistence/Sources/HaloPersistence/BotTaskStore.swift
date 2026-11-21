import Foundation
import GRDB
import HaloDomain
import HaloFoundation

/// `BotTaskPort` over the `bot_task` table (docs/data/DATA_MODELS.md): a derived index of the bot tasks Halo has seen, scoped by
/// account. The entity number is stored as text (the bot's own number as parsed), unlike the early sketch in DATA_MODELS.
public struct BotTaskStore: BotTaskPort {
    private let database: HaloDatabase
    private let account: String
    private let now: @Sendable () -> Date

    public init(database: HaloDatabase, account: UserID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.account = account.rawValue
        self.now = now
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    public func upsert(_ entries: [BotTaskEntry]) async throws(HaloError) {
        guard !entries.isEmpty else { return }
        do {
            let account = account
            let stamp = Self.millis(now())
            try await database.pool.write { db in
                for entry in entries {
                    // Newer-or-equal `as_of` wins (so a rebuilt entry replaces its own old copy); a missing source keeps the stored one.
                    try db.execute(
                        sql: """
                            INSERT INTO bot_task (account, room_id, bot_sender, entity_type, entity_id, source_event_id, title, detail, status, as_of_ts, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT (account, room_id, bot_sender, entity_type, entity_id) DO UPDATE SET
                              source_event_id = COALESCE(excluded.source_event_id, bot_task.source_event_id),
                              title = excluded.title, detail = excluded.detail, status = excluded.status,
                              as_of_ts = excluded.as_of_ts, updated_at = excluded.updated_at
                            WHERE excluded.as_of_ts >= bot_task.as_of_ts
                            """,
                        arguments: [
                            account, entry.key.room.rawValue, entry.key.bot, entry.key.kind.rawValue, entry.key.id,
                            entry.sourceEventID?.rawValue, entry.title, entry.detail, entry.status.rawValue, Self.millis(entry.asOf), stamp,
                        ])
                }
            }
        } catch { throw .storage(.corrupted) }
    }

    public func entries() async throws(HaloError) -> [BotTaskEntry] {
        do {
            let account = account
            return try await database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM bot_task WHERE account = ? ORDER BY as_of_ts DESC, room_id, bot_sender, entity_type, entity_id", arguments: [account])
                    .compactMap { row -> BotTaskEntry? in
                        guard let room = try? RoomID(row["room_id"] as String), let kind = BotTaskEntry.Kind(rawValue: row["entity_type"]),
                            let status = BotTaskEntry.Status(rawValue: row["status"])
                        else { return nil }
                        let source: String? = row["source_event_id"]
                        return BotTaskEntry(
                            key: .init(room: room, bot: row["bot_sender"], kind: kind, id: row["entity_id"]), title: row["title"], status: status,
                            sourceEventID: source.flatMap { try? EventID($0) },
                            asOf: Date(timeIntervalSince1970: Double(row["as_of_ts"] as Int64) / 1000), detail: row["detail"])
                    }
            }
        } catch { throw .storage(.corrupted) }
    }

    public func prune(before date: Date) async throws(HaloError) {
        do {
            let account = account
            let cutoff = Self.millis(date)
            try await database.pool.write { db in
                try db.execute(sql: "DELETE FROM bot_task WHERE account = ? AND as_of_ts < ?", arguments: [account, cutoff])
            }
        } catch { throw .storage(.corrupted) }
    }

    public func removeAll() async throws(HaloError) {
        do {
            let account = account
            try await database.pool.write { db in try db.execute(sql: "DELETE FROM bot_task WHERE account = ?", arguments: [account]) }
        } catch { throw .storage(.corrupted) }
    }
}
