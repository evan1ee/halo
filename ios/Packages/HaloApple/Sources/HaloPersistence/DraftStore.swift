import Foundation
import GRDB
import HaloDomain
import HaloFoundation

/// `DraftPort` over the `draft` table (docs/data/DATA_MODELS.md).
public struct DraftStore: DraftPort {
    private let database: HaloDatabase
    private let account: String
    private let now: @Sendable () -> Date

    /// - Parameter account: the signed-in user ID; every row is scoped by it.
    public init(database: HaloDatabase, account: UserID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.account = account.rawValue
        self.now = now
    }

    public func draft(for room: RoomID) async throws(HaloError) -> String? {
        do {
            let account = account
            return try await database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT body FROM draft WHERE account = ? AND room_id = ?", arguments: [account, room.rawValue])
            }
        } catch { throw .storage(.corrupted) }
    }

    public func save(_ text: String, for room: RoomID) async throws(HaloError) {
        do {
            let account = account
            let stamp = Int64((now().timeIntervalSince1970 * 1000).rounded())
            let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            try await database.pool.write { db in
                if blank {
                    try db.execute(sql: "DELETE FROM draft WHERE account = ? AND room_id = ?", arguments: [account, room.rawValue])
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO draft (account, room_id, body, updated_at) VALUES (?, ?, ?, ?)
                            ON CONFLICT (account, room_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
                            """,
                        arguments: [account, room.rawValue, text, stamp])
                }
            }
        } catch { throw .storage(.corrupted) }
    }
}
