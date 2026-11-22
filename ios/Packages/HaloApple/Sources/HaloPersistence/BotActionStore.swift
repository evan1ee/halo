import Foundation
import GRDB
import HaloFoundation

/// Persisted pending/no-response bot action state (TD-08, Honest UI — AGENTS.md §4).
/// Survives app restarts so a ticked bot item doesn't revert to "open" before the bot replies.
public struct PendingBotActionRecord: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case pending
        case noResponse = "no_response"
    }

    public let roomID: RoomID
    public let botSender: UserID
    public let itemID: String
    public let state: State
    public let updatedAtMillis: Int64

    public init(roomID: RoomID, botSender: UserID, itemID: String, state: State, updatedAtMillis: Int64) {
        self.roomID = roomID
        self.botSender = botSender
        self.itemID = itemID
        self.state = state
        self.updatedAtMillis = updatedAtMillis
    }
}

/// GRDB repository for the `bot_action` table (migration `v9-bot-action`, TD-08).
public struct BotActionStore: Sendable {
    private let pool: DatabasePool

    public init(database: HaloDatabase) {
        self.pool = database.pool
    }

    /// Monotonic upsert: only overwrites an existing row when `updatedAtMillis` is newer or equal.
    public func upsert(_ record: PendingBotActionRecord, account: UserID) throws(HaloError) {
        do {
            try pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO bot_action (account, room_id, bot_sender, item_id, state, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (account, room_id, bot_sender, item_id) DO UPDATE SET
                          state = excluded.state,
                          updated_at = excluded.updated_at
                        WHERE excluded.updated_at >= bot_action.updated_at
                        """,
                    arguments: [
                        account.rawValue,
                        record.roomID.rawValue,
                        record.botSender.rawValue,
                        record.itemID,
                        record.state.rawValue,
                        record.updatedAtMillis,
                    ]
                )
            }
        } catch {
            throw .storage(.corrupted)
        }
    }

    public func delete(roomID: RoomID, botSender: UserID, itemID: String, account: UserID) throws(HaloError) {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM bot_action WHERE account = ? AND room_id = ? AND bot_sender = ? AND item_id = ?",
                    arguments: [account.rawValue, roomID.rawValue, botSender.rawValue, itemID]
                )
            }
        } catch {
            throw .storage(.corrupted)
        }
    }

    public func all(account: UserID, roomID: RoomID? = nil) throws(HaloError) -> [PendingBotActionRecord] {
        do {
            return try pool.read { db in
                let rows: [Row]
                if let roomID {
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT room_id, bot_sender, item_id, state, updated_at FROM bot_action WHERE account = ? AND room_id = ? ORDER BY updated_at ASC",
                        arguments: [account.rawValue, roomID.rawValue]
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: "SELECT room_id, bot_sender, item_id, state, updated_at FROM bot_action WHERE account = ? ORDER BY updated_at ASC",
                        arguments: [account.rawValue]
                    )
                }
                return rows.compactMap { row in
                    guard let room = try? RoomID(row["room_id"] as String),
                          let bot = try? UserID(row["bot_sender"] as String),
                          let state = PendingBotActionRecord.State(rawValue: row["state"] as String) else {
                        return nil
                    }
                    return PendingBotActionRecord(
                        roomID: room,
                        botSender: bot,
                        itemID: row["item_id"],
                        state: state,
                        updatedAtMillis: row["updated_at"]
                    )
                }
            }
        } catch {
            throw .storage(.corrupted)
        }
    }
}
